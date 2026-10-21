import Foundation
import Testing
@testable import NetworkCulprit

private struct TailscaleFixture {
    let directory: URL
    let executable: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "NetworkCulprit-Tailscale-CLI-Test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        executable = directory.appending(path: "tailscale-cli-fixture")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test func tailscaleStatusTransportAndPeerAlwaysUseExplicitCLIMode() async throws {
    // Model the macOS combined GUI/CLI executable: exit zero alone is not
    // success. Every subcommand must explicitly choose CLI mode in its child.
    let fixture = try TailscaleFixture(script: #"""
    if [ "$TAILSCALE_BE_CLI" != "1" ]; then
      printf 'GUI mode selected; CLI status was not requested.'
      exit 0
    fi
    case "$1" in
      status) printf '%s' '{"BackendState":"Running","Health":[],"Peer":{"nodekey:synthetic-private-inventory":{"HostName":"fixture-peer","Online":true,"TailscaleIPs":["100.64.0.1"],"PrivateKey":"synthetic-do-not-retain"}}}' ;;
      netcheck) printf '%s' '{"UDP":true,"IPv4":true,"IPv6":true,"PreferredDERP":1,"RegionLatency":{"1":8000000}}' ;;
      ping) printf 'pong from fixture-peer (100.64.0.1) via 192.0.2.1:41641 in 12ms\npong from fixture-peer (100.64.0.1) via 192.0.2.1:41641 in 14ms\npong from fixture-peer (100.64.0.1) via 192.0.2.1:41641 in 10ms\n' ;;
      *) exit 64 ;;
    esac
    """#)
    defer { fixture.remove() }
    let probes = await DiagnosticEngine.tailscale(settings: DiagnosticSettings(), executable: fixture.executable.path)
    #expect(probes.count == 3)
    #expect(probes.allSatisfy { $0.health == .good })
    #expect(probes.first { $0.key == "tailscale.service" }?.detail == "Running")
    #expect(probes.first { $0.key == "tailscale.transport" }?.milliseconds == 8)
    #expect(probes.first { $0.key == "tailscale.peer" }?.milliseconds == 12)
    let stored = String(decoding: try JSONEncoder().encode(probes), as: UTF8.self)
    #expect(!stored.contains("synthetic-private-inventory"))
    #expect(!stored.contains("synthetic-do-not-retain"))
}

@Test func tailscaleExitZeroWithNonJSONIsAnIntegrationWarningWithoutRawPeerData() async throws {
    let fixture = try TailscaleFixture(script: "printf 'GUI/CLI launch message: synthetic-do-not-retain'\nexit 0\n")
    defer { fixture.remove() }
    let probes = await DiagnosticEngine.tailscale(settings: DiagnosticSettings(), executable: fixture.executable.path)
    #expect(probes.count == 1)
    #expect(probes.first?.health == .warning)
    #expect(probes.first?.detail.contains("does not establish a VPN outage") == true)
    #expect(probes.first?.evidence.contains("Command exit: 0") == true)
    #expect(probes.first?.evidence.contains("synthetic-do-not-retain") == false)
}

@Test func tailscaleDoesNotAcceptStatusJSONFromAFailedProcess() async throws {
    let fixture = try TailscaleFixture(script: #"""
    printf '%s' '{"BackendState":"Running","Health":[]}'
    exit 7
    """#)
    defer { fixture.remove() }
    let probes = await DiagnosticEngine.tailscale(settings: DiagnosticSettings(), executable: fixture.executable.path)
    #expect(probes.count == 1)
    #expect(probes.first?.health == .warning)
    #expect(probes.first?.evidence.contains("Command exit: 7") == true)
}

@Test func stoppedTailscaleDoesNotClaimConnectivityOrRunPeerTests() async throws {
    let fixture = try TailscaleFixture(script: #"""
    if [ "$1" != "status" ]; then exit 99; fi
    printf '%s' '{"BackendState":"Stopped","Health":[]}'
    """#)
    defer { fixture.remove() }
    let probes = await DiagnosticEngine.tailscale(settings: DiagnosticSettings(), executable: fixture.executable.path)
    #expect(probes.count == 1)
    #expect(probes.first?.health == .unavailable)
    #expect(probes.first?.detail == "Stopped")
}
