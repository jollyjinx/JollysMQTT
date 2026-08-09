---
title: "R6 Release Readiness Acceptance"
description: "Automated release-candidate evidence, first-release schema baseline, external gates, and the smallest remaining human acceptance checklist."
area: "release"
doc_type: "acceptance-record"
status: "automated-gates-passed-pending-human-acceptance"
last_reviewed: "2026-08-09"
tags:
  - "release"
  - "acceptance"
  - "signing"
  - "migration"
  - "restoration"
  - "r6"
---

# R6 Release Readiness Acceptance

This record consolidates the reproducible R6 evidence for the first JollysMQTT
release candidate. It does **not** approve a release. Automated source,
package, integration, storage, performance, and unsigned-build gates pass, but
signing, CloudKit production promotion, final artwork, and device/manual
acceptance require human-controlled resources and remain open.

## Candidate and environment

- Source baseline: commit `2c4d5ab93cc70c44c0b9f346555981133304ec2c`
  plus the tests and documents committed with this record.
- Marketing version: `0.1.0`; build number: `1`.
- Xcode: 27.0 (`27A5228h`); Swift: 6.4; XcodeGen: 2.45.4.
- Host: Apple silicon macOS 27.0 (`26A5388g`), arm64.
- Valid code-signing identities reported by `security find-identity -v -p
  codesigning`: **0**.

## Automated gate results

| Gate | Result | Evidence and boundary |
|------|--------|-----------------------|
| Package build | Pass | `swift build` completed. |
| Package tests | Pass | `swift test --parallel` completed; opt-in broker tests were skipped as designed. |
| Isolated MQTT integration | Pass | Seven `MQTTTransportIntegrationTests` passed against an isolated Mosquitto instance, including QoS, session behavior, trusted/untrusted TLS, cancellation, and overload handling. No real broker or credentials were used. |
| Reviewed full performance baseline | Pass, retained | The accepted 2026-07-29 Mac16,7 release run exercised the paced 10-minute/1,000,000-message fixture with exact history parity, 1,666.8235 ingest messages/s, queues settled to zero, 8.3191 main updates/s, memory stabilization, and last-feed release. The reviewed raw result and baseline remain in `AI/Performance/`. |
| Quick release performance probe | Pass as development evidence | 1,000 messages ingested and written; 1,103.822 ingest messages/s; bounded queues settled to zero; 6.6229 main updates/s; feed released; SQLite peak/settled size 885,616 bytes. This quick run does not replace a full acceptance-duration performance run. |
| Full release storage probe | Pass | 1,000,000/1,000,000 messages; 89,793.377 messages/s; schema 5; independent peak SQLite allocation 239,572,136 bytes, below the 262,144,000-byte cap; settled allocation 133,779,456 bytes; retention, queue backpressure, zero-orphan convergence, WAL truncation, and forced-writer crash recovery passed. |
| Unsigned platform matrix | Pass | Debug, Release, Official Development, and Official Release built for macOS and generic iOS with signing disabled: eight builds total. One overlapping invocation briefly locked Xcode's build database; the serialized retry passed. |
| Build-setting resolution | Pass structurally | Local builds resolve to local-only sync. Official Development resolves to the Development CloudKit environment and development push. Official Release resolves to Production and production push. Version, strict concurrency, Swift language mode, and user-script sandboxing resolve consistently. |
| Release metadata source contract | Pass | Tests pin version/build-family metadata, least-privilege entitlement key families and CloudKit substitutions, the local-network privacy string, and every required app-icon catalog slot. |
| History migration matrix | Pass | A parameterized test opens schema versions 1, 2, 3, and 4, migrates each to version 5, and verifies legacy message content plus current metadata and coverage-gap usability. |
| Localization/catalog audit | Pass | The extraction audit found 452 source keys and 452 catalog keys in source language `en`; `xcstringstool` accepted a dry-run compile. XcodeGen regeneration produced no project diff, and every plist/entitlement parsed successfully. |
| Compiler/concurrency audit | Pass | The build matrix produced no project-source or Swift-concurrency warnings. Xcode selected the first of two matching local Mac destinations in some macOS builds; this is destination ambiguity, not a source diagnostic. |

SwiftPM printed stale cache-file warnings during probe compilation for paths
under an older checkout. They did not identify source or concurrency warnings
and did not affect the successful probes. Clearing reusable package caches was
not necessary for release evidence.

## First-release persistence baseline

Version `0.1.0` is documented as the first public release candidate; no earlier
publicly shipped JollysMQTT version is documented. The internal pre-release
formats below remain compatibility inputs and are tested rather than discarded:

| Store | Write version | Accepted older state | Recovery behavior covered by tests |
|-------|---------------|----------------------|------------------------------------|
| Local broker profiles | 2 | Version 1 | V1-to-V2 conversion, atomic backup recovery, tombstone preservation, and future-version refusal. |
| Encrypted CloudKit profile envelope | 2 | Version 1 | V1-to-V2 decode and authenticated envelope handling. Real CloudKit schema and multi-device convergence remain external gates. |
| Workspace document | 1 | Version 1 with absent additive fields and legacy single-chart state | Optional-field defaults, single-chart-to-dashboard restoration, independent workspaces, corrupt-state quarantine, and future-version preservation. |
| SQLite history | 5 | Versions 1 through 4 | Transactional migration to version 5, preserved legacy history, current metadata defaults, coverage-gap writes, retention, and interrupted-write recovery. |
| History retention settings | 1 | Version 1 | Relaunch persistence plus corrupt/future-version fail-closed behavior. |
| Keychain credentials | Service-scoped V1 contract | No credential bytes in profile or CloudKit documents | Device-local lookup/removal and serialized-data privacy tests. There is no previously shipped credential migration. |

## Restoration evidence and limits

Deterministic package tests cover normal scene close/relaunch, independent
multi-window workspace state, profile backup corruption recovery, CloudKit
envelope decoding, workspace optional-field and legacy-chart restoration,
future/corrupt workspace preservation, all pre-release SQLite schema
migrations, and a storage writer killed during an uncommitted transaction.

The focused macOS largest-text/relaunch coverage and focused iPad semantic-tree
coverage recorded on 2026-08-08 in
`AI/ADAPTIVE_UX_ACCESSIBILITY_ACCEPTANCE.md` remain the accepted simulator UI
evidence. They used deterministic local fixtures and no broker or credentials.

A new focused macOS XCUITest attempt on 2026-08-09 did not launch a test.
Xcode's runner failed before execution while trying to read a bundle identifier
from a bare build product path named `JollysMQTT` instead of the existing
`JollysMQTT.app`.
Accordingly, that attempt is recorded as runner/invocation evidence only, not
as a passed or failed application UI test.

The current automated record does not cover OS-forced application termination,
a full application-process crash with several open windows, display-topology
changes, install/update transitions, iOS protected-data state transitions on
hardware, VoiceOver/manual accessibility review, or physical-device
performance and thermal behavior.

## Release metadata and configuration audit

- `Info.plist` derives the short version and build number from project settings
  and declares the local-network privacy purpose.
- Ordinary builds remain local-only. Official builds use separate development
  and production CloudKit environments through substituted settings.
- Entitlement files contain only their intended sandbox, network-client,
  CloudKit, and push families. Unsigned builds prove compilation and resource
  processing, not provisioned entitlement authorization.
- The app-icon catalog declares the required iOS and macOS slots but contains
  no image files. Slot metadata passing is not artwork acceptance.
- `AI/xcode-security-settings.md` remains the controlling decision record.
  Enhanced Security and pointer authentication are deferred pending explicit
  approval and signed hardware validation; release readiness does not silently
  enable them.
- Human-readable release notes are drafted in
  `AI/RELEASE_NOTES_0.1.0_DRAFT.md` and remain unapproved.

## Blocking external gates

1. Produce signed iOS and macOS archives with the intended identities,
   provisioning profiles, bundle ID, and official entitlements; inspect the
   archived signatures and complete the applicable Apple validation and
   notarization workflows. No valid signing identity is installed on this host.
2. Deploy and inspect the CloudKit Development schema, complete the documented
   two-device convergence scenarios, promote the exact schema to Production,
   and verify a clean Production install. Do not infer this from unsigned
   build settings.
3. Supply and approve final app-icon artwork for every catalog slot, then
   validate rendered icons on supported platforms.
4. Execute the manual/device restoration, update, protected-data,
   accessibility, display-change, crash, thermal, and long-duration performance
   checklist on release hardware.
5. Review and approve the release notes and the linked privacy, security,
   accessibility, performance, CloudKit, and Xcode-security acceptance records.

## Smallest human release checklist

- [ ] Install the intended Apple signing identities/profiles and archive both
      platforms from the Official Release configuration.
- [ ] Verify archive signatures and effective entitlements, then complete
      Apple validation/notarization without changing the tested candidate.
- [ ] Complete the Development-to-Production CloudKit acceptance sequence and
      record the schema identifiers and two-device results.
- [ ] Add approved icon artwork and visually inspect every required rendition.
- [ ] Run the manual/device matrix for relaunch/crash/update/protected data,
      multi-window/display restoration, accessibility, and sustained performance.
- [ ] Approve the draft release notes and every referenced acceptance record.

Until every checkbox has dated evidence and an accountable approver, R6 and
GitHub issue #26 remain open.
