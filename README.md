# Network Culprit

[![Native macOS validation](https://github.com/andresark/network-culprit/actions/workflows/validate-and-release.yml/badge.svg)](https://github.com/andresark/network-culprit/actions/workflows/validate-and-release.yml)

A free, MIT-licensed, native Swift macOS menu bar app for answering **which part of my network is failing?** Compare your local connection, router, internet path, DNS, NextDNS, Tailscale, IPv6, and web/TLS checks alongside their history.

## What it does

- A color-coded menu bar icon shows current health; open the dashboard for evidence and likely causes.
- Lightweight checks run in the background, with optional native launch at login.
- Native issue and recovery notifications include the likely culprit and observed duration. Confirmation, recovery checks, and cooldowns suppress brief blips and repeated alerts.
- Compare system, router, independent public, NextDNS, and Tailscale DNS paths. Enter your own NextDNS resolver addresses in settings; none are preconfigured.
- Test IPv6 source prefixes separately to expose stale ranges after a router restart.
- Review local SQLite history, Swift Charts, latency, loss, interface errors, and optional bandwidth/responsiveness benchmarks. Export JSON or CSV when needed.
- SwiftUI Liquid Glass surfaces respect Reduce Transparency. No Electron, web view, paid service, or account is required.

Results show supporting evidence and confidence. A single Mac cannot reliably distinguish an ISP outage from every router WAN/ONT fault, and filtered ICMP does not by itself establish an outage.

## Get the app

**Requires macOS 27 or later on Apple Silicon.** Download the app ZIP from [Releases](https://github.com/andresark/network-culprit/releases), verify its SHA-256 against the release checksums, unzip, and move **Network Culprit.app** to Applications.

The free downloadable build is **ad hoc signed, not Developer ID signed or Apple notarized**. macOS may block a downloaded build pending your approval. Building from source is another option. Checksums confirm file integrity; they do not provide Apple notarization.

Allow Local Network access when macOS asks. In Monitoring Settings, optionally enable launch at login and native issue notifications. Closing the dashboard leaves the menu bar monitor running; Quit stops it. Automatic bandwidth tests are off by default because they can use substantial data.

Tailscale checks use your existing Tailscale installation; it is not bundled. Select a peer if you want peer reachability measurements. Direct DNS probes may be blocked on managed networks; their failures should be compared with normal system resolution.

## Build and test

Use Xcode 27 or the macOS 27 Command Line Tools, with Swift 6.4. No third-party Swift packages are required.

```sh
git clone https://github.com/andresark/network-culprit.git
cd network-culprit
./scripts/test-native-network-diagnostics.sh
./scripts/build-native-macos-app.sh
./scripts/verify-public-app.sh
./scripts/install-native-macos-app.sh
```

The build is in `dist/Network Culprit.app`. Quit and relaunch the installed app after updating. The installer stages and verifies the signed bundle before replacing it by directory rename; previous installed builds are preserved in `.build/`.

For a one-off report without UI history:

```sh
"dist/Network Culprit.app/Contents/MacOS/NetworkCulprit" --diagnose-json /path/to/report.json
```

Add `--include-bandwidth` only when you want a data-intensive capacity test. Reports contain network details; review them before sharing.

## Privacy

History stays on your Mac in `~/Library/Application Support/Network Culprit — ISP DNS and VPN Diagnostics/`. Preferences use macOS UserDefaults. There is no telemetry or cloud history upload. Network probes necessarily send requests to the endpoints being tested, including Apple, Cloudflare, Google, NextDNS, configured DNS servers, and an optional selected Tailscale peer. Those services see normal connection metadata.

History and exports can include IP addresses, DNS configuration, selected peer details, network interfaces, and diagnostic evidence. Raw Tailscale peer inventory is not retained. Native notifications are local, not push messages. The app never changes network configuration or installs an IPv6 repair service. It can read status from an independently installed companion IPv6 repair tool if present.

## Maintenance and security

[SECURITY.md](SECURITY.md) describes the scheduled vulnerability audit, Dependabot updates, security reporting, and coverage limits. CI runs tests, verifies a clean public bundle, and checks dependencies on every change and daily. Release tags publish only after those checks pass. Update PRs require passing checks and maintainer review; updates are not silently merged or installed on users' Macs.

There are currently **zero external Swift packages**. macOS supplies Swift runtime/frameworks and SQLite, so keep macOS updated for their security fixes. Update an independently installed Tailscale client through its own distribution channel.

See [CONTRIBUTING.md](CONTRIBUTING.md) for architecture, test, and release details.
