---
title: "CloudKit Provisioning and Recovery Acceptance"
description: "Build variants, recovery behavior, development schema, deterministic checks, and pending signed two-device release gates."
area: "release"
doc_type: "acceptance-record"
status: "implemented-pending-external-acceptance"
last_reviewed: "2026-07-29"
tags:
  - "cloudkit"
  - "provisioning"
  - "profiles"
  - "privacy"
  - "release"
---

# CloudKit Provisioning and Recovery Acceptance

Ticket #22 adds release-ready build selection and local-data-preserving recovery
logic. It does **not** establish that the intended Apple container exists or
that signing, development schema deployment, production promotion, or
two-device synchronization has succeeded.

The machine used for this implementation reported zero valid code-signing
identities on 2026-07-29. No Apple account, signed build, CloudKit Dashboard
container, or second signed device was available. Every such result is
therefore explicitly pending below.

## Build families

| Configuration | Profile adapter | CloudKit container | CloudKit environment | Push environment |
|---|---|---|---|---|
| `Debug` | `LocalOnlyProfileSync` | none | none | none |
| `Release` | `LocalOnlyProfileSync` | none | none | none |
| `Official Development` | `CloudKitProfileSync` | intended `iCloud.eu.jinx.JollysMQTT` | Development | development |
| `Official Release` | `CloudKitProfileSync` | intended `iCloud.eu.jinx.JollysMQTT` | Production | production |

Ordinary Debug and Release are the default open-source/self-build
configurations. Their resolved Info.plist selects `localOnly`, they have no
iOS entitlement file, and the macOS entitlement contains only app sandbox and
outgoing-network access. They never construct `CKContainer` or address the
intended official container.

The profile-sync parser fails closed. `cloudKit` mode, a nonempty `iCloud.`
container identifier, and a nonempty custom-zone name must all be present.
Missing, malformed, or partial values select `LocalOnlyProfileSync`. A fork
can supply its own complete values and entitlements; ordinary configurations
never inherit the intended official identifier.

Official configurations use platform-specific entitlement files:

- iOS/iPadOS: `aps-environment`
- macOS: `com.apple.developer.aps-environment`
- both: `com.apple.developer.icloud-container-identifiers`,
  `com.apple.developer.icloud-services = CloudKit`, and
  `com.apple.developer.icloud-container-environment`

No team identifier or provisioning profile is checked into the repository.
The official identifier in source is an intention, not evidence of container
ownership or access.

## Recovery contract

The atomic local profile replica remains authoritative for interactive use in
every state. None of these paths deletes local profiles, local credentials,
workspace state, or history.

| Condition | Presented state | Choices and behavior |
|---|---|---|
| Offline | retryable status | Retry iCloud sync, or keep profiles only on this device |
| Rate limited / service busy | retryable status, preserving retry delay | Retry iCloud sync, or keep profiles only on this device |
| Signed out | recovery required | Sign in and explicitly use preserved local profiles with that account, or keep them device-only |
| Signed in / account switched | recovery required | Explicitly upload preserved local profiles to the current account, or keep them device-only |
| User-deleted custom zone | recovery required | Explicitly recreate the zone from local profiles, or keep them device-only |
| Purged custom zone | distinct recovery required | Explicitly recreate the zone from local profiles, or keep them device-only |
| Encrypted-data key reset | distinct recovery required | Explicitly upload local profiles under the new key, or keep them device-only |

`CKSyncEngine` account changes clear its pending changes. On an account or zone
reset the delegate also clears its staged transport snapshot, fetched records,
server-record bases, and all pending engine database/record changes. Later
local edits remain only in the wrapper's memory and the durable local replica.
No outgoing batch is provided until the user explicitly resumes. Resume
re-stages the latest durable replica, including permanent tombstones, and adds
the zone and records again.

Choosing **Keep Profiles Only on This Device** writes a device-local preference
under the app's Application Support directory before any later launch may
stage profiles. Official builds load that preference before constructing or
calling the CloudKit adapter. The choice therefore survives relaunch, never
syncs to another device, and presents an explicit **Enable iCloud Profile
Sync** action. Re-enabling persists the new choice before the latest local
replica is staged. A missing preference defaults to the build configuration;
a corrupt preference fails closed with Cloud sync disabled. If an opt-out
write fails, sync remains off for the current process and the UI explicitly
asks the user to retry saving before quitting; it does not claim that the
choice survived relaunch. Ordinary LocalOnly builds ignore this CloudKit-only
preference and remain plain LocalOnly builds.

The server-list UI refreshes sync status while it is visible. Recovery events
reported by automatic `CKSyncEngine` activity therefore become visible without
a manual sync. Multiple windows pass the recovery value they observed;
the repository reserves resolution before its first suspension, so a
concurrent or stale second choice cannot be applied after another window has
started resolving it.

## Development encrypted-field schema

Expected Development schema:

| Item | Value |
|---|---|
| Database | private |
| Zone | `EncryptedBrokerProfiles` |
| Record type | `EncryptedBrokerProfile` |
| Record name | lowercase broker-profile UUID |
| Encrypted field | `profilePayload`, Bytes |
| Ordinary application fields | none |

The `profilePayload` bytes contain the versioned profile-replica envelope:
content register, independent rank register, logical revisions, and permanent
tombstone. Broker name, endpoint, username, subscriptions, ranks, revisions,
and tombstones are only in `CKRecord.encryptedValues`. Passwords, credential
availability, history, payloads, and workspace state are absent.

Automated codec tests pass for the schema allow-list, encrypted-only values,
UUID-only record names, v1-to-v2 migration, tombstones, conflict bases, and
absence of credential/history/workspace keys. Actual Development schema
creation and inspection in CloudKit Dashboard is **PENDING**.

### Local deterministic validation

The following checks passed on 2026-07-29:

- Debug and Release `swift build`;
- Debug and Release `swift test --parallel` (the opt-in Mosquitto integration
  suite remained skipped);
- unsigned macOS and generic iOS Xcode builds for `Debug`, `Release`,
  `Official Development`, and `Official Release`;
- locally signed iOS Simulator builds for both official configurations;
- resolved build-setting checks on macOS, generic iOS, and generic iOS
  Simulator;
- built Info.plist checks confirming that ordinary products contain
  `localOnly` and no container/zone, while official products contain the
  intended mode, container, and zone;
- plist, entitlement, localization JSON, changed-file strict Swift formatting,
  import-boundary, privacy, and `git diff --check` audits.

The generated official Simulator `*-Simulated.xcent` files contain the
platform push key, intended container, CloudKit service, and the expected
Development or Production environment. This validates local build-setting
resolution only; it is not evidence that the Apple team owns the container or
that a simulator can access it.

Repository-wide strict Swift formatting still reports pre-existing errors in
unrelated, untouched files. All Swift files changed for this ticket pass the
strict formatter. That existing repository-wide debt was not mechanically
rewritten as part of provisioning work.

### Human Development schema acceptance

1. Confirm the Apple team owns `iCloud.eu.jinx.JollysMQTT`; create it if
   necessary. Do not substitute another team's production container.
2. Enable iCloud/CloudKit and remote notifications for the official app ID on
   iOS/iPadOS and macOS. Create matching development provisioning profiles.
3. Build `Official Development` with a valid development identity. Inspect the
   signed app with `codesign -d --entitlements :-` and confirm the resolved
   platform-specific push key, Development container environment, CloudKit
   service, and exactly the intended container.
4. Sign into a disposable iCloud test account and create one non-secret test
   profile. Never use a real broker address, username, or password for schema
   verification.
5. In CloudKit Dashboard's Development environment, verify the private custom
   zone, record type, UUID record name, and single encrypted Bytes field.
   Confirm no ordinary endpoint, username, rank, or tombstone field exists.
6. Export or screenshot the schema inspection and record the tester, date,
   build commit, OS versions, and result in the table below.

## Two-device acceptance record

Use two signed devices or simulators logged into the same disposable iCloud
account. Credentials are deliberately device-local.

| Scenario | Expected result | Result |
|---|---|---|
| Create on A | Profile appears on B; B reports missing local password when username is present | **PENDING — no signed devices/account** |
| Credential on B | One password entry changes B to available and connects; no second entry is required until local deletion/replacement | **PENDING — no signed devices/account/broker fixture** |
| Edit A and B independently | Logical revisions converge without using wall-clock time | **PENDING — no signed devices/account** |
| Reorder on A while editing on B | Independent rank/content registers preserve both operations | **PENDING — no signed devices/account** |
| Delete on A while B is offline | Permanent tombstone prevents resurrection when B returns | **PENDING — no signed devices/account** |
| Offline local edit | Local edit remains usable and uploads after retry | **PENDING signed integration; automated repository test passes** |
| Rate limit | Local data remains usable; retry honors CloudKit's retry diagnostic | **PENDING signed integration; automated adapter test passes** |
| Account switch | Prior account's local profiles are not uploaded before explicit consent | **PENDING signed integration; automated recovery test passes** |
| Keep device-only, relaunch, then re-enable | Relaunch performs no CloudKit staging until the explicit re-enable action; the latest local replica is then staged | **PENDING signed integration; automated relaunch test passes** |
| User-deleted zone | Local replica survives; zone is recreated only after explicit consent | **PENDING signed integration; automated delegate test passes** |
| Encrypted-data reset | Local replica survives; records are re-uploaded only after explicit consent | **PENDING signed integration; automated delegate test passes** |

For each human run, record:

- commit and official configuration;
- device models and OS versions;
- disposable iCloud account identifier (redacted in public artifacts);
- start/end profile UUIDs and visible order, without private endpoint data;
- whether each device had a local credential before and after;
- Dashboard record count and tombstone presence;
- pass/fail plus links to private evidence.

## Production release gate

Production promotion remains blocked until all of the following are complete:

- Development schema inspection passes and evidence is retained.
- Every two-device scenario above passes on the release candidate.
- Signed iOS/iPadOS and macOS entitlements are inspected.
- App Store and, if shipped, Developer ID archives pass validation.
- The tested Development schema is promoted to Production in CloudKit
  Dashboard by an authorized release operator.
- A clean `Official Release` install confirms Production access without
  changing or auto-creating an incompatible schema.

Production schema promotion is an external, consequential release action. It
must not be inferred from local tests and must never be performed by an
unattended implementation task.
