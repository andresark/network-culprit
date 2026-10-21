# Contributing

Use Swift 6.4 and the macOS 27 SDK. Run `scripts/test-native-network-diagnostics.sh` before submitting a pull request. Tests use synthetic data and temporary storage; they do not disconnect a network, register login items, or deliver issue notifications. Do not commit real diagnostic exports or personal resolver defaults.

## Architecture

| File | Responsibility |
| --- | --- |
| `App.swift` | SwiftUI app, menu bar, headless entry points |
| `DiagnosticStore.swift` | Observation model, background sampling, native path events, retention |
| `Diagnostics.swift`, `NetworkProbes.swift` | Bounded probes, native DNS, command execution and parsers |
| `Models.swift` | Codable measurements and evidence-based attribution |
| `SnapshotDatabase.swift`, `HistoryExport.swift` | System SQLite storage and safe JSON/CSV exports |
| `NetworkIncidentTracker.swift` | Incident confirmation, recovery, cooldowns, durable state |
| `NetworkIncidentNotifications.swift` | Native authorization, local notification delivery, durable outbox |
| `LoginItemController.swift` | Native `SMAppService.mainApp` login registration |
| `Views.swift`, `HistoryAndSettings.swift` | Dashboard, charts, history, settings |
| `GlassComponents.swift`, `NetworkMenuBarStatus.swift` | Liquid Glass and accessible status icons |
| `DemonstrationData.swift` | Synthetic, offline scenarios for documentation and exploration |

The `NativeViewState` alias selects SwiftUI's native State property wrapper explicitly because the macOS 27 Command Line Tools can resolve a same-named macro whose plugin is only in full Xcode. The test script similarly locates the Swift Testing plugin when required. SQLite avoids a SwiftData macro build dependency.

Subprocesses have bounded output and timeouts; stdout and stderr stay separate. Tailscale commands explicitly set `TAILSCALE_BE_CLI=1`. Unknown `netcheck` JSON is inconclusive rather than reported healthy. Keep these properties when changing probes.

## Dependency audit

CI uses the runner's Ruby standard library for maintenance tooling, not as an app runtime. To run the audit locally:

```sh
mkdir -p .build
swift package resolve
swift package dump-package > .build/package-manifest.json
ruby scripts/test-dependency-vulnerability-audit.rb
ruby scripts/test-automatic-security-maintenance.rb
ruby scripts/audit-dependency-vulnerabilities.rb
```

Commit `Package.resolved` when adding remote packages. All direct and transitive remote source-control packages need pinned revisions. Unsupported package sources fail the audit and require a reviewed extension. The audit's regression tests simulate findings, pagination, missing locks, and failed requests without querying real user network data.

## Releasing

1. Update the default development version in `scripts/build-native-macos-app.sh` and add `docs/releases/vVERSION.md` for a feature release.
2. Merge a reviewed PR after the required checks pass.
3. Tag that main-branch commit `vVERSION` and push the tag. Tag builds automatically embed that version; local builds can set `NETWORK_CULPRIT_RELEASE_VERSION` explicitly.
4. The workflow repeats tests/auditing, builds an Apple Silicon bundle, checks it for local paths, and publishes its ZIP and SHA-256 file only after all jobs succeed.

Verified Dependabot security fixes follow [the automatic maintenance policy](SECURITY.md#automatic-merge-and-release-policy). SwiftPM changes create the next patch tag on the merge commit and dispatch the same release gates; CI-only fixes do not publish binaries. No version-bump commit or stored PAT is needed. Normal version updates and other contributions still require manual merging. When merging with `gh`, use `--author-email 22714509+andresark@users.noreply.github.com` for this maintainer's commit identity.

Use the release's workflow run to inspect its provenance. The release job checks that the tagged commit belongs to main. It does not overwrite an existing release. Tag creation permits the owner and GitHub Actions; updating/deleting existing tags remains owner-only. Do not upload a development bundle or a ZIP containing local history. Publishing an ad hoc signed build does not provide notarization.

## Documentation screenshots

Launch the built executable with `--demo` to explore synthetic healthy, DNS-failure, and stale-IPv6 scenarios using the real native views. This path never reads the live history database, starts probes, changes user preferences, or requests notification/login permission. Capture only its window, keep the sample-data label visible, and review images for private information before committing them to `docs/images/`.
