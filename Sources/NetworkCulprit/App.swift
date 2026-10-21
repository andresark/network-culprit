import SwiftUI
import AppKit
import ServiceManagement

// Explicitly select the native property-wrapper type. The macOS 27 SDK also
// exports a same-named macro whose plugin ships only with the full Xcode app.
typealias NativeViewState<Value> = SwiftUI.State<Value>

@main enum NetworkCulpritLauncher {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--network-notification-status") || arguments.contains("--enable-network-issue-notifications") || arguments.contains("--send-test-network-notification") {
            Task { @MainActor in exit(await NetworkIncidentNotifications.runManagementCommand(arguments)) }
            dispatchMain()
        } else if arguments.contains("--login-item-status") || arguments.contains("--enable-launch-at-login") {
            // Management runs inside the signed application bundle, so macOS
            // registers the correct installed app rather than an external tool.
            if arguments.contains("--enable-launch-at-login"), SMAppService.mainApp.status != .enabled {
                do { try SMAppService.mainApp.register() }
                catch { fputs("Login item registration failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            switch SMAppService.mainApp.status {
            case .enabled: print("Network Culprit launch at login: enabled")
            case .requiresApproval: print("Network Culprit launch at login: requires approval"); exit(2)
            case .notRegistered: print("Network Culprit launch at login: not registered"); exit(3)
            case .notFound: print("Network Culprit launch at login: app not found"); exit(4)
            @unknown default: print("Network Culprit launch at login: unknown status"); exit(5)
            }
        } else if let index = arguments.firstIndex(of: "--diagnose-json"), index + 1 < arguments.count {
            let destination = arguments[index + 1]
            Task.detached {
                let snapshot = await DiagnosticEngine.capture(settings: DiagnosticSettings(), speedTest: arguments.contains("--include-bandwidth"))
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(snapshot).write(to: URL(fileURLWithPath: destination), options: .atomic)
                    print(snapshot.finding.title); exit(0)
                } catch { try? FileHandle.standardError.write(contentsOf: Data("Could not save diagnostic report: \(error)\n".utf8)); exit(1) }
            }
            dispatchMain()
        } else { NetworkCulpritApp.main() }
    }
}

struct NetworkCulpritApp: App {
    @NativeViewState private var store = DiagnosticStore()
    var body: some Scene {
        WindowGroup("Network Culprit", id: "main") {
            MainWindow(store: store)
                .frame(minWidth: 980, minHeight: 700)
        }
        .defaultSize(width: 1240, height: 880)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Run Network Diagnostic") { store.run() }.keyboardShortcut("r", modifiers: .command).disabled(store.isRunning)
                Button("Run Bandwidth Benchmark") { store.run(speedTest: true) }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(store.isRunning)
                Divider()
                Button("Export Diagnostic History as JSON…") { store.exportHistory(csv: false) }
                Button("Export Benchmarks as CSV…") { store.exportHistory(csv: true) }
            }
        }
        Settings { SettingsScreen(store: store).frame(width: 650, height: 650) }
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            NetworkMenuBarIcon(store: store)
        }
    }
}

private struct NetworkMenuBarIcon: View {
    @Bindable var store: DiagnosticStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let status = NetworkMenuBarStatus(health: store.latest?.finding.health, isRunning: store.isRunning)
        Image(nsImage: status.image)
            .renderingMode(.original)
            .accessibilityLabel("Network Culprit: \(status.description)")
            .help(store.latest.map { "Network Culprit: \(status.description) — \($0.finding.title)" } ?? "Network Culprit: \(status.description)")
            .onChange(of: store.incidentNotifications.dashboardRequested, initial: true) { _, requested in
                if requested { openWindow(id: "main"); NSApp.activate(); store.incidentNotifications.dashboardRequested = false }
            }
    }
}

struct MenuBarContent: View {
    @Bindable var store: DiagnosticStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Network Culprit — ISP, DNS & VPN Diagnostics")
        if let latest = store.latest {
            Text(latest.finding.title)
            Text("Checked \(latest.date.formatted(date: .omitted, time: .shortened))")
        } else { Text("No diagnostic recorded yet") }
        Divider()
        Button("Open Network Dashboard") { openWindow(id: "main"); NSApp.activate() }
        Button(store.isRunning ? "Checking network…" : "Run Quick Diagnostic") { store.run() }.disabled(store.isRunning)
        Toggle("Keep Lightweight History", isOn: $store.settings.automaticChecks)
        Toggle("Launch Network Culprit at Login", isOn: Binding(get: { store.loginItem.isRequested }, set: { store.loginItem.setEnabled($0) }))
        if store.loginItem.needsApproval { Button("Approve Launch in System Settings…") { store.loginItem.openSystemSettings() } }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Network Culprit") { NSApp.terminate(nil) }
    }
}
