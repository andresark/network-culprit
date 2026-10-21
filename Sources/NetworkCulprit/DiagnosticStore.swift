import Foundation
import Observation
import Network
import AppKit

@MainActor @Observable final class DiagnosticStore {
    var history: [DiagnosticSnapshot] = []
    var totalRecords = 0
    var isRunning = false
    var activity = "Ready"
    var errorMessage: String?
    var pathDescription = "Reading network path…"
    var lastCheck: Date?
    var pathIsExpensive = false
    var pathIsConstrained = false
    var displayLimit = 1000
    var settings: DiagnosticSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "networkDiagnosticSettings") }
            configureSampling()
        }
    }
    let database: SnapshotDatabase?
    let dataDirectory: URL
    let loginItem = LoginItemController()
    let incidentNotifications: NetworkIncidentNotifications
    private var samplingTask: Task<Void, Never>?
    private var incidentConfirmationTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    var latest: DiagnosticSnapshot? { history.first }

    init() {
        if let data = UserDefaults.standard.data(forKey: "networkDiagnosticSettings"), let saved = try? JSONDecoder().decode(DiagnosticSettings.self, from: data) { settings = saved }
        else { settings = DiagnosticSettings() }
        dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Network Culprit — ISP DNS and VPN Diagnostics", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            database = try SnapshotDatabase(url: dataDirectory.appending(path: "Network Diagnostic History.sqlite"))
        } catch { database = nil; errorMessage = "History storage could not be opened: \(error.localizedDescription). Checks are disabled until storage is available." }
        incidentNotifications = NetworkIncidentNotifications(dataDirectory: dataDirectory)
        reloadHistory()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let interfaces = Array(Set(path.availableInterfaces.map(\.name))).sorted().joined(separator: ", ")
            let summary = "\(path.status == .satisfied ? "Connected" : "No network path") · \(interfaces)\(path.isConstrained ? " · Low Data Mode" : "")"
            let connected = path.status == .satisfied, expensive = path.isExpensive, constrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = pathDescription != "Reading network path…" && pathDescription != summary
                pathDescription = summary; pathIsExpensive = expensive; pathIsConstrained = constrained
                if changed { recordPathEvent(summary: summary, connected: connected); run() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "local.NetworkCulprit.network-path"))
        configureSampling()
        // Startup diagnostics must not depend on a dashboard window appearing.
        // The app can launch entirely in the menu bar at login.
        run()
    }

    func configureSampling() {
        samplingTask?.cancel()
        incidentConfirmationTask?.cancel()
        guard settings.automaticChecks else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = max(self?.settings.intervalSeconds ?? 300, 60)
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                let lastBenchmark = history.first { $0.kind == "Full benchmark" }?.date ?? .distantPast
                let speed = settings.automaticBandwidthTests && !pathIsExpensive && !pathIsConstrained && Date().timeIntervalSince(lastBenchmark) >= Double(settings.bandwidthIntervalHours * 3600)
                run(speedTest: speed)
            }
        }
        scheduleIncidentConfirmation()
    }

    private func scheduleIncidentConfirmation() {
        incidentConfirmationTask?.cancel()
        guard settings.automaticChecks, let delay = incidentNotifications.followUpDelay else { return }
        incidentConfirmationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            if isRunning { scheduleIncidentConfirmation() }
            else { run() } // Lightweight only; confirmation never starts a bandwidth test.
        }
    }

    func run(speedTest: Bool = false) {
        guard !isRunning, database != nil else { return }
        isRunning = true
        activity = speedTest ? "Measuring bandwidth, loaded latency, and every network layer…" : "Comparing router, internet, DNS, Tailscale, IPv6, and HTTPS…"
        let settings = settings
        Task {
            var snapshot = await DiagnosticEngine.capture(settings: settings, speedTest: speedTest)
            if let previous = latest, previous.context.interface == snapshot.context.interface,
               let oldIn = previous.context.interfaceInputErrors, let oldOut = previous.context.interfaceOutputErrors,
               let newIn = snapshot.context.interfaceInputErrors, let newOut = snapshot.context.interfaceOutputErrors,
               newIn >= oldIn, newOut >= oldOut {
                let growth = (newIn - oldIn) + (newOut - oldOut)
                snapshot.probes.append(Probe(key: "local.interface-errors", layer: .local, name: "Interface error growth", target: snapshot.context.interface,
                                             health: growth > 0 ? .warning : .good, value: Double(growth), unit: "new errors",
                                             detail: "Input +\(newIn - oldIn), output +\(newOut - oldOut) since \(previous.date.formatted(date: .omitted, time: .shortened)). Counter resets are not treated as growth."))
                snapshot.finding = Attribution.evaluate(snapshot.probes, context: snapshot.context)
            }
            do {
                guard let database else { throw CocoaError(.fileNoSuchFile) }
                try database.insert(snapshot)
                incidentNotifications.record(snapshot)
                lastCheck = snapshot.date
                try pruneHistory(); reloadHistory()
            } catch { errorMessage = "The diagnostic completed, but saving history failed: \(error.localizedDescription)" }
            isRunning = false; activity = "Ready"
            scheduleIncidentConfirmation()
        }
    }

    func reloadHistory() {
        guard let database else { return }
        do {
            history = try database.read(limit: displayLimit)
            totalRecords = try database.count()
            lastCheck = history.first?.date
        } catch { errorMessage = "Could not read saved history: \(error.localizedDescription)" }
    }

    func loadMoreHistory() { displayLimit += 1000; reloadHistory() }

    private func recordPathEvent(summary: String, connected: Bool) {
        let finding = Finding(title: connected ? "Network path changed" : "Network path became unavailable",
                              explanation: "macOS Network.framework reported: \(summary). This event records a path transition, not a completed internet benchmark.",
                              health: connected ? .warning : .failed, layer: .local, confidence: "Measured",
                              evidence: [summary], nextStep: "Compare the diagnostics immediately before and after this event.")
        let event = DiagnosticSnapshot(kind: "Network path event", context: NetworkContext(),
                                       probes: [Probe(key: "local.path-event", layer: .local, name: "Native network path transition", target: "This Mac", health: finding.health, detail: summary)], finding: finding, duration: 0)
        do {
            guard let database else { return }
            try database.insert(event); reloadHistory()
            incidentNotifications.record(event); scheduleIncidentConfirmation()
        } catch { errorMessage = "Could not record network path event: \(error.localizedDescription)" }
    }

    func pruneHistory() throws {
        guard settings.retentionDays > 0, let database,
              let cutoff = Calendar.current.date(byAdding: .day, value: -settings.retentionDays, to: Date()) else { return }
        try database.prune(before: cutoff)
    }

    func exportHistory(csv: Bool) {
        guard let database else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csv ? "Network Culprit Diagnostic History.csv" : "Network Culprit Diagnostic History.json"
        panel.title = "Export local diagnostic history"
        panel.message = "Exports include network addresses, selected peer names, and raw diagnostic evidence. Share only with people you trust."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshots = Array(try database.read().reversed())
            let data = try HistoryExport.encode(snapshots, csv: csv)
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }
}
