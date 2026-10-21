# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/andresark/network-culprit/security/advisories/new). Do not post credentials, real network histories, private peer inventories, or sensitive exports in a public issue. General bugs can be reported in Issues using synthetic or redacted evidence.

Security fixes target the latest release. Older releases are not maintained separately. This community project has no guaranteed response time.

## Automated maintenance

- Dependabot checks GitHub Actions daily and Swift packages weekly, opening update PRs. Repository vulnerability alerts and automated security update PRs are enabled for supported dependencies.
- The **Native macOS tests, dependency audit, and release** workflow runs on pushes, pull requests, a daily schedule, and manual dispatch. GitHub can delay schedules; inspect Actions for its last successful run. Workflow failures and Dependabot alerts use GitHub's notification settings.
- The dependency audit submits pinned Git commits and published package versions to [OSV's vulnerability API](https://google.github.io/osv.dev/post-v1-querybatch/). It covers GitHub Actions and future remote SwiftPM dependencies, including transitive pins in `Package.resolved`. It fails on known advisories, API/parse errors, missing lockfiles for declared packages, unsupported dependency kinds, or unpinned workflow actions. No extra Ruby gems are installed.
- Each audit also queries a known vulnerable public Swift version as a positive control. If that advisory is not returned, the audit fails for investigation rather than treating an empty response as proof of coverage. The control package is never installed or bundled in the app.
- Every external action is pinned to a full commit SHA with a release-version comment. Dependabot maintains these pins. CI uses GitHub-hosted runners and read-only repository access by default. Pull requests never run on a maintainer's Mac or receive release credentials.
- Native Swift tests, vulnerability auditing, public-bundle verification, and GitHub Actions CodeQL analysis gate releases. Main-branch protection requires checks and pull requests; administrators retain GitHub's explicit override for emergency recovery.
- The **Automatically merge verified Dependabot security fixes and release app patches** workflow merges qualifying security fixes after all checks pass. Routine version updates remain for maintainer review. Dependabot may be unable to generate a patch if no fixed version exists. Installed apps are updated manually; this project has no in-app updater.

## Automatic merge and release policy

The privileged maintenance workflow runs only after successful pull-request validation. It checks out protected main's policy, never a PR's executable code. It fetches PR files as bounded text and requires all of the following:

1. The PR and every verified commit belong to `dependabot[bot]`, with the exact head SHA that finished validation, targeting this repository's main branch from the same repository.
2. Both required checks and every additional check have passed (tag-only jobs may be skipped). Main-branch protection still applies; the bot has no administrator bypass.
3. Changes are limited to SwiftPM manifests/locks or existing workflow action references. Workflow commands, permissions, or other structure cannot change.
4. OSV confirms a known advisory in the previous dependency pins and none in the proposed pins. A title, label, or `security(...)` commit prefix alone never authorizes merging.

SwiftPM fixes produce a new semantic patch tag on the actual squash-merge commit, then explicitly dispatch the full release workflow. This avoids GitHub's suppression of push workflows for tags created with `GITHUB_TOKEN`; no long-lived PAT is stored. The tag version is embedded in the built bundle. CI-only action fixes merge without an app release. Retries reuse an existing release tag and do not duplicate a published release.

Only the maintenance job receives PR/content/action write permissions. Only the publication job writes releases. Authorized repository writers, including GitHub Actions jobs with content-write permission, can create release tags; existing tag updates and deletion remain owner-only. Build and test jobs retain read-only access. Failed or indeterminate checks, identity mismatches, unsupported changes, API failures, and remaining advisories stop automation for investigation.

The maintenance workflow's manual **Run workflow** entry accepts a completed PR validation run ID and always performs a dry run. It never merges a PR or creates a release, even for a qualifying security fix.

An hourly reconciliation rechecks open Dependabot PRs that already have successful validation on their current head. This retries late checks, delayed advisory data, and transient service failures without approving untested commits. GitHub may delay schedules. A failed release job can be rerun; existing tags/releases are reused rather than replaced.

## Coverage boundaries

The app currently has **no external Swift package dependencies**. SwiftUI, Network.framework, Foundation, Swift Charts, system SQLite, the Swift runtime, and documented command-line tools come from macOS. Their CVEs are fixed through Apple software updates, not by Dependabot. Keep the operating system and build toolchain current. Tailscale is optional and independently installed; update it through its own vendor channel.

OSV and GitHub advisory coverage is incomplete. An empty result means no matching known advisory was returned, not a guarantee that code is safe. Unknown vulnerabilities, malicious releases, Apple system components, optional external applications, and runtime network conditions require additional review. The current audit rejects binary targets and local or registry package dependencies until an explicit audit design is added. Vendored source is outside automated package detection and requires explicit review.

As of October 2026, [CodeQL cannot analyze Swift 6.4 or trace Xcode 27 builds](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/). CodeQL here analyzes workflow code only; it is not a Swift source scan. The app remains built and tested against the macOS 27 SDK. Revisit Swift source scanning when upstream support is available.

The public release is ad hoc signed and not notarized. Release checksums detect corruption but do not replace an Apple Developer ID identity or code review. Only protected `v*` tags should produce official releases.
