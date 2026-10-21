import Foundation
import Testing
import dnssd
@testable import NetworkCulprit

private func dnsProbe(_ key: String, _ health: Health) -> Probe {
    Probe(key: key, layer: .dns, name: key, target: "example.com", health: health, detail: "Synthetic resolver evidence")
}

private func dnsSnapshot(_ probes: [Probe]) -> DiagnosticSnapshot {
    var context = NetworkContext(); context.interface = "en0"
    let all = probes + [Probe(key: "internet.https.control", layer: .internet, name: "Independent HTTPS", target: "192.0.2.1", health: .good, detail: "TLS verified")]
    return DiagnosticSnapshot(context: context, probes: all, finding: Attribution.evaluate(all, context: context), duration: 1)
}

@Test func cachedSystemLookupDoesNotConcealFailedResolverPaths() {
    let snapshot = dnsSnapshot([dnsProbe("dns.system", .good), dnsProbe("dns.nextdns-identity", .good),
                                dnsProbe("dns.router.192.0.2.1", .failed), dnsProbe("dns.nextdns.192.0.2.2", .failed),
                                dnsProbe("dns.tailscale.100.100.100.100", .good), dnsProbe("dns.control.cf", .good)])
    #expect(snapshot.finding.layer == .dns)
    #expect(snapshot.finding.health == .warning)
    #expect(snapshot.dnsAssessment.title == "2 DNS checks failed")
    #expect(snapshot.dnsAssessment.evidence.count == 2)
    #expect(snapshot.layerHealth(.dns) == .warning)
    #expect(snapshot.finding.explanation.contains("Cached"))
}

@Test func freshSystemFailureOverridesSuccessfulCachedHostnameLookup() {
    let snapshot = dnsSnapshot([dnsProbe("dns.system", .good), dnsProbe("dns.system.fresh", .failed), dnsProbe("dns.control.cf", .good)])
    #expect(snapshot.finding.layer == .dns)
    #expect(snapshot.finding.health == .failed)
    #expect(snapshot.layerHealth(.dns) == .failed)
    #expect(snapshot.dnsAssessment.title == "System DNS is failing")
}

@Test func healthyFreshQueryDoesNotEraseBrokenAlternativeDNSPath() {
    let snapshot = dnsSnapshot([dnsProbe("dns.system", .good), dnsProbe("dns.system.fresh", .good), dnsProbe("dns.router.192.0.2.1", .failed)])
    #expect(snapshot.dnsAssessment.health == .warning)
    #expect(snapshot.dnsAssessment.detail.contains("Fresh system DNS answered"))
    #expect(snapshot.finding.health == .warning)
}

@Test func failedIndependentControlDoesNotClaimSystemDNSOutage() {
    let snapshot = dnsSnapshot([dnsProbe("dns.system.fresh", .good), dnsProbe("dns.control.cf", .failed)])
    #expect(snapshot.dnsAssessment.health == .warning)
    #expect(snapshot.dnsAssessment.title == "1 DNS check failed")
    #expect(snapshot.finding.health != .failed)
}

@Test func unavailableIdentityEndpointDoesNotFailHealthyDNS() {
    let snapshot = dnsSnapshot([dnsProbe("dns.system", .good), dnsProbe("dns.system.fresh", .good), dnsProbe("dns.nextdns-identity", .unavailable)])
    #expect(snapshot.dnsAssessment.health == .good)
    #expect(snapshot.finding.health == .good)
}

@Test func repeatedDNSProtocolErrorsAreFailuresEvenWhenServerReplies() {
    for code in [2, 3, 5] { // SERVFAIL, NXDOMAIN and REFUSED for a known hostname.
        #expect(DNSWire.health(Array(repeating: DNSReply(milliseconds: 5, code: code, answers: 0), count: 3)) == .failed)
    }
    #expect(DNSWire.health(Array(repeating: DNSReply(milliseconds: 5, code: 0, answers: 0), count: 3)) == .failed)
}

@Test func partialOrSlowDNSResponsesRemainWarnings() {
    let success = DNSReply(milliseconds: 5, code: 0, answers: 1)
    #expect(DNSWire.health([success, success, DNSReply(milliseconds: 1800, code: -1, answers: 0, error: "Timeout")]) == .warning)
    #expect(DNSWire.health([DNSReply(milliseconds: 300, code: 0, answers: 1)]) == .warning)
    #expect(DNSWire.health([success, success, success]) == .good)
}

@Test func freshSystemQueryNamesAreUniqueValidAndRespectDomainLimits() throws {
    let first = try #require(FreshSystemDNS.queryName(domain: "example.com"))
    let second = try #require(FreshSystemDNS.queryName(domain: "example.com"))
    #expect(first != second)
    #expect(first.hasSuffix(".example.com"))
    #expect(DNSWire.query(first, id: 1) != nil)
    #expect(FreshSystemDNS.queryName(domain: "https://example.com") == nil)
    #expect(FreshSystemDNS.queryName(domain: Array(repeating: String(repeating: "x", count: 60), count: 4).joined(separator: ".")) == nil)
}

@Test func nativeNegativeDNSAnswerVerifiesResponseButCacheDoesNot() {
    let negative = FreshSystemDNS.response(error: DNSServiceErrorType(kDNSServiceErr_NoSuchRecord), cached: false, milliseconds: 10, domain: "example.com", name: "unique.example.com")
    #expect(negative.health == .good)
    #expect(negative.detail.contains("expected for a random name"))
    let cached = FreshSystemDNS.response(error: 0, cached: true, milliseconds: 1, domain: "example.com", name: "unique.example.com")
    #expect(cached.health == .warning)
    #expect(cached.detail.contains("live DNS was not verified"))
    let timeout = FreshSystemDNS.response(error: DNSServiceErrorType(kDNSServiceErr_Timeout), cached: false, milliseconds: 6000, domain: "example.com", name: "unique.example.com")
    #expect(timeout.health == .failed)
    #expect(timeout.milliseconds == nil)
    let denied = FreshSystemDNS.response(error: DNSServiceErrorType(kDNSServiceErr_PolicyDenied), cached: false, milliseconds: 1, domain: "example.com", name: "unique.example.com")
    #expect(!denied.detail.contains("6 seconds"))
    #expect(dnsSnapshot([denied]).finding.layer == .local)
}

@Test func uniqueFreshQueriesKeepOneStableHistorySeriesAndDetailedEvidence() {
    let first = FreshSystemDNS.response(error: 0, cached: false, milliseconds: 10, domain: "example.com", name: "first.example.com")
    let second = FreshSystemDNS.response(error: 0, cached: false, milliseconds: 12, domain: "example.com", name: "second.example.com")
    #expect(first.target == "example.com")
    #expect(first.target == second.target)
    #expect(first.name == second.name)
    #expect(first.evidence.contains("first.example.com"))
    #expect(second.evidence.contains("second.example.com"))
    var older = first; older.target = "network-culprit-older.example.com"
    #expect(older.historySeriesName == first.historySeriesName)
    #expect(first.historySeriesName == second.historySeriesName)
    var router = first; router.key = "dns.router.192.0.2.1"; router.target = "192.0.2.1"
    #expect(router.historySeriesName.contains("192.0.2.1"))
}
