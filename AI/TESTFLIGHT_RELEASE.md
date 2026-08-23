---
title: "TestFlight Release Workflow"
description: "Clean-commit archive, versioning, signing, verification, and App Store Connect upload workflow for JollysMQTT iOS and macOS builds."
area: "release"
doc_type: "release-runbook"
status: "active"
last_reviewed: "2026-08-23"
tags:
  - "testflight"
  - "app-store-connect"
  - "signing"
  - "release"
  - "versioning"
---

# TestFlight Release Workflow

`Tools/build-and-upload-testflight.sh` follows the established SmartyBox
release workflow. It archives the same committed source for iOS and macOS,
verifies that both archives contain the same deterministic build number, then
submits both archives to App Store Connect/TestFlight.

The script always uses `Official Release` unless explicitly overridden. This
is required because ordinary `Release` is the local-only open-source build;
`Official Release` selects the Production CloudKit container, production push
environment, and official entitlements.

## Safety contract

- The worktree, including untracked files, must be clean.
- Build numbers use the JNX commit timestamp format
  `YYYYMMDD.HHMMSS.TYPE`, where `main`/`master` is type 3, `develop` is type 2,
  and another clean branch is type 1. Dirty type-0 builds are rejected.
- Both archives use the same build number and are inspected before upload.
- The script verifies that HEAD and the worktree did not change while
  archiving.
- Archive and export output must remain outside the Git worktree.
- Automatic signing archives with an Apple Development identity. App Store
  export then re-signs the submitted products for distribution.
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
