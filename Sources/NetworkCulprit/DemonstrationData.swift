import Foundation

enum DemonstrationScenario: String, CaseIterable, Identifiable {
    case healthy = "All healthy", dnsIssue = "DNS issue", staleIPv6 = "Stale IPv6"
    var id: String { rawValue }
}

/// Documentation-only fixtures. Addresses use documentation ranges; no real
/// history, resolver profile, peer inventory, or network request is involved.
enum DemonstrationData {
    static func history(scenario: DemonstrationScenario, now: Date = Date()) -> [DiagnosticSnapshot] {
        (0..<36).map { index in
            var context = NetworkContext()
            context.interface = "en0"; context.publicTrafficInterface = "en0"
            context.gateway = "192.0.2.1"; context.resolvers = ["192.0.2.1"]
            context.ipv6Prefixes = ["2001:db8:100:1::/64"]
            context.linkMedia = "1000baseT · full-duplex · MTU 1500"
            let date = now.addingTimeInterval(Double(-index * 300))
            let baseline = Double(index % 5) * 0.8
            let hasIssue = scenario != .healthy && (index < 3 || (index >= 16 && index <= 19))
            let dnsFailure = hasIssue && scenario == .dnsIssue
            func probe(_ key: String, _ layer: NetworkLayer, _ name: String, _ target: String, _ milliseconds: Double,
                       _ detail: String, health: Health = .good) -> Probe {
                Probe(key: key, layer: layer, name: name, target: target, health: health, milliseconds: health == .failed ? nil : milliseconds,
                      detail: detail, evidence: "Illustrative sample measurement. No request was sent.")
            }
            var probes = [
                probe("local.link", .local, "Active network route", "en0", 0.5, "Ethernet · 1 Gbps full-duplex"),
                probe("local.router", .local, "Router latency & loss", "192.0.2.1", 1.2, "8/8 replies · 0% packet loss"),
                probe("internet.ping.cloudflare", .internet, "Internet latency & loss", "Sample public endpoint", 12 + baseline, "8/8 replies · 0% packet loss"),
                probe("internet.https.cloudflare", .internet, "Independent internet path", "Sample HTTPS endpoint", 24 + baseline, "TLS and HTTPS responded"),
                probe("dns.system", .dns, "System DNS", "www.example.com", 9 + baseline,
                      dnsFailure ? "System lookup timed out" : "System resolver answered", health: dnsFailure ? .failed : .good),
                probe("dns.router", .dns, "Router DNS", "192.0.2.1", 4.5, "Router DNS answered"),
                probe("dns.nextdns.primary", .dns, "NextDNS upstream", "Configured resolver (sample)", 8.2,
                      dnsFailure ? "Configured upstream timed out" : "Configured upstream answered", health: dnsFailure ? .failed : .good),
                probe("dns.control.cloudflare", .dns, "Independent DNS control", "Sample control resolver", 10.8, "Independent resolver answered"),
                probe("tailscale.service", .tailscale, "Tailscale service", "This Mac (sample)", 1, "Running · no service warnings"),
                probe("tailscale.peer", .tailscale, "Selected peer path", "sample-peer", 16.4 + baseline, "Direct path · selected sample peer responded"),
                probe("ipv6.prefix.good.sample", .ipv6, "IPv6 prefix reachability", "2001:db8:100:1::/64", 18.5, "2/2 independent HTTPS destinations answered"),
                probe("web.system", .web, "Normal HTTPS path", "https://www.example.com/", 45 + baseline, "HTTPS response received")
            ]
            if dnsFailure {
                probes.append(probe("dns.nextdns.secondary", .dns, "NextDNS secondary upstream", "Secondary resolver (sample)", 0,
                                    "Configured upstream timed out", health: .failed))
            }
            if hasIssue && scenario == .staleIPv6 {
                context.ipv6Prefixes.append("2001:db8:200:1::/64")
                probes.append(probe("ipv6.prefix.bad.sample", .ipv6, "IPv6 prefix reachability", "2001:db8:200:1::/64", 0,
                                    "0/2 destinations answered from the older range", health: .failed))
            }
            let benchmark = index % 6 == 3
            if benchmark {
                for (key, name, value, unit) in [("download", "Download capacity", 820.0 + Double(index % 7) * 8, "Mbps"),
                                                ("upload", "Upload capacity", 710.0 + Double(index % 9) * 7, "Mbps"),
                                                ("responsiveness", "Responsiveness", 1400.0 + Double(index % 6) * 40, "RPM")] {
                    probes.append(Probe(key: "speed.\(key)", layer: .internet, name: name, target: "Sample bandwidth test", health: .good,
                                        value: value, unit: unit, detail: "Illustrative sample; no bandwidth was used."))
                }
            }
            return DiagnosticSnapshot(date: date, kind: benchmark ? "Full benchmark" : "Quick check", context: context,
                                      probes: probes, finding: Attribution.evaluate(probes, context: context), duration: 12.4 + baseline)
        }
    }
}
