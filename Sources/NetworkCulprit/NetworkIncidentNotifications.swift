import Foundation
import Observation
import AppKit
import UserNotifications

struct NetworkIncidentNotificationPreferences: Codable, Sendable {
    var isEnabled = false
    var minimumProblemDuration: TimeInterval = 60
    var playSound = false
    private static let key = "networkIncidentNotificationPreferences"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

struct PersistedNetworkIncidentState: Codable, Sendable {
    var tracker = NetworkIncidentTracker()
    var pendingNotices: [NetworkIncidentNotice] = []

    mutating func enqueue(_ notices: [NetworkIncidentNotice], observedAt date: Date) {
        pendingNotices.append(contentsOf: notices)
        let resolved = Set(pendingNotices.filter { $0.kind == .recovered }.map(\.incidentID))
        // If delivery failed until the incident ended, send one resolved summary
        // instead of a delayed issue/recovery burst. Discard stale old summaries.
        pendingNotices.removeAll {
            ($0.kind == .started && resolved.contains($0.incidentID)) ||
            ($0.kind == .recovered && date.timeIntervalSince($0.observedThrough) > 900)
        }
        pendingNotices = Array(pendingNotices.suffix(10))
    }
}

extension NetworkIncidentNotice {
    func notificationContent(playSound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = kind == .started ? "Network issue detected" : "Network recovered"
        content.subtitle = "\(kind == .started ? "Likely culprit" : "Previous likely culprit"): \(issue.layer.rawValue)"
        content.body = kind == .started
            ? "\(issue.title)\nRepeatedly observed across \(durationDescription). \(issue.confidence) confidence."
            : "Observed issue window: \(durationDescription). Healthy in two checks.\n\(issue.title)"
        content.threadIdentifier = "local.NetworkCulprit.incident.\(incidentID.uuidString)"
        content.userInfo = ["networkIncidentID": incidentID.uuidString]
        content.interruptionLevel = .active
        if playSound { content.sound = .default }
        return content
    }
}

@MainActor @Observable final class NetworkIncidentNotifications: NSObject, UNUserNotificationCenterDelegate {
    var preferences: NetworkIncidentNotificationPreferences {
        didSet {
            guard !isDemonstration else { return }
            preferences.save()
            if !preferences.isEnabled { state = PersistedNetworkIncidentState(); persistState() }
        }
    }
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var errorMessage: String?
    var dashboardRequested = false
    private(set) var state = PersistedNetworkIncidentState()
    @ObservationIgnored private lazy var center = UNUserNotificationCenter.current()
    private let stateURL: URL
    private var isSubmitting = false
    private let isDemonstration: Bool

    var canDeliver: Bool { authorizationStatus == .authorized || authorizationStatus == .provisional }
    var followUpDelay: TimeInterval? { preferences.isEnabled && canDeliver ? state.tracker.followUpDelay : nil }
    var statusDescription: String {
        if isDemonstration { return "Demo mode — no notifications are requested or delivered" }
        return switch authorizationStatus {
        case .authorized, .provisional: preferences.isEnabled ? "Enabled — sustained issues and confirmed recoveries" : "Off — macOS notification permission is available"
        case .denied: "Blocked by macOS — allow Network Culprit in System Settings → Notifications"
        case .notDetermined: "macOS notification permission has not been requested"
        @unknown default: "Unknown macOS notification permission state"
        }
    }

    init(dataDirectory: URL, demonstration: Bool = false) {
        isDemonstration = demonstration
        preferences = demonstration ? NetworkIncidentNotificationPreferences() : .load()
        stateURL = dataDirectory.appending(path: "Network Incident Notification State.json")
        super.init()
        guard !demonstration else { return }
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(PersistedNetworkIncidentState.self, from: data) {
            state = saved
            if saved.tracker.lastObservation.map({ $0 > Date().addingTimeInterval(300) }) == true { state = PersistedNetworkIncidentState() }
        }
        if !preferences.isEnabled { state = PersistedNetworkIncidentState() }
        center.delegate = self
        // Retry only after fresh diagnostic evidence, not immediately on restart.
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async { if !isDemonstration { authorizationStatus = await center.notificationSettings().authorizationStatus } }

    func setEnabled(_ enabled: Bool) async {
        guard !isDemonstration else { return }
        errorMessage = nil
        if enabled {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                await refreshAuthorization()
                guard granted, canDeliver else { preferences.isEnabled = false; return }
            } catch { errorMessage = "Could not request notifications: \(error.localizedDescription)"; return }
        }
        preferences.isEnabled = enabled
    }

    func record(_ snapshot: DiagnosticSnapshot) {
        guard preferences.isEnabled, canDeliver else { return }
        let notices = state.tracker.observe(snapshot, minimumProblemDuration: preferences.minimumProblemDuration)
        state.enqueue(notices, observedAt: snapshot.date)
        // Keep a bounded, durable outbox so a transient submission error does not
        // lose an incident or create repeated notices on every failing sample.
        guard persistState() else { return }
        Task { await submitPendingNotices() }
    }

    @discardableResult private func persistState() -> Bool {
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            return true
        } catch { errorMessage = "Could not save notification incident state: \(error.localizedDescription)"; return false }
    }

    private func submitPendingNotices() async {
        guard !isSubmitting, preferences.isEnabled, canDeliver, !state.pendingNotices.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let delivered = Set(await center.deliveredNotifications().map { $0.request.identifier })
        while preferences.isEnabled, let notice = state.pendingNotices.first {
            if notice.kind == .started {
                guard let current = state.tracker.incident, current.id == notice.incidentID else {
                    state.pendingNotices.removeFirst(); persistState(); continue
                }
                guard current.firstHealthy == nil, state.tracker.lastObservation == current.lastProblem else { return }
            }
            do {
                if !delivered.contains(notice.id) {
                    try await center.add(UNNotificationRequest(identifier: notice.id, content: notice.notificationContent(playSound: preferences.playSound), trigger: nil))
                }
                state.pendingNotices.removeAll { $0.id == notice.id }
                persistState()
            } catch { errorMessage = "Could not deliver a network notification: \(error.localizedDescription)"; return }
        }
    }

    func sendTestNotification() async {
        guard !isDemonstration else { return }
        await refreshAuthorization()
        guard canDeliver else { errorMessage = "Allow Network Culprit notifications in macOS first."; return }
        let content = UNMutableNotificationContent()
        content.title = "Network Culprit notification test"
        content.subtitle = "Test only — no network outage detected"
        content.body = "Sustained issue alerts will include the likely culprit. Recovery alerts will include the observed issue duration."
        if preferences.playSound { content.sound = .default }
        do { try await center.add(UNNotificationRequest(identifier: "local.NetworkCulprit.notification-test", content: content, trigger: nil)) }
        catch { errorMessage = "Could not deliver the test notification: \(error.localizedDescription)" }
    }

    func openSystemSettings() {
        guard !isDemonstration else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor [weak self] in self?.dashboardRequested = true }
        }
        completionHandler()
    }

    static func runManagementCommand(_ arguments: [String]) async -> Int32 {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Network Culprit — ISP DNS and VPN Diagnostics", directoryHint: .isDirectory)
        if !arguments.contains("--network-notification-status") {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { print("Could not open notification settings: \(error.localizedDescription)"); return 1 }
        }
        let notifications = NetworkIncidentNotifications(dataDirectory: directory)
        await notifications.refreshAuthorization()
        if arguments.contains("--enable-network-issue-notifications") { await notifications.setEnabled(true) }
        if arguments.contains("--send-test-network-notification") { await notifications.sendTestNotification() }
        await notifications.refreshAuthorization()
        print("Network Culprit notifications: \(notifications.statusDescription)")
        if arguments.contains("--network-notification-status") {
            let delivered = await notifications.center.deliveredNotifications()
            let incidents = delivered.filter { $0.request.identifier.hasPrefix("local.NetworkCulprit.network-incident.") }.count
            let testDelivered = delivered.contains { $0.request.identifier == "local.NetworkCulprit.notification-test" }
            print("Notification Center retains \(incidents) incident notices; test notification present: \(testDelivered)")
        }
        if let error = notifications.errorMessage { print(error); return 1 }
        return notifications.canDeliver ? 0 : 2
    }
}
