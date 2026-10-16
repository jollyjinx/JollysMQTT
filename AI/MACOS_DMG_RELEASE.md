---
title: "Notarized macOS DMG Releases"
description: "GitHub version-tag releases, Developer ID and CloudKit provisioning, required secrets, verification gates, and local validation."
area: "release"
doc_type: "release-runbook"
status: "implemented-pending-signed-validation"
last_reviewed: "2026-10-16"
tags:
  - "github-actions"
  - "developer-id"
  - "notarization"
  - "cloudkit"
  - "dmg"
---

# Notarized macOS DMG Releases

`.github/workflows/release-macos.yml` builds and publishes a macOS DMG when a
version tag such as `v0.2.0` is pushed to `jollyjinx/JollysMQTT` on GitHub.
Tags must be exactly `vX.Y.Z`, without leading zeroes or prerelease suffixes.
The tag supplies `MARKETING_VERSION`; `Scripts/xcode_git_version.sh` supplies
the UTC Git-derived build number. Annotated and lightweight tags are supported.

The build runs on `macos-26` with Xcode 26.3 and produces a universal app
containing `arm64` and `x86_64`. It uses **Official Release** with manual
Developer ID Application signing, hardened runtime, secure timestamps, and
Production CloudKit. The existing TestFlight signing path is independent.

## Configure the GitHub environment

In the GitHub repository, open **Settings → Environments**, create
**macos-release**, and add these six environment secrets. Repository secrets
with the same names also work. Do not paste private keys or passwords into
chat, source files, issue comments, or workflow logs.

| Secret | Value |
|--------|-------|
| `MACOS_DEVELOPER_ID_P12_BASE64` | Base64 of a `.p12` export containing one **Developer ID Application** certificate and its private key for team `5V8J7476Q9`. |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | Password used to encrypt that `.p12` export. |
| `MACOS_DEVELOPER_ID_PROFILE_BASE64` | Base64 of the **Developer ID** `.provisionprofile` for `eu.jinx.jollymqtt`, authorizing that certificate, Production CloudKit container `iCloud.eu.jinx.jollymqtt`, and production push notifications. |
| `APP_STORE_CONNECT_API_KEY_P8` | Complete, raw contents of the notarization **Team API Key** `.p8` file, including the BEGIN/END lines; this value is **not Base64**. |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID associated with that `.p8` file. |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer UUID associated with that Team API Key. |

Use an App Store Connect Team API Key authorized for notarization, normally
with the Developer role or higher. An individual API key is not supported by
this workflow. Apple describes API-key authentication in
[TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

No GitHub personal access token or Keychain-password secret is required. The
workflow uses the built-in `GITHUB_TOKEN` to publish and generates a random
temporary Keychain password on each run. Only the publishing job receives
`contents: write`; the job holding Apple credentials has `contents: read`.

One way to set file secrets from your own terminal is:

```bash
base64 -i /path/to/DeveloperID.p12 |
  gh secret set MACOS_DEVELOPER_ID_P12_BASE64 --repo jollyjinx/JollysMQTT --env macos-release
gh secret set MACOS_DEVELOPER_ID_P12_PASSWORD --repo jollyjinx/JollysMQTT --env macos-release
base64 -i /path/to/JollysMQTT.provisionprofile |
  gh secret set MACOS_DEVELOPER_ID_PROFILE_BASE64 --repo jollyjinx/JollysMQTT --env macos-release
gh secret set APP_STORE_CONNECT_API_KEY_P8 --repo jollyjinx/JollysMQTT --env macos-release < /path/to/AuthKey_EXAMPLE.p8
gh secret set APP_STORE_CONNECT_API_KEY_ID --repo jollyjinx/JollysMQTT --env macos-release
gh secret set APP_STORE_CONNECT_API_ISSUER_ID --repo jollyjinx/JollysMQTT --env macos-release
```

The commands without input redirection prompt locally for the secret value.
The workflow can publish automatically after tag push; environment approval
rules, if configured by the repository owner, still apply.

## Prepare Developer ID signing and CloudKit

1. In Apple Certificates, Identifiers & Profiles, create or select a
   **Developer ID Application** certificate for team `5V8J7476Q9`. Export the
   certificate **with its private key** as a password-protected `.p12` from
   Keychain Access. Apple Distribution and Developer ID Installer certificates
   do not satisfy this workflow.
2. Confirm the explicit macOS App ID `eu.jinx.jollymqtt` has CloudKit and push
   enabled and is associated with `iCloud.eu.jinx.jollymqtt`.
3. Create a **Developer ID distribution provisioning profile** for that App ID
   and the selected Developer ID Application certificate. Download the
   `.provisionprofile` file. A development, wildcard, or Mac App Store profile
   will be rejected. See Apple's
   [Developer ID guidance](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
   which covers CloudKit, push, and profile expiration.
4. Verify the existing Production schema and real-device sync using
   `AI/CLOUDKIT_PROVISIONING_ACCEPTANCE.md`. The release workflow preserves
   entitlements; it does not modify Apple App IDs, capabilities, or schemas.

Official identity, bundle ID, and container are deliberate constants in the
release script and the Xcode Official Release configuration. The workflow is
restricted to the official GitHub repository. Forks must configure their own
team, identifiers, container, signing profile, and repository guard.

## Release a committed version

Merge or push the workflow and intended release changes to GitHub before
tagging. From a clean release commit:

```bash
git tag -a v0.2.0 -m "JollysMQTT 0.2.0"
git push github refs/tags/v0.2.0
```

`github` is this checkout's GitHub remote. `gitmaster.jinx.eu` remains the
primary Git server; this workflow is triggered by the GitHub copy of the tag.
Mirror the same tag to `jnxpublic` separately when maintaining both remotes.
Pushing a tag is an explicit public release operation once secrets are set.

The workflow validates release-script gates and runs `swift build` and
`swift test --parallel` before signing. Its release script then:

- Requires a clean source tree and a version tag pointing at the checked-out
  commit. Output must be in a new directory outside the repository.
- Seeds Xcode's generated lockfile from the checked-in package lock, resolves
  Xcode's root metadata, and rejects changed dependency versions or revisions.
- Installs signing material into a temporary Keychain and restores the
  original user Keychain search list and provisioning-profile files on exit.
- Rejects expired or mismatched profiles, certificates, teams, App IDs,
  CloudKit containers, environments, and push authorization.
- Archives **with signing enabled**, then exports using `method=developer-id`
  and `iCloudContainerEnvironment=Production`.
- Checks the archive and exported app's actual signed entitlements, embedded
  profile, certificate, hardened runtime, timestamp, architectures, and version.
  Export must preserve every archived entitlement. Sandbox and outbound
  network access, Production CloudKit, and production push are required.
- Notarizes a ZIP of the app, requires an explicit `Accepted` result, then
  staples and validates the app ticket. Packages that stapled app with an
  Applications shortcut into a signed DMG, notarizes the DMG separately, and
  staples and validates its ticket. This preserves the app ticket after copying
  out of the disk image. See Apple's
  [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
- Requires Gatekeeper assessments to pass for both app and DMG, then computes
  SHA-256 **after stapling**. Publishable assets are created only after every
  gate and signing-material cleanup succeeds.

The publishing job verifies the checksum and creates a public GitHub Release
with `JollysMQTT-X.Y.Z-universal.dmg` and `SHA256SUMS`, using generated release
notes. It requires the tag to exist and does not overwrite existing releases
or assets. To recover a failed upload, inspect the existing draft/release and
the successful workflow artifact before retrying; do not replace a published
version's binaries silently.

Notarization reports are saved as a separate workflow artifact for seven days,
including on failure when available. Each submission has a 30-minute wait
limit; a timeout blocks publishing even if Apple continues processing later.
The full build job has a 120-minute limit. Signing keys, `.p12` exports,
provisioning profiles, archives, and temporary Keychains are not uploaded as
workflow artifacts.

## Local validation and acceptance limits

Run release regression tests without any Apple credentials or uploads:

```bash
python3 -B -m unittest discover -s Scripts/Tests -p 'test_macos_release.py' -v
python3 Scripts/release_macos_dmg.py --tag v0.2.0 --validate-tag
git diff --check
```

For a real local build, set the same six secret environment variables and run
`python3 Scripts/release_macos_dmg.py --tag vX.Y.Z --output-dir /absolute/new/output`.
This submits the app and DMG to Apple's notary service but never publishes to
GitHub. It requires a clean tagged commit and the same Xcode toolchain.

Automated fixtures verify failure handling and preservation gates; they cannot
prove Apple's authorization or actual CloudKit synchronization. The initial
signed Developer ID build, notarization, GitHub-hosted run, and installed-app
Production CloudKit sync remain pending until the owner configures secrets
and runs an authorized release. Do not report them as passed based on mocks
or unsigned builds.

Local validation on 2026-10-16 passed all nine release regression tests,
actionlint 1.7.12, the existing TestFlight script tests, `swift build`, and
macOS Debug and unsigned iOS builds. The full parallel package suite passed on
rerun; its first run exposed an existing intermittent expectation in
`ProfileSyncTests.canceledQueuedWriterPreservesTail` about generation order.
No storage implementation or test behavior was changed. Xcode resolution was
also checked against every pinned package revision. Local builds used the
installed Xcode 27.2; the workflow's Xcode 26.3 run remains pending.
