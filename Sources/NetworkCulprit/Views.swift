import SwiftUI
import Charts
import AppKit

extension Health {
    var color: Color {
        switch self { case .good: .green; case .warning: .orange; case .failed: .red; case .unavailable: .secondary }
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case overview = "Overview", history = "Diagnostic History", benchmarks = "Bandwidth Benchmarks", settings = "Monitoring Settings"
    var id: String { rawValue }
    var icon: String {
        switch self { case .overview: "gauge.with.dots.needle.50percent"; case .history: "clock.arrow.circlepath"; case .benchmarks: "speedometer"; case .settings: "slider.horizontal.3" }
    }
}

struct MainWindow: View {
    @Bindable var store: DiagnosticStore
    @NativeViewState private var selection: Destination? = .overview
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Network Culprit") {
                    ForEach(Destination.allCases) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                }
                Section("On this Mac") {
                    Label("Local history", systemImage: "internaldrive").foregroundStyle(.secondary)
                    Text("\(store.totalRecords) saved checks").font(.caption).foregroundStyle(.secondary)
                    Text(store.settings.automaticChecks ? "Sampling every \(store.settings.intervalSeconds / 60) min" : "Automatic sampling paused")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 230)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewScreen(store: store)
                case .history: HistoryScreen(store: store)
                case .benchmarks: BenchmarkScreen(store: store)
                case .settings: SettingsScreen(store: store)
                }
            }
            .navigationTitle((selection ?? .overview).rawValue)
            .toolbar {
                ToolbarItem(placement: .status) {
                    HStack(spacing: 6) {
                        if store.isRunning { ProgressView().controlSize(.small) }
                        Text(store.isRunning ? "Checking…" : store.lastCheck.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Ready to diagnose")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu { Button("JSON with evidence…") { store.exportHistory(csv: false) }; Button("CSV benchmarks…") { store.exportHistory(csv: true) } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    Button { store.run() } label: { Label("Run Check", systemImage: "arrow.clockwise") }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut("r", modifiers: .command).disabled(store.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ConnectionStatusBar(store: store)
            }
            .safeAreaInset(edge: .top) {
                if store.isDemonstration { DemonstrationBanner(store: store) }
            }
        }
        .alert("Network Culprit", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

private struct DemonstrationBanner: View {
    @Bindable var store: DiagnosticStore
    var body: some View {
        HStack(spacing: 16) {
            Label("Demo · Sample data", systemImage: "play.rectangle").font(.callout.weight(.semibold))
            Text("Offline · real history stays untouched").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Example", selection: Binding(get: { store.demonstrationScenario }, set: { store.showDemonstration($0) })) {
                ForEach(DemonstrationScenario.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width: 200)
        }.padding(.horizontal, 22).padding(.vertical, 10)
    }
}

struct StatusPill: View {
    var health: Health
    var text: String? = nil
    var body: some View {
        Label(text ?? health.title, systemImage: health.symbol)
            .font(.caption.weight(.medium)).foregroundStyle(health.color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .networkGlass(in: .capsule, tint: health.color.opacity(0.12))
    }
}

struct OverviewScreen: View {
    @Bindable var store: DiagnosticStore
    @NativeViewState private var selectedLayer: NetworkLayer?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let snapshot = store.latest {
                    FindingCard(finding: snapshot.finding)
                    HStack {
                        Text("The network stack").font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(snapshot.context.interface) · \(snapshot.context.gateway.isEmpty ? "No gateway" : snapshot.context.gateway)")
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    GlassEffectContainer(spacing: 10) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                            ForEach(NetworkLayer.allCases) { layer in
                                Button { selectedLayer = layer } label: { LayerCard(layer: layer, snapshot: snapshot) }
                                    .buttonStyle(.plain).accessibilityLabel("Inspect \(layer.rawValue)")
                            }
                        }
                    }
                    LatencyHistoryChart(history: store.history)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Evidence you can inspect", systemImage: "list.bullet.rectangle").font(.headline)
                            Text("Every saved check keeps individual results, response times, packet loss, context and raw evidence. Open a layer above to see why it is highlighted.")
                                .foregroundStyle(.secondary)
                            if let guardSummary = snapshot.context.guardSummary {
                                Label(guardSummary, systemImage: "wrench.and.screwdriver").font(.caption).textSelection(.enabled)
                            }
                            Text("Snapshot: \(snapshot.date.formatted(date: .abbreviated, time: .standard)) · \(snapshot.probes.count) measurements · \(snapshot.duration.formatted(.number.precision(.fractionLength(1)))) seconds")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                } else {
                    ContentUnavailableView {
                        Label(store.isRunning ? "Checking your network" : "Find the failing network layer", systemImage: "network")
                    } description: {
                        Text(store.isRunning ? "Comparing the router, independent internet paths, DNS, Tailscale, and IPv6. The first check usually takes 10–20 seconds." : "Run a diagnostic to start your local benchmark history.")
                    } actions: {
                        if store.isRunning { ProgressView() }
                        else { Button("Run First Diagnostic") { store.run() }.buttonStyle(.glassProminent) }
                    }.frame(minHeight: 460)
                }
            }.padding(24)
        }
        .sheet(item: $selectedLayer) { layer in
            LiveLayerDetailSheet(layer: layer, store: store)
        }
    }
}

struct FindingCard: View {
    var finding: Finding
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: finding.layer?.symbol ?? (finding.health == .good ? "checkmark.shield" : "waveform.path.ecg"))
                .font(.system(size: 29, weight: .medium)).foregroundStyle(finding.health.color)
                .frame(width: 58, height: 58)
                .networkGlass(in: .rect(cornerRadius: 17), tint: finding.health.color.opacity(0.13))
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(finding.health == .good ? "CURRENT ASSESSMENT" : "LIKELY CULPRIT").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(health: finding.health, text: "\(finding.confidence) confidence")
                }
                Text(finding.title).font(.system(.title, design: .rounded, weight: .semibold))
                Text(finding.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider().padding(.vertical, 2)
                Label { Text(finding.nextStep).font(.callout) } icon: { Image(systemName: "arrow.turn.down.right") }
            }
        }.padding(22).background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 18))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(finding.health.color).frame(width: 4).padding(.vertical, 20) }
    }
}

struct LayerCard: View {
    var layer: NetworkLayer
    var snapshot: DiagnosticSnapshot
    var primary: Probe? {
        let probes = snapshot.probes(for: layer)
        let wanted: String
        switch layer {
        case .local: wanted = "local.router"
        case .internet: wanted = "internet.ping.cloudflare"
        case .dns: wanted = "dns.system"
        case .tailscale: wanted = "tailscale.service"
        case .ipv6: wanted = "ipv6.prefix."
        case .web: wanted = "web.system"
        }
        return probes.first { $0.key.hasPrefix(wanted) } ?? probes.first
    }
    var body: some View {
        let health = snapshot.layerHealth(layer)
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(layer.rawValue, systemImage: layer.symbol).font(.headline); Spacer(); Image(systemName: health.symbol).foregroundStyle(health.color) }
            Text(layer == .dns ? snapshot.dnsAssessment.title : primary?.metric ?? "Not measured").font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(layer == .dns ? snapshot.dnsAssessment.detail : primary?.detail ?? "Run a diagnostic to measure this layer.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 34, alignment: .topLeading)
            HStack { Text("\(snapshot.probes(for: layer).filter { $0.health == .good }.count)/\(snapshot.probes(for: layer).count) checks passed"); Spacer(); Image(systemName: "chevron.right") }
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 18))
            .networkGlass(in: .rect(cornerRadius: 18),
                          tint: health == .warning || health == .failed ? health.color.opacity(0.13) : nil,
                          interactive: true)
    }
}

enum ChartSelection: String, CaseIterable { case latency = "Path latency", dns = "DNS", tailscale = "Tailscale", bandwidth = "Bandwidth" }
private struct ChartPoint: Identifiable { var id = UUID(); var date: Date; var value: Double; var series: String }

struct LatencyHistoryChart: View {
    var history: [DiagnosticSnapshot]
    @NativeViewState private var selection: ChartSelection = .latency
    @NativeViewState private var selectedDate: Date?
    init(history: [DiagnosticSnapshot], initialSelection: ChartSelection = .latency) {
        self.history = history
        self._selection = NativeViewState(initialValue: initialSelection)
    }
    private var points: [ChartPoint] {
        history.prefix(288).reversed().flatMap { snapshot in
            snapshot.probes.compactMap { probe -> ChartPoint? in
                switch selection {
                case .latency:
                    guard ["local.router", "internet.ping.cloudflare", "internet.ping.google"].contains(probe.key), let value = probe.milliseconds else { return nil }
                    return ChartPoint(date: snapshot.date, value: value, series: probe.name)
                case .dns:
                    guard probe.layer == .dns, probe.key != "dns.nextdns-identity", let value = probe.milliseconds else { return nil }
                    return ChartPoint(date: snapshot.date, value: value, series: probe.historySeriesName)
                case .bandwidth:
                    guard probe.key == "speed.download" || probe.key == "speed.upload", let value = probe.value else { return nil }
                    return ChartPoint(date: snapshot.date, value: value, series: probe.name)
                case .tailscale:
                    guard probe.layer == .tailscale, let value = probe.milliseconds else { return nil }
                    return ChartPoint(date: snapshot.date, value: value, series: "\(probe.name) · \(probe.target)")
                }
            }
        }
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Recorded performance", systemImage: "chart.xyaxis.line").font(.headline)
                    Spacer()
                    Picker("Metric", selection: $selection) { ForEach(ChartSelection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 390)
                }
                if points.isEmpty {
                    ContentUnavailableView(selection == .bandwidth ? "No bandwidth benchmarks yet" : "No measurements recorded", systemImage: "chart.xyaxis.line",
                                           description: Text(selection == .bandwidth ? "Run a manual bandwidth benchmark to start this history." : "Completed checks will appear here."))
                        .frame(height: 180)
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("Time", point.date), y: .value(selection == .bandwidth ? "Mbps" : "ms", point.value))
                            .foregroundStyle(by: .value("Measurement", point.series))
                        PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                            .foregroundStyle(by: .value("Measurement", point.series)).symbolSize(18)
                    }
                    .chartXSelection(value: $selectedDate)
                    .chartLegend(position: .bottom, alignment: .leading)
                    .chartYAxisLabel(selection == .bandwidth ? "Mbps" : "Milliseconds")
                    .frame(height: 210)
                }
                HStack {
                    Text("Latest \(min(history.count, 288)) saved checks · gaps and failures are preserved in history")
                    Spacer()
                    if let selectedDate { Text(selectedDate.formatted(date: .abbreviated, time: .standard)) }
                }.font(.caption2).foregroundStyle(.secondary)
            }.padding(10)
        }
    }
}

// Observe the store inside the presented view so an open sheet follows new
// samples. History detail sheets intentionally keep their selected snapshot.
struct LiveLayerDetailSheet: View {
    var layer: NetworkLayer
    @Bindable var store: DiagnosticStore
    var body: some View {
        Group {
            if let snapshot = store.latest {
                LayerDetailSheet(layer: layer, snapshot: snapshot, isRunning: store.isRunning,
                                 refresh: store.isDemonstration ? nil : { store.run() })
            }
        }
        .task { store.run() }
    }
}

struct LayerDetailSheet: View {
    var layer: NetworkLayer
    var snapshot: DiagnosticSnapshot
    var isRunning = false
    var refresh: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private var orderedProbes: [Probe] {
        func priority(_ health: Health) -> Int {
            switch health { case .failed: 0; case .warning: 1; case .good: 2; case .unavailable: 3 }
        }
        return snapshot.probes(for: layer).sorted {
            if priority($0.health) != priority($1.health) { return priority($0.health) < priority($1.health) }
            return ($0.name, $0.target) < ($1.name, $1.target)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(layer.rawValue, systemImage: layer.symbol).font(.title2.weight(.semibold))
                Spacer()
                if let refresh {
                    Button(action: refresh) { Label(isRunning ? "Checking…" : "Check Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.glassProminent).disabled(isRunning)
                }
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(health: snapshot.layerHealth(layer))
                    if layer == .dns { Text(snapshot.dnsAssessment.title).font(.headline) }
                    Spacer()
                    if isRunning { ProgressView().controlSize(.small) }
                }
                if layer == .dns { Text(snapshot.dnsAssessment.detail).font(.callout).foregroundStyle(.secondary) }
                Text("\(isRunning ? "Checking now · previous result" : "Measured"): \(snapshot.date.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(orderedProbes) { probe in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack { Text(probe.name).font(.headline); Spacer(); StatusPill(health: probe.health); Text(probe.metric).monospacedDigit().bold() }
                                Text(probe.target).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(probe.detail).textSelection(.enabled)
                                if !probe.evidence.isEmpty {
                                    DisclosureGroup("Diagnostic evidence") { Text(probe.evidence).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    }
                }.padding(20)
            }
        }.frame(minWidth: 750, idealWidth: 850, minHeight: 520, idealHeight: 650)
    }
}
