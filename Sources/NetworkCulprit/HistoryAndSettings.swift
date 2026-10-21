import SwiftUI
import AppKit

struct HistoryScreen: View {
    @Bindable var store: DiagnosticStore
    @NativeViewState private var selection: UUID?
    @NativeViewState private var reviewed: DiagnosticSnapshot?
    @NativeViewState private var search = ""
    @NativeViewState private var onlyProblems = false
    var filtered: [DiagnosticSnapshot] {
        store.history.filter { (!onlyProblems || $0.finding.health != .good) && (search.isEmpty || $0.finding.title.localizedCaseInsensitiveContains(search) || $0.context.interface.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The evidence, over time").font(.title2.weight(.semibold))
                    Text("\(store.totalRecords) checks saved locally · \(store.settings.retentionDays == 0 ? "Unlimited retention" : "\(store.settings.retentionDays)-day retention")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Only issues", isOn: $onlyProblems).toggleStyle(.switch)
                Button("Review Selected Check") { reviewed = filtered.first { $0.id == selection } }.buttonStyle(.glass).disabled(selection == nil)
            }
            LatencyHistoryChart(history: filtered)
            Table(filtered, selection: $selection) {
                TableColumn("Recorded") { snapshot in Text(snapshot.date.formatted(date: .abbreviated, time: .shortened)) }.width(min: 150, ideal: 175)
                TableColumn("Assessment") { snapshot in Label(snapshot.finding.title, systemImage: snapshot.finding.health.symbol).foregroundStyle(snapshot.finding.health.color) }.width(min: 230)
                TableColumn("Run") { Text($0.kind) }.width(115)
                TableColumn("Interface") { Text($0.context.interface).monospaced() }.width(70)
                TableColumn("Duration") { Text(String(format: "%.1f s", $0.duration)).monospacedDigit() }.width(80)
            }.frame(minHeight: 230)
            if store.history.count < store.totalRecords { Button("Load 1,000 Older Checks") { store.loadMoreHistory() } }
        }.padding(22)
        .searchable(text: $search, prompt: "Search recorded assessments")
        .sheet(item: $reviewed) { snapshot in SnapshotReview(snapshot: snapshot) }
    }
}

struct SnapshotReview: View {
    var snapshot: DiagnosticSnapshot
    @Environment(\.dismiss) private var dismiss
    @NativeViewState private var layer: NetworkLayer?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(snapshot.date.formatted(date: .complete, time: .standard)).font(.headline); Spacer(); Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.defaultAction) }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FindingCard(finding: snapshot.finding)
                    GlassEffectContainer(spacing: 10) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                            ForEach(NetworkLayer.allCases) { item in Button { layer = item } label: { LayerCard(layer: item, snapshot: snapshot) }.buttonStyle(.plain) }
                        }
                    }
                    GroupBox("Network context at capture") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Interface: \(snapshot.context.interface) · public traffic: \(snapshot.context.publicTrafficInterface)")
                            Text("Gateway: \(snapshot.context.gateway)")
                            Text("Resolvers: \(snapshot.context.resolvers.joined(separator: ", "))")
                            Text("IPv6 prefixes: \(snapshot.context.ipv6Prefixes.joined(separator: ", "))")
                            Text(snapshot.context.proxySummary)
                        }.font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(8).textSelection(.enabled)
                    }
                }.padding(22)
            }
        }.frame(width: 950, height: 740)
        .sheet(item: $layer) { LayerDetailSheet(layer: $0, snapshot: snapshot) }
    }
}

struct BenchmarkScreen: View {
    @Bindable var store: DiagnosticStore
    var benchmarks: [DiagnosticSnapshot] { store.history.filter { $0.kind == "Full benchmark" } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 20) {
                    Image(systemName: "speedometer").font(.system(size: 42)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Capacity is only part of the story").font(.title2.weight(.semibold))
                        Text("Measure download, upload, and responsiveness under load with Apple's networkQuality. Compare the saved results with the lightweight diagnostic history.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run Bandwidth Benchmark") { store.run(speedTest: true) }.buttonStyle(.glassProminent).controlSize(.large).disabled(store.isRunning)
                }.padding(22).background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                Label("Baseline checks, then up to 35 seconds of load · can transfer gigabytes and briefly saturate your connection", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                LatencyHistoryChart(history: benchmarks, initialSelection: .bandwidth)
                if benchmarks.isEmpty {
                    ContentUnavailableView("No bandwidth benchmarks saved", systemImage: "speedometer", description: Text("Run a benchmark to start your ISP capacity history. Lightweight checks do not run speed tests."))
                } else {
                    ForEach(benchmarks) { snapshot in
                        GroupBox(snapshot.date.formatted(date: .abbreviated, time: .shortened)) {
                            HStack(spacing: 28) {
                                ForEach(snapshot.probes.filter { $0.key.hasPrefix("speed.") }) { probe in
                                    VStack(alignment: .leading, spacing: 5) { Text(probe.name).foregroundStyle(.secondary); Text(probe.metric).font(.title2.weight(.semibold)).monospacedDigit(); Text(probe.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                    }
                }
            }.padding(24)
        }
    }
}

struct SettingsScreen: View {
    @Bindable var store: DiagnosticStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            Section {
                Toggle("Launch Network Culprit at login", isOn: Binding(get: { store.loginItem.isRequested }, set: { store.loginItem.setEnabled($0) }))
                Text(store.loginItem.description).font(.caption).foregroundStyle(.secondary)
                if let error = store.loginItem.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if store.loginItem.needsApproval { Button("Open macOS Login Items…") { store.loginItem.openSystemSettings() } }
                Text("The app starts quietly in the menu bar and records checks with no dashboard window open. Choose Open Network Dashboard from its menu to inspect history. Quitting stops monitoring until the next launch or login.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Login & menu bar monitoring") }
            Section {
                Toggle("Record lightweight network checks while the app is open", isOn: $store.settings.automaticChecks)
                Picker("Check every", selection: $store.settings.intervalSeconds) {
                    Text("1 minute").tag(60); Text("5 minutes").tag(300); Text("15 minutes").tag(900); Text("30 minutes").tag(1800)
                }.disabled(!store.settings.automaticChecks)
                Picker("Keep local history", selection: $store.settings.retentionDays) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365); Text("Forever").tag(0)
                }
                Text("Closing the window keeps the menu bar app running. Quitting stops checks. Checks run while the Mac is awake; the app does not wake it or install a background daemon.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Monitoring & history") }
            Section {
                Toggle("Notify sustained network issues and recoveries", isOn: Binding(
                    get: { store.incidentNotifications.preferences.isEnabled },
                    set: { enabled in Task { await store.incidentNotifications.setEnabled(enabled); if enabled { store.run() } } }))
                Text(store.incidentNotifications.statusDescription).font(.caption).foregroundStyle(.secondary)
                Picker("Confirm an issue for at least", selection: Binding(
                    get: { store.incidentNotifications.preferences.minimumProblemDuration },
                    set: { store.incidentNotifications.preferences.minimumProblemDuration = $0 })) {
                        Text("1 minute").tag(60.0); Text("2 minutes").tag(120.0); Text("5 minutes").tag(300.0)
                    }
                Toggle("Play a notification sound", isOn: Binding(
                    get: { store.incidentNotifications.preferences.playSound },
                    set: { store.incidentNotifications.preferences.playSound = $0 }))
                HStack {
                    Button("Send Test Notification") { Task { await store.incidentNotifications.sendTestNotification() } }.disabled(!store.incidentNotifications.canDeliver)
                    Button("Open macOS Notification Settings…") { store.incidentNotifications.openSystemSettings() }
                }
                if let error = store.incidentNotifications.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text("One alert per incident, then one recovery after two healthy checks at least 30 seconds apart. Confirmation uses extra lightweight checks, never bandwidth tests. Same-layer repeat alerts wait five minutes after recovery. Brief blips and assessments without an identified faulty layer stay in history without an incident alert. Durations describe the observed window, not an exact outage stopwatch.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Network issue notifications") }
            Section {
                Toggle("Also schedule bandwidth benchmarks", isOn: $store.settings.automaticBandwidthTests)
                    .disabled(!store.settings.automaticChecks)
                Picker("Bandwidth benchmark interval", selection: $store.settings.bandwidthIntervalHours) {
                    Text("Every 6 hours").tag(6); Text("Every 12 hours").tag(12); Text("Every 24 hours").tag(24)
                }.disabled(!store.settings.automaticChecks || !store.settings.automaticBandwidthTests)
                Text("Bandwidth tests can consume gigabytes per run and affect other traffic. They are off by default. Scheduled bandwidth tests skip Low Data Mode and paths macOS marks as expensive.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Optional bandwidth history") }
            Section {
                TextField("DNS benchmark domain", text: $store.settings.domain, prompt: Text("www.apple.com"))
                TextField("NextDNS resolver IPs", text: $store.settings.nextDNSResolvers, prompt: Text("Comma-separated IP addresses"))
                Text("Enter the resolver IPs from your NextDNS setup to compare upstream response times. Leave blank to skip direct NextDNS queries. Direct queries do not prove a specific NextDNS profile is being applied.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Normal HTTPS test URL", text: $store.settings.customWebsite)
            } header: { Text("DNS / NextDNS & HTTPS") }
            Section {
                TextField("Tailnet peer to test", text: $store.settings.tailscalePeer, prompt: Text("Automatic: an online tailnet peer"))
                Text("Leave empty to select one online peer automatically, or enter a 100.x.x.x IP / MagicDNS name for a consistent benchmark target. Tests report direct vs relay paths. Peer keys, login credentials, and the full peer inventory are not stored.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Tailscale") }
            Section {
                LabeledContent("Storage", value: "Native SQLite · on this Mac")
                Text(store.dataDirectory.path).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Reveal History Folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.dataDirectory.path) }
                    Button("Export JSON…") { store.exportHistory(csv: false) }
                    Button("Export CSV…") { store.exportHistory(csv: true) }
                    Button("Open MIT Source") {
                        if let url = URL(string: "https://github.com/andresark/network-culprit") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("Free and MIT licensed. No telemetry, account, AI service, or cloud storage. Diagnostic requests go to the providers and peers being tested. This app never changes network settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Privacy & source") }
        }.formStyle(.grouped).disabled(store.isDemonstration)
        .onAppear { store.loginItem.refresh(); Task { await store.incidentNotifications.refreshAuthorization() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.loginItem.refresh(); Task { await store.incidentNotifications.refreshAuthorization() } }
        }
    }
}
