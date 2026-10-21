import Foundation

enum NetworkLayer: String, Codable, CaseIterable, Identifiable, Sendable {
    case local = "Local network", internet = "Internet / ISP", dns = "DNS / NextDNS"
    case tailscale = "Tailscale", ipv6 = "IPv6", web = "Web / TLS"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .local: "network"
        case .internet: "globe"
        case .dns: "server.rack"
        case .tailscale: "point.3.connected.trianglepath.dotted"
        case .ipv6: "arrow.triangle.branch"
        case .web: "lock.shield"
        }
    }
}

enum Health: String, Codable, Sendable {
    case good, warning, failed, unavailable
    var title: String {
        switch self { case .good: "Healthy"; case .warning: "Investigate"; case .failed: "Failing"; case .unavailable: "Not measured" }
    }
    var symbol: String {
        switch self { case .good: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .failed: "xmark.octagon.fill"; case .unavailable: "minus.circle" }
    }
}

struct Probe: Codable, Identifiable, Sendable {
    var id = UUID()
    var key: String
    var layer: NetworkLayer
    var name: String
    var target: String
    var health: Health
    var milliseconds: Double?
    var packetLoss: Double?
    var value: Double?
    var unit: String?
    var detail: String
    var evidence: String = ""
    // Older fresh-query records used a unique hostname as their target. Group
    // them with current records without rewriting any saved diagnostic data.
    var historySeriesName: String { key == "dns.system.fresh" ? name : "\(name) · \(target)" }
    var metric: String {
        if let value { return String(format: "%.0f %@", value, unit ?? "") }
        if let milliseconds { return String(format: "%.1f ms", milliseconds) }
        return health == .good ? "Passed" : health.title
    }
}

struct NetworkContext: Codable, Sendable {
    var interface = "Unknown"
    var publicTrafficInterface = "Unknown"
    var gateway = ""
    var localAddresses: [String] = []
    var ipv6Prefixes: [String] = []
    var resolvers: [String] = []
    var proxySummary = "No system proxy configured"
    var wifiRSSI: Int?
    var wifiNoise: Int?
    var wifiLinkMbps: Double?
    var trafficUsesVPN = false
    var guardSummary: String?
    var interfaceInputErrors: UInt64?
    var interfaceOutputErrors: UInt64?
    var linkMedia: String?
}

struct Finding: Codable, Sendable {
    var title: String
    var explanation: String
    var health: Health
    var layer: NetworkLayer?
    var confidence: String
    var evidence: [String]
    var nextStep: String
}

struct DiagnosticSnapshot: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var kind = "Quick check"
    var context: NetworkContext
    var probes: [Probe]
    var finding: Finding
    var duration: Double
    func probes(for layer: NetworkLayer) -> [Probe] { probes.filter { $0.layer == layer } }
    func layerHealth(_ layer: NetworkLayer) -> Health {
        if finding.layer == layer && finding.health != .good { return finding.health }
        if layer == .dns { return dnsAssessment.health }
        let measured = probes(for: layer).filter { $0.health != .unavailable }
        if measured.isEmpty { return .unavailable }
        if measured.allSatisfy({ $0.health == .good }) { return .good }
        // A failed single endpoint does not establish that an entire layer failed.
        return .warning
    }
}

struct DNSAssessment {
    var health: Health
    var title: String
    var detail: String
    var evidence: [Probe]
}

extension DiagnosticSnapshot {
    var dnsAssessment: DNSAssessment { DNSAssessment.evaluate(probes) }
}

extension DNSAssessment {
    static func evaluate(_ probes: [Probe]) -> DNSAssessment {
        let dns = probes.filter { $0.layer == .dns }
        let failures = dns.filter { $0.health == .failed }
        let concerns = dns.filter { $0.health == .failed || $0.health == .warning }
        let systemFailed = dns.contains { ($0.key == "dns.system" || $0.key == "dns.system.fresh") && $0.health == .failed }
        if systemFailed {
            return DNSAssessment(health: .failed, title: "System DNS is failing",
                                 detail: "The Mac's system resolver did not complete a lookup. Cached or alternative DNS paths may still answer.", evidence: concerns)
        }
        if !concerns.isEmpty {
            let freshWorks = dns.contains { $0.key == "dns.system.fresh" && $0.health == .good }
            return DNSAssessment(health: .warning,
                                 title: failures.isEmpty ? "DNS needs attention" : "\(failures.count) DNS check\(failures.count == 1 ? "" : "s") failed",
                                 detail: "\(freshWorks ? "Fresh system DNS answered" : "Some lookups answered, potentially from cache"), but individual resolver paths need attention. Open the evidence to compare them.", evidence: concerns)
        }
        let measured = dns.filter { $0.health != .unavailable }
        return DNSAssessment(health: measured.isEmpty ? .unavailable : .good,
                             title: measured.isEmpty ? "DNS not measured" : "DNS checks passed",
                             detail: dns.contains { $0.key == "dns.system.fresh" && $0.health == .good } ? "A unique system query and the measured resolver paths answered." : "Saved resolver checks passed. A cached hostname lookup alone does not verify live DNS.", evidence: [])
    }
}

struct DiagnosticSettings: Codable, Sendable {
    var automaticChecks = true
    var automaticBandwidthTests = false
    var bandwidthIntervalHours = 6
    var intervalSeconds = 300
    var retentionDays = 90
    var domain = "www.apple.com"
    var nextDNSResolvers = ""
    var tailscalePeer = ""
    var customWebsite = "https://www.apple.com/"
}

enum Attribution {
    static func evaluate(_ probes: [Probe], context: NetworkContext) -> Finding {
        func named(_ key: String) -> Probe? { probes.first { $0.key == key } }
        func successful(_ prefix: String) -> Bool { probes.contains { $0.key.hasPrefix(prefix) && $0.health == .good } }
        func failed(_ prefix: String) -> Bool {
            let group = probes.filter { $0.key.hasPrefix(prefix) && $0.health != .unavailable }
            return !group.isEmpty && group.allSatisfy { $0.health == .failed }
        }
        func finding(_ title: String, _ text: String, _ layer: NetworkLayer, _ confidence: String,
                     _ evidence: [String], _ step: String, health: Health = .failed) -> Finding {
            Finding(title: title, explanation: text, health: health, layer: layer,
                    confidence: confidence, evidence: evidence, nextStep: step)
        }
        if context.interface == "Unknown" || named("local.link")?.health == .failed {
            return finding("Local connection is down", "No active route to the network was found.", .local, "High",
                           ["The Mac has no usable default route."], "Check the Ethernet cable, adapter, Wi-Fi connection, and router power.")
        }
        if successful("ipv6.prefix.good") && failed("ipv6.prefix.bad") {
            return finding("IPv6 prefix selection is failing", "One local IPv6 range works while another cannot reach either independent destination.", .ipv6, "High",
                           ["A working IPv6 range proves that IPv6 service is available.", "Another range fails both HTTPS destinations."],
                           "Review the router's prefix changes and the automatic IPv6 repair log. A reconnect can clear stale addresses.")
        }
        let directWorks = successful("internet.https")
        if probes.contains(where: { $0.evidence.localizedCaseInsensitiveContains("operation not permitted") || $0.evidence.localizedCaseInsensitiveContains("policy denied") }) {
            return finding("Local network access may be blocked", "A diagnostic was denied by system policy. A permission failure should be resolved before blaming a router or DNS provider.", .local, "Medium",
                           ["A probe returned a permission or policy denial."], "Check System Settings → Privacy & Security → Local Network for Network Culprit.", health: .warning)
        }
        let systemDNSFailed = named("dns.system")?.health == .failed || named("dns.system.fresh")?.health == .failed
        let controlWorks = successful("dns.control")
        if systemDNSFailed && (directWorks || controlWorks) {
            if failed("dns.nextdns.") && controlWorks {
                return finding("NextDNS path is the likely culprit", "System resolution and both configured NextDNS upstream tests failed while an independent resolver answered.", .dns, "Medium",
                               ["Independent public DNS responds.", "Configured NextDNS upstreams do not respond."], "Check NextDNS service status, linked-IP/profile configuration, and access to its resolver addresses. This cannot distinguish NextDNS itself from filtering on the path.")
            }
            if failed("dns.tailscale") && successful("dns.router") {
                return finding("Tailscale DNS forwarding is failing", "The router's DNS answers, but the Tailscale resolver and normal system resolution fail.", .dns, "High",
                               ["Router DNS works.", "Tailscale DNS and system resolution fail."], "Inspect Tailscale DNS settings, upstream nameservers, exit node, and the local Tailscale service.")
            }
            if failed("dns.router") && (successful("dns.nextdns.") || controlWorks) {
                return finding("Router DNS forwarding is failing", "Public DNS or the NextDNS upstream answers directly, while the router resolver and system resolution fail.", .dns, "High",
                               ["The internet is reachable without hostname resolution.", "The router's DNS proxy does not answer."], "Inspect the router's DNS forwarding and configured upstreams. IPv6 resets will not repair this condition.")
            }
            return finding("DNS resolution is failing", "Direct connectivity works, but the Mac's normal hostname lookup does not.", .dns, "High",
                           ["Direct connectivity or independent DNS works.", "The system resolver timed out or returned no address."], "Compare the configured, router, NextDNS, and Tailscale resolver rows below.")
        }
        let resolverFailures = probes.filter {
            $0.layer == .dns && $0.health == .failed &&
            ["dns.router.", "dns.nextdns.", "dns.configured.", "dns.tailscale."].contains(where: $0.key.hasPrefix)
        }
        if directWorks && !resolverFailures.isEmpty {
            return finding("Some DNS resolver paths are failing", "The internet is reachable and some system or alternative DNS lookups may work, but direct queries to \(resolverFailures.count) resolver path\(resolverFailures.count == 1 ? "" : "s") failed. Cached results or encrypted/VPN DNS can conceal these failures.", .dns, "Measured",
                           resolverFailures.map { "\($0.name): \($0.detail)" },
                           "Open DNS / NextDNS and compare the fresh system query with the failing resolver rows. Direct UDP failures alone do not establish a NextDNS service outage.", health: .warning)
        }
        if !directWorks && failed("internet.https") && !successful("internet.ping") && named("local.router")?.packetLoss == 100 {
            return finding("Local gateway path is unreachable", "The router and independent internet destinations do not answer. A local router, cable, adapter, or access-point problem is more likely than a DNS-only fault.", .local, "Medium",
                           ["Router ICMP probes failed.", "Independent internet checks also failed."], "Check local network permission for this app, the cable/adapter, Wi-Fi signal, and router power. Routers can filter ICMP, so confirm on another device.")
        }
        if !directWorks && failed("internet.https") {
            if successful("internet.ping") {
                return finding("HTTPS or TLS path needs attention", "Public IPs answer ICMP, but HTTPS to two independent providers fails.", .web, "Medium",
                               ["Public IP connectivity exists.", "Independent HTTPS connections fail."], "Inspect VPN filtering, proxies, endpoint protection, system time, and TLS errors.")
            }
            return finding(context.trafficUsesVPN ? "VPN or upstream path is failing" : "Upstream internet path is failing",
                           "The local route exists, but independent internet destinations fail. A Mac-only test cannot distinguish ISP service, the ONT, or the router's WAN side.", .internet, "Medium",
                           ["A local default route exists.", "Multiple public destinations failed."], "Check another device, router WAN status, and ONT. If an exit node is active, compare with it disconnected manually.")
        }
        if named("tailscale.peer")?.health == .failed {
            return finding("Tailscale peer path is failing", "The public internet is reachable but the configured tailnet peer did not answer.", .tailscale, "Medium",
                           ["Public internet checks succeed.", "The selected peer path failed."], "Confirm that the peer is online, then inspect tailnet access rules, direct/relay connectivity, and Tailscale service status.")
        }
        if named("web.system")?.health == .failed && directWorks {
            return finding("System web path differs from direct connectivity", "DNS-independent internet checks pass, but a normal app-style HTTPS request fails.", .web, "Medium",
                           ["Direct HTTPS works.", "The system HTTPS path fails."], "Review system DNS, proxy/PAC configuration, TLS filtering, and the requested site's status.")
        }
        let warnings = probes.filter { $0.health == .warning || $0.health == .failed }
        if let errors = named("local.interface-errors"), errors.health == .warning {
            return finding("Local link errors are increasing", "The network interface reported new input/output errors since the previous comparable sample.", .local, "Medium",
                           [errors.detail], "Inspect the Ethernet cable, switch/router port, adapter, or Wi-Fi signal. Compare error growth with packet-loss history.", health: .warning)
        }
        if let loss = probes.first(where: { $0.layer == .internet && ($0.packetLoss ?? 0) >= 10 }), directWorks {
            return finding("Internet packet loss needs watching", "HTTPS works, but a short ICMP sample lost packets. ICMP rate limiting can produce this result without application loss.", .internet, "Low",
                           ["\(loss.target): \(Int(loss.packetLoss ?? 0))% ICMP loss.", "HTTPS connectivity works."], "Repeat the check and compare history before attributing loss to the ISP.", health: .warning)
        }
        if !warnings.isEmpty {
            return Finding(title: "Connected, with signals to inspect", explanation: "Core connectivity works. Some individual tests were slow, unavailable, or failed; no single culprit is established.", health: .warning, layer: nil,
                           confidence: "Limited", evidence: warnings.prefix(3).map { "\($0.name): \($0.detail)" }, nextStep: "Review the highlighted rows and compare neighboring history samples.")
        }
        return Finding(title: "No fault detected in this sample", explanation: "The measured network paths responded. This is a point-in-time result, not a guarantee against intermittent issues.", health: .good, layer: nil,
                       confidence: "Measured", evidence: ["Independent connectivity and resolver tests completed."], nextStep: "Keep lightweight monitoring running to capture the next interruption.")
    }
}
