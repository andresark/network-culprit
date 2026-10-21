import Foundation
import Network
import Darwin

struct CommandResult: Sendable {
    var text: String
    var exitCode: Int32
    var seconds: Double
    var timedOut: Bool
    var standardOutput = ""
    var standardError = ""
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; if data.count < 524_288 { data.append(value.prefix(524_288 - data.count)) } }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum SystemCommand {
    static func run(_ path: String, _ arguments: [String], timeout: Double = 8, environmentOverrides: [String: String] = [:]) async -> CommandResult {
        // Process execution blocks on termination and pipe draining. Keep that
        // work off Swift's cooperative executor: on a small-core Mac, blocking
        // detached tasks can starve the dispatch readers that supply output.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: execute(path, arguments, timeout: timeout, environmentOverrides: environmentOverrides))
            }
        }
    }
    private static func execute(_ path: String, _ arguments: [String], timeout: Double, environmentOverrides: [String: String]) -> CommandResult {
        let start = Date()
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        // Preserve the user's GUI/XPC session. Per-command overrides affect only
        // this child process, never this app or the user's shell configuration.
        // Executables are absolute paths; arguments never pass through a shell.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"; environment["LC_ALL"] = "C"
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment
        let pipe = Pipe(), errors = Pipe(), output = OutputBuffer(), errorOutput = OutputBuffer(), done = DispatchSemaphore(value: 0), drained = DispatchGroup()
        process.standardOutput = pipe; process.standardError = errors
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            return CommandResult(text: error.localizedDescription, exitCode: -1, seconds: Date().timeIntervalSince(start), timedOut: false)
        }
        try? pipe.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        for (reader, buffer) in [(pipe.fileHandleForReading, output), (errors.fileHandleForReading, errorOutput)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                while let bytes = try? reader.read(upToCount: 16_384), !bytes.isEmpty { buffer.append(bytes) }
                drained.leave()
            }
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
        }
        _ = drained.wait(timeout: .now() + 2)
        let stdout = output.text(), stderr = errorOutput.text()
        return CommandResult(text: stdout + (stderr.isEmpty ? "" : "\n" + stderr), exitCode: process.isRunning ? -1 : process.terminationStatus,
                             seconds: Date().timeIntervalSince(start), timedOut: timedOut, standardOutput: stdout, standardError: stderr)
    }
}

enum TailscaleCLI {
    static func run(_ executable: String, _ arguments: [String], timeout: Double) async -> CommandResult {
        // The macOS executable contains both the GUI and CLI. Finder-launched
        // apps have no terminal variables, so implicit mode detection starts the
        // GUI and can return exit 0 with a short non-JSON informational message.
        // https://tailscale.com/docs/reference/tailscale-cli?tab=macos
        await SystemCommand.run(executable, arguments, timeout: timeout, environmentOverrides: ["TAILSCALE_BE_CLI": "1"])
    }
}

struct DNSReply: Sendable { var milliseconds: Double; var code: Int; var answers: Int; var error: String? }

enum DNSWire {
    static func health(_ results: [DNSReply]) -> Health {
        let successful = results.filter { $0.error == nil && $0.code == 0 && $0.answers > 0 }
        guard !successful.isEmpty else { return .failed }
        let median = successful.map(\.milliseconds).sorted()[successful.count / 2]
        return successful.count == results.count && median <= 250 ? .good : .warning
    }
    static func query(_ domain: String, id: UInt16) -> Data? {
        let domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard domain.utf8.count <= 253, domain.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63 else { return nil }
            bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0, 0, 1, 0, 1]); return Data(bytes)
    }
    static func reply(_ data: Data, id: UInt16) -> (Int, Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) == id, bytes[2] & 0x80 != 0 else { return nil }
        return (Int(bytes[3] & 15), Int(bytes[6]) << 8 | Int(bytes[7]))
    }
    static func measure(server: String, domain: String) async -> DNSReply {
        await withCheckedContinuation { continuation in DNSOperation(server: server, domain: domain, continuation: continuation).start() }
    }
}

private final class DNSOperation: @unchecked Sendable {
    let queue = DispatchQueue(label: "local.NetworkCulprit.dns-probe")
    let connection: NWConnection
    let identifier = UInt16.random(in: 1...65535)
    let domain: String
    var continuation: CheckedContinuation<DNSReply, Never>?
    var startTime = DispatchTime.now()
    var waitingError: String?
    init(server: String, domain: String, continuation: CheckedContinuation<DNSReply, Never>) {
        self.domain = domain; self.continuation = continuation
        connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
    }
    func start() {
        queue.async { [self] in
            guard let packet = DNSWire.query(domain, id: identifier) else { finish(error: "Invalid DNS test domain"); return }
            startTime = .now()
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { [self] error in
                        if let error { finish(error: error.localizedDescription); return }
                        connection.receiveMessage { [self] data, _, _, error in
                            if let data, let reply = DNSWire.reply(data, id: identifier) { finish(code: reply.0, answers: reply.1) }
                            else { finish(error: error?.localizedDescription ?? "Invalid DNS response") }
                        }
                    })
                case .failed(let error): finish(error: error.localizedDescription)
                case .waiting(let error): waitingError = error.localizedDescription
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.8) { [self] in finish(error: waitingError ?? "No reply within 1.8 seconds") }
        }
    }
    func finish(code: Int = -1, answers: Int = 0, error: String? = nil) {
        guard let continuation else { return }; self.continuation = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        continuation.resume(returning: DNSReply(milliseconds: ms, code: code, answers: answers, error: error))
    }
}

enum TextParse {
    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last,
              let data = String(text[first...last]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    static func all(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }; return String(text[range])
        }
    }
    static func dnsServers(_ text: String) -> [String] {
        var seen = Set<String>()
        return all("nameserver\\[\\d+\\]\\s*:\\s*(\\S+)", in: text).filter {
            $0 != "127.0.0.1" && $0 != "::1" && seen.insert($0).inserted
        }
    }
    static func publicIPv6Addresses(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard !["deprecated", "tentative", "duplicated", "detached", "pltime 0 "].contains(where: { text.contains($0) }),
                  let address = first("inet6 ([0-9a-fA-F:]+) prefixlen", in: text),
                  address.hasPrefix("2") || address.hasPrefix("3") else { return nil }
            return address
        }
    }
    static func prefix(_ address: String) -> String? {
        var value = in6_addr()
        guard inet_pton(AF_INET6, address, &value) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        return stride(from: 0, to: 8, by: 2).map { String(Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]), radix: 16) }.joined(separator: ":") + "::/64"
    }
    static func ping(_ result: CommandResult, key: String, layer: NetworkLayer, name: String, target: String) -> Probe {
        let loss = first("([0-9.]+)% packet loss", in: result.text).flatMap(Double.init)
        let avg = first("(?:round-trip|rtt)[^=]*=\\s*[0-9.]+/([0-9.]+)/", in: result.text).flatMap(Double.init)
        let slow = (avg ?? 0) > (layer == .local ? 20 : 150)
        let health: Health = loss == nil || loss == 100 ? .failed : (loss ?? 0) > 0 || slow ? .warning : .good
        return Probe(key: key, layer: layer, name: name, target: target, health: health,
                     milliseconds: avg, packetLoss: loss,
                     detail: loss.map { String(format: "%.0f%% loss · 8 short ICMP probes", $0) + (slow ? " · elevated mean latency" : "") } ?? "No ICMP replies; ICMP may be filtered",
                     evidence: result.text)
    }
}
