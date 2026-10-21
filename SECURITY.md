# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/andresark/network-culprit/security/advisories/new). Do not post credentials, real network histories, private peer inventories, or sensitive exports in a public issue. General bugs can be reported in Issues using synthetic or redacted evidence.

Security fixes target the latest release. Older releases are not maintained separately. This community project has no guaranteed response time.

## Automated maintenance

- Dependabot checks GitHub Actions daily and Swift packages weekly, opening update PRs. Repository vulnerability alerts and automated security update PRs are enabled for supported dependencies.
- The **Native macOS tests, dependency audit, and release** workflow runs on pushes, pull requests, a daily schedule, and manual dispatch. GitHub can delay schedules; inspect Actions for its last successful run. Workflow failures and Dependabot alerts use GitHub's notification settings.
- The dependency audit submits pinned Git commits and published package versions to [OSV's vulnerability API](https://google.github.io/osv.dev/post-v1-querybatch/). It covers GitHub Actions and future remote SwiftPM dependencies, including transitive pins in `Package.resolved`. It fails on known advisories, API/parse errors, missing lockfiles for declared packages, unsupported dependency kinds, or unpinned workflow actions. No extra Ruby gems are installed.
- Every external action is pinned to a full commit SHA with a release-version comment. Dependabot maintains these pins. CI uses GitHub-hosted runners and read-only repository access by default. Only the tag-release job can write releases. Pull requests never run on a maintainer's Mac or receive release credentials.
- Native Swift tests, vulnerability auditing, public-bundle verification, and GitHub Actions CodeQL analysis gate releases. Main-branch protection requires checks and pull requests; administrators retain GitHub's explicit override for emergency recovery.
- Updates require maintainer review and passing CI. This project does not promise unattended remediation, automatic merging, or an in-app updater. Dependabot may be unable to generate a patch if no fixed version exists.

## Coverage boundaries

The app currently has **no external Swift package dependencies**. SwiftUI, Network.framework, Foundation, Swift Charts, system SQLite, the Swift runtime, and documented command-line tools come from macOS. Their CVEs are fixed through Apple software updates, not by Dependabot. Keep the operating system and build toolchain current. Tailscale is optional and independently installed; update it through its own vendor channel.

OSV and GitHub advisory coverage is incomplete. An empty result means no matching known advisory was returned, not a guarantee that code is safe. Unknown vulnerabilities, malicious releases, Apple system components, optional external applications, and runtime network conditions require additional review. The current audit rejects binary targets and local or registry package dependencies until an explicit audit design is added. Vendored source is outside automated package detection and requires explicit review.

As of October 2026, [CodeQL cannot analyze Swift 6.4 or trace Xcode 27 builds](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/). CodeQL here analyzes workflow code only; it is not a Swift source scan. The app remains built and tested against the macOS 27 SDK. Revisit Swift source scanning when upstream support is available.

The public release is ad hoc signed and not notarized. Release checksums detect corruption but do not replace an Apple Developer ID identity or code review. Only protected `v*` tags should produce official releases.
