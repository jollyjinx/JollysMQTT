---
title: "TestFlight Release Workflow"
description: "Clean-commit archive, versioning, signing, verification, and App Store Connect upload workflow for JollysMQTT iOS and macOS builds."
area: "release"
doc_type: "release-runbook"
status: "active"
last_reviewed: "2026-09-30"
tags:
  - "testflight"
  - "app-store-connect"
  - "signing"
  - "release"
  - "versioning"
---

# TestFlight Release Workflow

`Tools/build-and-upload-testflight.sh` follows the JollysFastVNC2
archive-then-upload workflow. It archives the same committed source for iOS and
macOS, verifies both version fields in both archives, then submits both
archives to App Store Connect/TestFlight.

The script always uses `Official Release` unless explicitly overridden. This
is required because ordinary `Release` is the local-only open-source build;
`Official Release` selects the Production CloudKit container, production push
environment, and official entitlements.

## Safety contract

- The worktree, including untracked files, must be clean.
- The default marketing version comes from the app target's Official Release
  `MARKETING_VERSION` setting (`0.1.0` currently). `--version X.Y.Z` chooses a
  version for both archives without editing the project; `--version auto`
  derives `YYYY.MM.DD` from the commit date. The chosen version is passed to
  both archives and verified in their `CFBundleShortVersionString` fields.
- Build numbers use the JNX commit timestamp format
  `YYYYMMDD.HHMMSS.TYPE`, where `main`/`master` is type 3, `develop` is type 2,
  and another clean branch is type 1. Dirty type-0 builds are rejected.
- Both archives use the same build number and are inspected before upload.
- The script verifies that HEAD and the worktree did not change while
  archiving.
- Archive and export output must remain outside the Git worktree.
- The iOS archive uses Apple Development. The macOS archive uses Apple
  Distribution because Xcode's Mac App Store export preserves SwiftPM
  resource-bundle signatures; they must match the distribution certificate in
  the embedded Mac App Store provisioning profile.
- A retry for the same commit preserves previous output and selects the next
  available `-retry-N` directory. An explicit `--output-dir` remains
  non-overwriting and fails if its path already exists.
- The script never promotes a CloudKit schema. Production schema readiness is
  still governed by `CLOUDKIT_PROVISIONING_ACCEPTANCE.md`.

## Usage

Use Xcode's configured App Store Connect account:

```bash
Tools/build-and-upload-testflight.sh
```

Choose a new marketing version in the same command that builds and uploads:

```bash
Tools/build-and-upload-testflight.sh --version 0.2.0
```

Use `--version auto` for a date-based marketing version. Run `--preflight` or
`--dry-run` with either version choice to inspect it without uploading.

Create and verify archives without uploading:

```bash
Tools/build-and-upload-testflight.sh --archive-only
```

Print the archive and upload commands without executing them:

```bash
Tools/build-and-upload-testflight.sh --dry-run
```

Validate the clean commit, team, API-key tuple, output location, and export
options without building:

```bash
Tools/build-and-upload-testflight.sh --preflight
```

Preflight does not contact the Apple Developer portal or prove that the team
owns the explicit App ID, iCloud container, signing certificates, or matching
provisioning profiles. `Official Release` requires the explicit
`eu.jinx.jollymqtt` App ID with iCloud/CloudKit and Push Notifications, plus
the intended `iCloud.eu.jinx.jollymqtt` container. A wildcard provisioning
profile cannot satisfy those entitlements. See
[CLOUDKIT_PROVISIONING_ACCEPTANCE.md](CLOUDKIT_PROVISIONING_ACCEPTANCE.md) for
the current signed-release gate.

Before exporting or uploading, create an App Store Connect app record for the
exact bundle ID `eu.jinx.jollymqtt`. The Developer portal App ID and iCloud
container do not create this App Store Connect record. If shipping both iOS
and macOS through TestFlight, add both platforms to the matching app record.
The account needs a role that can create app records, and the Account Holder
must have accepted any required agreements. An archive can succeed while the
export account cannot see the matching App Store Connect app record. See Apple's
[add-a-new-app instructions](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
and [add-platforms instructions](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms).

The script uses Xcode's configured App Store Connect account by default. The
2026-09-30 14:26 attempt could not find an app record visible to the export
credentials. On a later retry, the same cached-credential lookup warning for
`pst@estos.de` (`Xcode-Token` missing) appeared, but Xcode still reached App
Store Connect package validation. Treat that warning as non-fatal for that
retry; the log does not identify which account the export authenticated as.
If a future export again cannot find the app record, check Xcode's configured
account/team or use an API key belonging to the intended App Store Connect
provider. The script accepts the complete API-key tuple described below.

The 2026-09-30 retry reached App Store Connect's package validation, which
rejected the iOS app for missing `CFBundleIconName` and the required iPhone and
iPad icon sizes. The project had an `AppIcon.appiconset` with no referenced
image files. The app now includes a 1024-pixel iOS marketing icon, populated
macOS icon variants, and `CFBundleIconName = AppIcon` in its explicit
`Info.plist`. Rerun the release script to confirm package validation accepts
the new assets.

The same build's macOS upload was later rejected with `ITMS-90284` for the
SwiftPM resource bundles `JollysMQTTPackage_JollysMQTT.bundle`,
`swift-nio-ssl_NIOSSL.bundle`, and `swift-nio_NIOPosix.bundle`. They are
codeless resource bundles, but the macOS archive signed them with Apple
Development. Xcode's Mac App Store export preserved their nested
`_CodeSignature` directories while remotely signing the containing app with
Apple Distribution, so the nested signatures did not match the Store profile.
The release script now disables code signing for the macOS archive. Xcode's
Mac App Store export then signs the app and seals the codeless package bundles
as resources. Before any export, the script verifies that each package bundle
has no executable and no nested signature; a new executable bundle needs a
separate distribution-signing solution. The iOS archive continues to use
Apple Development.

The shared app `Info.plist` sets `ITSAppUsesNonExemptEncryption` to `false` so
App Store Connect does not repeat the export-compliance questionnaire for each
new build. The production MQTT TLS configuration uses Apple's
Network.framework transport with full certificate verification; `CryptoKit` is
used for SHA-256-derived identifiers. Reassess this declaration before adding
custom encryption or changing the production transport. Apple defines `false`
as no encryption or encryption that is exempt from export-compliance
documentation, including encryption used by linked third-party libraries; see
[ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption).

Run the release-script regression tests after changing its signing, output,
or safety behavior:

```bash
Tools/Tests/build-and-upload-testflight-tests.sh
```

For API-key authentication, set all three values:

```bash
APP_STORE_CONNECT_API_KEY_PATH=/absolute/path/to/AuthKey_Example.p8 \
APP_STORE_CONNECT_API_KEY_ID=EXAMPLE123 \
APP_STORE_CONNECT_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
Tools/build-and-upload-testflight.sh
```

The default team is `5V8J7476Q9`, matching SmartyBox. Override it with
`JOLLYSMQTT_TEAM_ID`. `JOLLYSMQTT_SCHEME`, `JOLLYSMQTT_CONFIGURATION`, and
`XCODEBUILD_BIN` are also available for controlled diagnostics. Do not use a
non-official configuration for a real upload.

Successful upload is only submission evidence. App Store Connect processing,
export-compliance questions, tester assignment, CloudKit production schema,
and the human release gates remain separate checks.
