import Foundation
import SQLite3

/// Local SQLite storage using the system library; no compiler plugins or packages.
final class SnapshotDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS diagnostic_checks (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS diagnostic_checks_timestamp ON diagnostic_checks(timestamp); PRAGMA user_version=1;")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(handle) }
    private func failure() -> NSError {
        NSError(domain: "NetworkCulprit.History", code: Int(sqlite3_errcode(handle)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func insert(_ snapshot: DiagnosticSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(snapshot)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO diagnostic_checks(id,timestamp,payload) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        _ = snapshot.id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_double(statement, 2, snapshot.date.timeIntervalSince1970)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    func read(limit: Int = -1) throws -> [DiagnosticSnapshot] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT payload FROM diagnostic_checks ORDER BY timestamp DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var results: [DiagnosticSnapshot] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            results.append(try JSONDecoder().decode(DiagnosticSnapshot.self, from: data))
        }
        return results
    }
    func count() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM diagnostic_checks", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func prune(before date: Date) throws {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM diagnostic_checks WHERE timestamp < ?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
}
