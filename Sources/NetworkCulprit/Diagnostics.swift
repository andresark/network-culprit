import Foundation
import CoreWLAN
import SystemConfiguration
import Darwin

enum DiagnosticEngine {
    static func capture(settings: DiagnosticSettings, speedTest: Bool = false) async -> DiagnosticSnapshot {
        let start = Date()
        let (context, interfaceText) = await contextSnapshot()
        var probes = [Probe(key: "local.link", layer: .local, name: "Active network route", target: context.interface,
                            health: context.interface == "Unknown" || interfaceText.contains("status: inactive") ? .failed : .good,
                            detail: "Public traffic uses \(context.publicTrafficInterface). \(context.proxySummary)")]
        if let media = context.linkMedia {
            probes.append(Probe(key: "local.link-media", layer: .local, name: "Negotiated link & MTU", target: context.interface, health: .good,
                                detail: media + " · interface errors in/out: \(context.interfaceInputErrors ?? 0)/\(context.interfaceOutputErrors ?? 0). Cumulative counters; see history for changes."))
        }
        if let rssi = context.wifiRSSI {
            probes.append(Probe(key: "local.wifi", layer: .local, name: "Wi-Fi radio quality", target: context.interface,
                                health: rssi < -72 ? .warning : .good, value: Double(rssi), unit: "dBm",
                                detail: "Noise \(context.wifiNoise ?? 0) dBm · link \(Int(context.wifiLinkMbps ?? 0)) Mbps. Link rate is not ISP throughput."))
        }
        await withTaskGroup(of: [Probe].self) { group in
            if !context.gateway.isEmpty {
                group.addTask { [context] in [await ping(context.gateway, key: "local.router", layer: .local, name: "Router latency & loss")] }
            }
            group.addTask { [await ping("1.1.1.1", key: "internet.ping.cloudflare", layer: .internet, name: "Cloudflare latency & loss")] }
            group.addTask { [await ping("8.8.8.8", key: "internet.ping.google", layer: .internet, name: "Google latency & loss")] }
            group.addTask { [await directHTTPS(host: "one.one.one.one", ip: "1.1.1.1", key: "internet.https.cloudflare", layer: .internet)] }
            group.addTask { [await directHTTPS(host: "dns.google", ip: "8.8.8.8", key: "internet.https.google", layer: .internet)] }
            group.addTask { [await systemDNS(settings.domain)] }
            group.addTask { [await systemWeb(settings.customWebsite)] }
            group.addTask { await nextDNSIdentity() }
            group.addTask { await tailscale(settings: settings) }
            var servers: [(String, String, String)] = []
            for ip in context.resolvers.prefix(6) {
                let role = ip == "100.100.100.100" || ip.hasPrefix("fd7a:") ? "tailscale" : ip == context.gateway || ip.hasSuffix("::1") ? "router" : "configured"
                servers.append((ip, role, role == "tailscale" ? "Tailscale DNS" : role == "router" ? "Router DNS" : "Configured DNS"))
            }
            let nextDNS = settings.nextDNSResolvers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { validIP($0) }
            for ip in nextDNS.prefix(2) { servers.append((ip, "nextdns", "NextDNS upstream")) }
            servers.append(("1.1.1.1", "control.cloudflare", "Cloudflare DNS control"))
            servers.append(("8.8.8.8", "control.google", "Google DNS control"))
            for (ip, role, label) in servers {
                group.addTask { [await resolver(ip, role: role, name: label, domain: settings.domain)] }
            }
            let addresses = TextParse.publicIPv6Addresses(interfaceText)
            let groups = Dictionary(grouping: addresses, by: { TextParse.prefix($0) ?? $0 })
            if groups.isEmpty {
                probes.append(Probe(key: "ipv6.unavailable", layer: .ipv6, name: "Public IPv6", target: context.interface, health: .unavailable,
                                    detail: "No usable public IPv6 address. IPv4 connectivity is measured separately."))
            } else {
                for (prefix, addresses) in groups.sorted(by: { $0.key < $1.key }).prefix(4) {
                    guard let source = addresses.last else { continue }
                    group.addTask {
                        async let first = directHTTPS(host: "one.one.one.one", ip: "2606:4700:4700::1111", key: "ipv6.test", layer: .ipv6, source: source)
                        async let second = directHTTPS(host: "dns.google", ip: "2001:4860:4860::8888", key: "ipv6.test", layer: .ipv6, source: source)
                        let results = await [first, second]
                        let works = results.contains { $0.health == .good }
                        return [Probe(key: "ipv6.prefix.\(works ? "good" : "bad").\(prefix)", layer: .ipv6,
                                      name: "IPv6 prefix reachability", target: prefix, health: works ? .good : .failed,
                                      milliseconds: results.compactMap(\.milliseconds).min(),
                                      detail: "\(results.filter { $0.health == .good }.count)/2 independent HTTPS destinations answered.",
                                      evidence: results.map { "\($0.target): \($0.detail)\n\($0.evidence)" }.joined(separator: "\n"))]
                    }
                }
            }
            for await results in group { probes.append(contentsOf: results) }
        }
        // Keep baseline packet-loss/DNS probes separate from a saturating test.
        if speedTest { probes.append(contentsOf: await networkQuality(interface: context.interface)) }
        probes.sort { $0.layer.rawValue == $1.layer.rawValue ? $0.name < $1.name : $0.layer.rawValue < $1.layer.rawValue }
        return DiagnosticSnapshot(kind: speedTest ? "Full benchmark" : "Quick check", context: context, probes: probes,
                                  finding: Attribution.evaluate(probes, context: context), duration: Date().timeIntervalSince(start))
    }

    static func contextSnapshot() async -> (NetworkContext, String) {
        async let routeResult = SystemCommand.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
        async let publicResult = SystemCommand.run("/sbin/route", ["-n", "get", "1.1.1.1"], timeout: 3)
        async let dnsResult = SystemCommand.run("/usr/sbin/scutil", ["--dns"], timeout: 3)
        let (route, traffic, dns) = await (routeResult, publicResult, dnsResult)
        var context = NetworkContext()
        context.interface = TextParse.first("interface:\\s*(\\S+)", in: route.text) ?? "Unknown"
        context.publicTrafficInterface = TextParse.first("interface:\\s*(\\S+)", in: traffic.text) ?? context.interface
        context.trafficUsesVPN = context.publicTrafficInterface.hasPrefix("utun")
        context.gateway = TextParse.first("gateway:\\s*([0-9.]+)", in: route.text) ?? ""
        context.resolvers = TextParse.dnsServers(dns.text)
        let interface = context.interface == "Unknown" ? CommandResult(text: "", exitCode: 0, seconds: 0, timedOut: false) : await SystemCommand.run("/sbin/ifconfig", ["-L", context.interface])
        context.localAddresses = TextParse.all("inet6? ([0-9a-fA-F:.]+)", in: interface.text)
        context.ipv6Prefixes = Array(Set(TextParse.publicIPv6Addresses(interface.text).compactMap(TextParse.prefix))).sorted()
        context.linkMedia = TextParse.first("media:\\s*([^\\n]+)", in: interface.text).map { $0 + " · MTU " + (TextParse.first("mtu (\\d+)", in: interface.text) ?? "unknown") }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            var current = interfaces
            while let entry = current {
                let value = entry.pointee
                if String(cString: value.ifa_name) == context.interface, value.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let pointer = value.ifa_data {
                    let data = pointer.assumingMemoryBound(to: if_data.self).pointee
                    context.interfaceInputErrors = UInt64(data.ifi_ierrors); context.interfaceOutputErrors = UInt64(data.ifi_oerrors)
                }
                current = value.ifa_next
            }
            freeifaddrs(interfaces)
        }
        if let proxy = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            let names = [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"), ("ProxyAutoConfigEnable", "PAC")]
                .filter { (proxy[$0.0] as? NSNumber)?.boolValue == true }.map(\.1)
            if !names.isEmpty { context.proxySummary = "System proxy: " + names.joined(separator: ", ") }
        }
        if let wifi = CWWiFiClient.shared().interface(withName: context.interface), wifi.rssiValue() != 0 {
            context.wifiRSSI = wifi.rssiValue(); context.wifiNoise = wifi.noiseMeasurement(); context.wifiLinkMbps = wifi.transmitRate()
        }
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Ethernet IPv6 Stale Prefix Automatic Repair")
        if let data = try? Data(contentsOf: base.appending(path: "latest-ipv6-prefix-check.json")),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            context.guardSummary = "Ethernet IPv6 automatic repair: \(state["mode"] as? String ?? "unknown") · \(state["status"] as? String ?? "unknown") · \(state["checked_at"] as? String ?? "")"
        }
        return (context, interface.text)
    }

    static func validIP(_ string: String) -> Bool {
        var a = in_addr(), b = in6_addr()
        return inet_pton(AF_INET, string, &a) == 1 || inet_pton(AF_INET6, string, &b) == 1
    }

    static func ping(_ target: String, key: String, layer: NetworkLayer, name: String) async -> Probe {
        let result = await SystemCommand.run("/sbin/ping", ["-n", "-c", "8", "-i", "0.2", "-W", "1000", target], timeout: 5)
        return TextParse.ping(result, key: key, layer: layer, name: name, target: target)
    }

    static func directHTTPS(host: String, ip: String, key: String, layer: NetworkLayer, source: String? = nil) async -> Probe {
        let v6 = ip.contains(":")
        var args = [v6 ? "-6" : "-4", "--noproxy", "*", "--resolve", "\(host):443:\(v6 ? "[\(ip)]" : ip)", "-sS", "-I", "-o", "/dev/null", "--connect-timeout", "3", "--max-time", "5", "-w", "NC_METRICS %{http_code} %{time_connect} %{time_appconnect} %{time_total}"]
        if let source { args += ["--interface", source] }
        args.append("https://\(host)/")
        let result = await SystemCommand.run("/usr/bin/curl", args, timeout: 6)
        let code = TextParse.first("NC_METRICS (\\d+)", in: result.text).flatMap(Int.init) ?? 0
        let seconds = TextParse.first("NC_METRICS \\d+ ([0-9.]+)", in: result.text).flatMap(Double.init)
        let healthy = result.exitCode == 0 && code > 0
        return Probe(key: key, layer: layer, name: "\(host) direct HTTPS", target: ip, health: healthy ? .good : .failed,
                     milliseconds: healthy ? seconds.map { $0 * 1000 } : nil,
                     detail: healthy ? "TLS verified · HTTP \(code) · DNS bypassed" : "Direct HTTPS failed\(result.timedOut ? " (timeout)" : "")",
                     evidence: result.text)
    }

    static func resolver(_ ip: String, role: String, name: String, domain: String) async -> Probe {
        var results: [DNSReply] = []
        for _ in 0..<3 { results.append(await DNSWire.measure(server: ip, domain: domain)) }
        let good = results.filter { $0.error == nil && $0.code == 0 && $0.answers > 0 }
        let answered = results.filter { $0.error == nil }
        let median = good.map(\.milliseconds).sorted().dropFirst(good.count / 2).first
        let health: Health = good.count == 3 && (median ?? 0) <= 250 ? .good : !answered.isEmpty ? .warning : .failed
        return Probe(key: "dns.\(role).\(ip)", layer: .dns, name: name, target: ip, health: health,
                     milliseconds: median, detail: "\(good.count)/3 successful A queries for \(domain)\(median == nil ? "" : " · median response")",
                     evidence: results.enumerated().map { "Query \($0.offset + 1): \(String(format: "%.1f", $0.element.milliseconds)) ms; rcode=\($0.element.code); answers=\($0.element.answers); \($0.element.error ?? "response received")" }.joined(separator: "\n"))
    }

    static func systemDNS(_ domain: String) async -> Probe {
        guard DNSWire.query(domain, id: 1) != nil else {
            return Probe(key: "dns.system", layer: .dns, name: "System hostname lookup", target: domain, health: .unavailable, detail: "Enter a valid DNS test domain in Settings.")
        }
        let result = await SystemCommand.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", domain], timeout: 6)
        let works = result.text.contains("ip_address:") || result.text.contains("ipv6_address:")
        return Probe(key: "dns.system", layer: .dns, name: "System hostname lookup", target: domain, health: works ? .good : .failed,
                     milliseconds: works ? result.seconds * 1000 : nil, detail: works ? "Normal macOS resolver answered; cache and process time included" : "Normal macOS resolver returned no address or timed out", evidence: result.text)
    }

    static func systemWeb(_ address: String) async -> Probe {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            return Probe(key: "web.system", layer: .web, name: "Normal app HTTPS path", target: address, health: .unavailable, detail: "Enter an HTTPS URL without embedded credentials.")
        }
        let start = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 7
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Probe(key: "web.system", layer: .web, name: "Normal app HTTPS path", target: address, health: .good,
                         milliseconds: Date().timeIntervalSince(start) * 1000, detail: "URLSession · HTTP \(code) · system DNS/proxy/TLS path", evidence: "HTTP status \(code). TLS is verified by URLSession. Latency includes DNS, TLS and server response.")
        } catch {
            return Probe(key: "web.system", layer: .web, name: "Normal app HTTPS path", target: address, health: .failed,
                         detail: error.localizedDescription, evidence: String(describing: error))
        }
    }

    static func nextDNSIdentity() async -> [Probe] {
        let result = await SystemCommand.run("/usr/bin/curl", ["-sS", "-L", "--max-redirs", "4", "--connect-timeout", "3", "--max-time", "5", "https://test.nextdns.io"], timeout: 6)
        guard let info = TextParse.jsonObject(result.standardOutput) else {
            return [Probe(key: "dns.nextdns-identity", layer: .dns, name: "NextDNS identity endpoint", target: "test.nextdns.io", health: .unavailable,
                          detail: "Identity could not be fetched. Direct resolver benchmarks are independent of this endpoint.", evidence: "Command exit: \(result.exitCode); timed out: \(result.timedOut); response bytes: \(result.text.utf8.count)")]
        }
        let status = info["status"] as? String ?? "unknown"
        let description = ["status", "protocol", "profile", "server"].compactMap { key in info[key].map { "\(key): \($0)" } }.joined(separator: " · ")
        return [Probe(key: "dns.nextdns-identity", layer: .dns, name: "NextDNS identity endpoint", target: "test.nextdns.io", health: .good,
                      detail: status == "ok" ? "NextDNS reports active · \(description)" : "Current resolver identity: \(description)", evidence: description)]
    }

    static func tailscale(settings: DiagnosticSettings) async -> [Probe] {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return [Probe(key: "tailscale.service", layer: .tailscale, name: "Tailscale service", target: "This Mac", health: .unavailable, detail: "Tailscale CLI is not installed in a supported location.")]
        }
        return await tailscale(settings: settings, executable: executable)
    }

    static func tailscale(settings: DiagnosticSettings, executable: String) async -> [Probe] {
        let status = await TailscaleCLI.run(executable, ["status", "--json"], timeout: 5)
        guard status.exitCode == 0, !status.timedOut,
              let info = TextParse.jsonObject(status.standardOutput), let backend = info["BackendState"] as? String, !backend.isEmpty else {
            return [Probe(key: "tailscale.service", layer: .tailscale, name: "Tailscale service", target: "This Mac", health: .warning,
                          detail: "The Tailscale CLI did not return usable service status. This diagnostic could not assess the VPN; it does not establish a VPN outage. Confirm that the Tailscale app is running and retry.",
                          evidence: "CLI mode explicitly requested. Command exit: \(status.exitCode); timed out: \(status.timedOut); stdout bytes: \(status.standardOutput.utf8.count); stderr bytes: \(status.standardError.utf8.count). Raw peer data is not retained.")]
        }
        let health = (info["Health"] as? [String] ?? []).joined(separator: " · ")
        var probes = [Probe(key: "tailscale.service", layer: .tailscale, name: "Tailscale service", target: "This Mac",
                            health: backend == "Running" ? (health.isEmpty ? .good : .warning) : .unavailable,
                            detail: "\(backend)\(health.isEmpty ? "" : " · \(health)")", evidence: "Backend: \(backend)\nHealth: \(health.isEmpty ? "No service warnings" : health)\nPeer identities and node keys are not stored.")]
        guard backend == "Running" else { return probes }
        let check = await TailscaleCLI.run(executable, ["netcheck", "--format", "json"], timeout: 10)
        if check.exitCode == 0, !check.timedOut, let net = TextParse.jsonObject(check.standardOutput) {
            let udp = net["UDP"] as? Bool ?? false
            let region = net["PreferredDERP"] as? Int ?? net["NearestDERP"] as? Int ?? 0
            let latency = (net["RegionLatency"] as? [String: Double])?[String(region)].map { $0 / 1_000_000 }
            probes.append(Probe(key: "tailscale.transport", layer: .tailscale, name: "Tailscale transport / relay", target: "Tailscale STUN & DERP",
                                health: udp ? .good : .warning, milliseconds: latency, detail: "UDP \(udp ? "available" : "unavailable") · nearest relay region \(region). This does not prove any peer is reachable.",
                                evidence: "UDP: \(udp)\nIPv4: \(net["IPv4"] ?? "unknown")\nIPv6: \(net["IPv6"] ?? "unknown")\nNearest DERP: \(region)"))
        } else {
            probes.append(Probe(key: "tailscale.transport", layer: .tailscale, name: "Tailscale transport / relay", target: "Tailscale netcheck", health: .warning,
                                detail: "Transport check did not complete; service status alone cannot establish tailnet connectivity.", evidence: check.text))
        }
        var peer = settings.tailscalePeer.trimmingCharacters(in: .whitespacesAndNewlines)
        var peerLabel = peer
        if peer.isEmpty, let peers = info["Peer"] as? [String: [String: Any]] {
            let online = peers.values.filter { $0["Online"] as? Bool == true }.sorted { ($0["HostName"] as? String ?? "") < ($1["HostName"] as? String ?? "") }
            if let selected = online.first, let ip = (selected["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") }) {
                peer = ip; peerLabel = "\(selected["HostName"] as? String ?? "Online peer") · \(ip) (automatic)"
            }
        }
        if !peer.isEmpty && peer.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil {
            let result = await TailscaleCLI.run(executable, ["ping", "--until-direct=false", "--c", "3", "--timeout", "3s", peer], timeout: 11)
            let times = TextParse.all("in ([0-9.]+)ms", in: result.text).compactMap(Double.init)
            let answered = result.exitCode == 0 && !result.timedOut && result.standardOutput.contains("pong from")
            probes.append(Probe(key: "tailscale.peer", layer: .tailscale, name: "Tailnet peer path", target: peerLabel,
                                health: answered ? .good : .failed,
                                milliseconds: times.isEmpty ? nil : times.reduce(0, +) / Double(times.count),
                                detail: answered ? "\(times.count) responses · \(result.text.contains("via DERP") ? "relay observed" : "direct path"). Peer path only; application/firewall behavior may differ." : "Peer did not answer", evidence: result.text))
        } else {
            probes.append(Probe(key: "tailscale.peer", layer: .tailscale, name: "Selected tailnet peer", target: "Not configured", health: .unavailable,
                                detail: "No online peer was available. Choose a peer in Settings to measure actual tailnet reachability."))
        }
        return probes
    }

    static func networkQuality(interface: String) async -> [Probe] {
        var args = ["-c", "-M", "35"]
        if interface != "Unknown" { args += ["-I", interface] }
        let result = await SystemCommand.run("/usr/bin/networkQuality", args, timeout: 42)
        guard let range = result.text.range(of: "{"),
              let data = String(result.text[range.lowerBound...]).data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [Probe(key: "speed.failed", layer: .internet, name: "Bandwidth & responsiveness benchmark", target: "Apple networkQuality", health: .unavailable,
                          detail: "The benchmark could not complete. DNS or Apple test endpoint availability may be responsible.", evidence: result.text)]
        }
        var probes: [Probe] = []
        let endpoint = info["test_endpoint"] as? String ?? "Apple networkQuality"
        for (field, name, key) in [("dl_throughput", "Download capacity", "speed.download"), ("ul_throughput", "Upload capacity", "speed.upload")] {
            if let value = info[field] as? Double {
                probes.append(Probe(key: key, layer: .internet, name: name, target: endpoint, health: .good,
                                    value: value / 1_000_000, unit: "Mbps", detail: "Measured capacity on this path; server choice and other traffic affect results.", evidence: result.text))
            }
        }
        if let rpm = info["responsiveness"] as? Double, rpm > 0 {
            probes.append(Probe(key: "speed.responsiveness", layer: .internet, name: "Latency under load", target: endpoint, health: rpm < 200 ? .warning : .good,
                                milliseconds: 60_000 / rpm, detail: "\(Int(rpm)) round trips/minute under load", evidence: result.text))
        }
        if probes.isEmpty {
            probes.append(Probe(key: "speed.failed", layer: .internet, name: "Bandwidth benchmark", target: "Apple networkQuality", health: .unavailable,
                                detail: "No capacity measurements returned. See evidence.", evidence: result.text))
        }
        return probes
    }
}
