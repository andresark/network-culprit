import Foundation
import Testing
@testable import NetworkCulprit

private func probe(_ key: String, _ health: Health, layer: NetworkLayer = .dns, loss: Double? = nil) -> Probe {
    Probe(key: key, layer: layer, name: key, target: "test", health: health, packetLoss: loss, detail: "Test evidence")
}
private func context() -> NetworkContext { var value = NetworkContext(); value.interface = "en8"; value.gateway = "192.168.1.1"; return value }
private func snapshot(date: Date = Date()) -> DiagnosticSnapshot {
    let probes = [probe("internet.https.cloudflare", .good, layer: .internet)]
    return DiagnosticSnapshot(date: date, context: context(), probes: probes, finding: Attribution.evaluate(probes, context: context()), duration: 1.2)
}

@Test func dnsQueryUsesCorrectIdentifierAndLabels() throws {
    let data = try #require(DNSWire.query("www.apple.com", id: 0x1234))
    #expect(Array(data.prefix(4)) == [0x12, 0x34, 1, 0])
    #expect(Array(data.suffix(5)) == [0, 0, 1, 0, 1])
    #expect(data.contains(3))
}
@Test func invalidDomainsAreRejected() {
    for invalid in ["", "a..com", "-x;touch file", "https://apple.com", String(repeating: "a", count: 64) + ".com"] {
        #expect(DNSWire.query(invalid, id: 1) == nil)
    }
}
@Test func dnsResponseValidationRejectsMismatchedAndShortPackets() {
    #expect(DNSWire.reply(Data([1, 2]), id: 258) == nil)
    let valid = Data([0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0])
    #expect(DNSWire.reply(valid, id: 0x1234)?.1 == 2)
    #expect(DNSWire.reply(valid, id: 0x5678) == nil)
}
@Test func ipv6PrefixIsCanonicalAcrossCompressedAddresses() {
    #expect(TextParse.prefix("2001:db8:abcd:1200::1") == "2001:db8:abcd:1200::/64")
    #expect(TextParse.prefix("2001:db8::1") == "2001:db8:0:0::/64")
    #expect(TextParse.prefix("invalid") == nil)
}
@Test func unusableIPv6AddressesAreExcluded() {
    let text = """
      inet6 fe80::1 prefixlen 64
      inet6 2001:db8:1:2::1 prefixlen 64 autoconf secured
      inet6 2001:db8:3:4::1 prefixlen 64 deprecated autoconf secured
      inet6 2001:db8:5:6::1 prefixlen 64 tentative autoconf secured
      inet6 fdf0::1 prefixlen 64 autoconf
    """
    #expect(TextParse.publicIPv6Addresses(text) == ["2001:db8:1:2::1"])
}
@Test func resolverListIsDeduplicatedAndPlaceholderIgnored() {
    let text = "nameserver[0] : 127.0.0.1\nnameserver[0] : 192.168.1.1\nnameserver[1] : 192.168.1.1\nnameserver[0] : 100.100.100.100"
    #expect(TextParse.dnsServers(text) == ["192.168.1.1", "100.100.100.100"])
}
@Test func pingParserKeepsLossAndMean() {
    let text = "8 packets transmitted, 7 packets received, 12.5% packet loss\nround-trip min/avg/max/stddev = 0.4/0.8/1.2/0.1 ms"
    let result = TextParse.ping(CommandResult(text: text, exitCode: 0, seconds: 2, timedOut: false), key: "test", layer: .local, name: "Test", target: "test")
    #expect(result.packetLoss == 12.5); #expect(result.milliseconds == 0.8); #expect(result.health == .warning)
}
@Test func noRouteIsLocalFailure() {
    let finding = Attribution.evaluate([], context: NetworkContext())
    #expect(finding.layer == .local); #expect(finding.confidence == "High")
}
@Test func staleIPv6HasStrongIndependentEvidence() {
    let finding = Attribution.evaluate([probe("ipv6.prefix.good.a", .good, layer: .ipv6), probe("ipv6.prefix.bad.b", .failed, layer: .ipv6)], context: context())
    #expect(finding.layer == .ipv6); #expect(finding.confidence == "High")
}
@Test func multipleWorkingIPv6PrefixesAreNotAProblem() {
    let finding = Attribution.evaluate([probe("ipv6.prefix.good.a", .good, layer: .ipv6), probe("ipv6.prefix.good.b", .good, layer: .ipv6), probe("internet.https.cf", .good, layer: .internet)], context: context())
    #expect(finding.health == .good)
}
@Test func tailscaleDNSIsSeparatedFromRouterDNS() {
    let finding = Attribution.evaluate([probe("dns.system", .failed), probe("dns.tailscale.100", .failed), probe("dns.router.192", .good), probe("dns.control.cf", .good)], context: context())
    #expect(finding.title == "Tailscale DNS forwarding is failing")
}
@Test func nextDNSIdentitySuccessDoesNotMaskFailedUpstreamBenchmarks() {
    let finding = Attribution.evaluate([probe("dns.system", .failed), probe("dns.nextdns.a", .failed), probe("dns.nextdns.b", .failed), probe("dns.nextdns-identity", .good), probe("dns.control.cf", .good)], context: context())
    #expect(finding.title == "NextDNS path is the likely culprit")
}
@Test func routerDNSIsSeparatedFromUpstreamDNS() {
    let finding = Attribution.evaluate([probe("dns.system", .failed), probe("dns.router.192", .failed), probe("dns.nextdns.a", .good), probe("internet.https.cf", .good, layer: .internet)], context: context())
    #expect(finding.title == "Router DNS forwarding is failing")
}
@Test func ICMPFailuresDoNotEstablishISPOutageWhenHTTPSWorks() {
    let finding = Attribution.evaluate([probe("internet.ping.cf", .failed, layer: .internet, loss: 100), probe("internet.https.cf", .good, layer: .internet)], context: context())
    #expect(finding.health == .warning); #expect(finding.confidence == "Low")
}
@Test func allUpstreamChecksFailingDoesNotOverclaimISP() {
    let finding = Attribution.evaluate([probe("local.router", .good, layer: .local), probe("internet.https.cf", .failed, layer: .internet), probe("internet.https.google", .failed, layer: .internet)], context: context())
    #expect(finding.layer == .internet); #expect(finding.confidence == "Medium")
    #expect(finding.explanation.contains("cannot distinguish"))
}
@Test func gatewayAndPublicFailurePointsToLocalPath() {
    let finding = Attribution.evaluate([probe("local.router", .failed, layer: .local, loss: 100), probe("internet.https.cf", .failed, layer: .internet), probe("internet.ping.cf", .failed, layer: .internet, loss: 100)], context: context())
    #expect(finding.layer == .local); #expect(finding.confidence == "Medium")
}
@Test func HTTPSFailureWithWorkingICMPIsNotAnISPConclusion() {
    let finding = Attribution.evaluate([probe("internet.ping.cf", .good, layer: .internet), probe("internet.https.cf", .failed, layer: .internet)], context: context())
    #expect(finding.layer == .web)
}
@Test func VPNPathIsNamedWhenUpstreamUncertain() {
    var ctx = context(); ctx.trafficUsesVPN = true
    let finding = Attribution.evaluate([probe("internet.https.cf", .failed, layer: .internet)], context: ctx)
    #expect(finding.title == "VPN or upstream path is failing")
}
@Test func peerFailureIsNotHiddenByHealthyInternet() {
    let finding = Attribution.evaluate([probe("internet.https.cf", .good, layer: .internet), probe("tailscale.peer", .failed, layer: .tailscale)], context: context())
    #expect(finding.layer == .tailscale)
}
@Test func snapshotEncodingRetainsRawEvidence() throws {
    let value = snapshot()
    let decoded = try JSONDecoder().decode(DiagnosticSnapshot.self, from: JSONEncoder().encode(value))
    #expect(decoded.id == value.id); #expect(decoded.probes.first?.detail == "Test evidence")
}
@Test func databasePersistsSortsAndPrunesHistory() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "history.sqlite")
    let older = snapshot(date: Date(timeIntervalSince1970: 1000)), newer = snapshot(date: Date(timeIntervalSince1970: 2000))
    do {
        let database = try SnapshotDatabase(url: url)
        try database.insert(older); try database.insert(newer)
        #expect(try database.count() == 2)
        #expect(try database.read(limit: 1).first?.id == newer.id)
    }
    let reopened = try SnapshotDatabase(url: url)
    #expect(try reopened.count() == 2)
    try reopened.prune(before: Date(timeIntervalSince1970: 1500))
    #expect(try reopened.count() == 1); #expect(try reopened.read().first?.id == newer.id)
}
@Test func processTimeoutIsBounded() async {
    let result = await SystemCommand.run("/bin/sleep", ["5"], timeout: 0.1)
    #expect(result.timedOut); #expect(result.seconds < 2)
}
@Test func processCapturesOutputAndMissingExecutableErrors() async {
    let result = await SystemCommand.run("/usr/bin/printf", ["network-test"])
    #expect(result.text == "network-test"); #expect(result.exitCode == 0)
    let missing = await SystemCommand.run("/does-not-exist-network-culprit", [])
    #expect(missing.exitCode == -1)
}
@Test func processCapturesLargeJSONWithoutTruncatingOrRacing() async throws {
    let json = "{\"value\":\"" + String(repeating: "n", count: 50_000) + "\"}"
    let result = await SystemCommand.run("/usr/bin/printf", ["%s", json])
    #expect(result.text == json)
    #expect(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) is [String: Any])
}
@Test func concurrentCommandsAlwaysDrainBothOutputStreams() async {
    await withTaskGroup(of: (Int, CommandResult).self) { group in
        for index in 0..<16 {
            group.addTask {
                let result = await SystemCommand.run("/bin/sh", ["-c", "printf 'stdout-\(index)'; printf 'stderr-\(index)' >&2"], timeout: 5)
                return (index, result)
            }
        }
        for await (index, result) in group {
            #expect(result.exitCode == 0)
            #expect(!result.timedOut)
            #expect(result.standardOutput == "stdout-\(index)")
            #expect(result.standardError == "stderr-\(index)")
        }
    }
}
@Test func diagnosticJSONIsNotCorruptedByStandardError() async throws {
    let result = await SystemCommand.run("/bin/sh", ["-c", "printf '{\"UDP\":true}'; printf 'diagnostic warning' >&2"])
    #expect(result.standardOutput == "{\"UDP\":true}")
    #expect(result.standardError == "diagnostic warning")
    #expect(TextParse.jsonObject(result.standardOutput)?["UDP"] as? Bool == true)
}
@Test func historyCSVQuotesAndNeutralizesSpreadsheetFormulas() throws {
    var value = snapshot(); value.probes[0].target = "=DANGEROUS()"; value.probes[0].detail = "A \"quoted\", multiline\nvalue"
    let text = String(decoding: try HistoryExport.encode([value], csv: true), as: UTF8.self)
    #expect(text.contains("\"'=DANGEROUS()\"")); #expect(text.contains("\"A \"\"quoted\"\", multiline\nvalue\""))
}
@Test func historyJSONUsesPortableISO8601Dates() throws {
    let data = try HistoryExport.encode([snapshot(date: Date(timeIntervalSince1970: 0))], csv: false)
    let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(array.first?["date"] as? String == "1970-01-01T00:00:00Z")
}
@Test func permissionDenialIsNotBlamedOnDNSProvider() {
    var denied = probe("dns.router.192", .failed); denied.evidence = "Operation not permitted"
    let finding = Attribution.evaluate([denied, probe("dns.system", .failed), probe("dns.control.cf", .good)], context: context())
    #expect(finding.layer == .local); #expect(finding.title.contains("access"))
}
@Test func elevatedRouterLatencyIsHighlightedWithoutClaimingAnOutage() {
    let text = "0.0% packet loss\nround-trip min/avg/max/stddev = 15/80/120/20 ms"
    let result = TextParse.ping(CommandResult(text: text, exitCode: 0, seconds: 2, timedOut: false), key: "local.router", layer: .local, name: "Router", target: "router")
    #expect(result.health == .warning); #expect(result.packetLoss == 0)
}
