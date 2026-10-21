import Foundation
import dnssd

// A successful lookup of a frequently used name can come entirely from cache.
// Query a unique child of the test domain through mDNSResponder instead. Both
// an address and an authoritative negative answer demonstrate a responding DNS
// path; a nonexistent random name is expected and is not a connectivity error.
enum FreshSystemDNS {
    static func queryName(domain: String, identifier: UUID = UUID()) -> String? {
        let name = "network-culprit-\(identifier.uuidString.lowercased()).\(domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
        return DNSWire.query(name, id: 1) == nil ? nil : name
    }

    static func probe(domain: String) async -> Probe {
        guard let name = queryName(domain: domain) else {
            return Probe(key: "dns.system.fresh", layer: .dns, name: "Fresh system DNS response", target: domain,
                         health: .unavailable, detail: "The test domain must leave room for a unique query label.")
        }
        return await withCheckedContinuation { continuation in
            FreshSystemDNSOperation(name: name, continuation: continuation).start()
        }
    }

    static func response(error: DNSServiceErrorType, cached: Bool, milliseconds: Double, name: String) -> Probe {
        let answered = error == kDNSServiceErr_NoError || error == kDNSServiceErr_NoSuchRecord
        return Probe(key: "dns.system.fresh", layer: .dns, name: "Fresh system DNS response", target: name,
                     health: answered ? (cached ? .warning : .good) : .failed,
                     milliseconds: answered ? milliseconds : nil,
                     detail: answered ? (cached ? "macOS returned a cached response; live DNS was not verified." : "A unique query received \(error == kDNSServiceErr_NoSuchRecord ? "a negative DNS answer (expected for a random name)" : "a DNS answer") through the macOS resolver.") : (error == kDNSServiceErr_Timeout ? "A unique query received no usable system DNS response within 6 seconds." : "The macOS resolver could not complete a unique query (DNS service error \(error))."),
                     evidence: "Native DNSServiceQueryRecord · error \(error)\(error == kDNSServiceErr_PolicyDenied ? " (policy denied)" : "") · answered from cache: \(cached). A unique child of the configured test domain tests the system resolver, including VPN/encrypted DNS routing. It does not bypass caches at upstream resolvers or prove every hostname resolves.")
    }
}

private final class FreshSystemDNSOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.NetworkCulprit.fresh-system-dns-check")
    private let name: String
    private var reference: DNSServiceRef?
    private var continuation: CheckedContinuation<Probe, Never>?
    private var started = DispatchTime.now()

    init(name: String, continuation: CheckedContinuation<Probe, Never>) {
        self.name = name; self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            started = .now()
            let error = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates | kDNSServiceFlagsTimeout),
                                             0, name, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                             { _, flags, _, error, _, _, _, _, _, _, context in
                guard let context else { return }
                Unmanaged<FreshSystemDNSOperation>.fromOpaque(context).takeUnretainedValue()
                    .finish(error: error, cached: flags & DNSServiceFlags(kDNSServiceFlagAnsweredFromCache) != 0)
            }, Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError, let reference else { finish(error: error); return }
            let schedulingError = DNSServiceSetDispatchQueue(reference, queue)
            guard schedulingError == kDNSServiceErr_NoError else { finish(error: schedulingError); return }
            // Retains the operation until its bounded deadline. All callbacks,
            // cancellation and deallocation run on this same serial queue.
            queue.asyncAfter(deadline: .now() + 6) { [self] in finish(error: DNSServiceErrorType(kDNSServiceErr_Timeout)) }
        }
    }

    private func finish(error: DNSServiceErrorType, cached: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        if let reference { DNSServiceRefDeallocate(reference); self.reference = nil }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        continuation.resume(returning: FreshSystemDNS.response(error: error, cached: cached, milliseconds: milliseconds, name: name))
    }
}
