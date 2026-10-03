---
title: "CloudKit Provisioning and Recovery Acceptance"
description: "Build variants, recovery behavior, development schema, deterministic checks, and pending signed two-device release gates."
area: "release"
doc_type: "acceptance-record"
status: "implemented-pending-external-acceptance"
last_reviewed: "2026-10-03"
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

A 2026-08-23 `Official Release` archive probe still reported zero valid local
code-signing identities. Automatic signing progressed beyond the former
automatic-signing/Apple-Distribution conflict after selecting Apple
Development, then provisioning failed because team `5V8J7476Q9` could not
register `eu.jinx.JollysMQTT` and its wildcard profile lacked the required Push
Notifications and CloudKit entitlements. No signed archive was produced or
uploaded.

The 2026-09-24 TestFlight attempt from commit `e201396` stopped at the same
iOS archive provisioning errors. At the time, the Apple Developer identifier
list for team `5V8J7476Q9` did not contain `eu.jinx.JollysMQTT`, and the locally
installed profiles for that team contained a wildcard iOS profile but no exact
JollysMQTT profile. A keychain query inside the Codex filesystem sandbox
reported zero identities; the same read-only query outside that sandbox
reported twelve valid identities, but no Apple Development or Apple
Distribution identity for team `5V8J7476Q9`. The sandboxed zero count is not
evidence that the Mac has no certificates. The user initially selected the
lowercase candidate `eu.jinx.jollysmqtt`, with container
`iCloud.eu.jinx.jollysmqtt`; that candidate was later rejected as unavailable
to the signing team. The exact registered ID confirmed afterward is recorded
below.

A further 2026-09-24 archive attempt from commit `58af7dc` confirms the
lowercase identifier is used by the project, but Xcode still cannot register
`eu.jinx.jollysmqtt` to team `5V8J7476Q9` because the identifier is not
available to that team. Xcode then selects the wildcard iOS provisioning
profile, which lacks Push Notifications and the configured CloudKit
entitlements/container. The iOS archive failed before export or upload. The
App ID must be available to the signing team, and an explicit profile with the
required capabilities must be provisioned before TestFlight can proceed.

On 2026-09-25, the user confirmed the registered explicit App ID shown for
team `5V8J7476Q9` is `eu.jinx.jollymqtt` (without the extra `s` in the prior
candidate). The app and release configuration now use that exact ID. The
matching CloudKit container `iCloud.eu.jinx.jollymqtt` still needs portal
verification and association with the App ID.

A subsequent iOS `Official Release` archive reached the explicit profile for
`eu.jinx.jollymqtt`, confirming the bundle ID is now recognized. The selected
`iOS Team Provisioning Profile: eu.jinx.jollymqtt` lacks the
`com.apple.developer.icloud-container-environment` entitlement and does not
authorize the configured CloudKit container identifier. The archive failed
before export or upload. Enable iCloud with CloudKit support for this App ID,
assign the configured container, then regenerate or refresh the provisioning
profile before retrying.

The next 2026-09-25 archive attempt reports the same two CloudKit profile
errors. This confirms the profile refresh or App ID/container configuration
has not yet taken effect; the bundle identifier itself is no longer the
blocker.

On 2026-09-30, the user supplied Apple Developer screenshots showing the
registered `eu.jinx.jollymqtt` App ID and the `JollyMqtt Container` assignment
to `iCloud.eu.jinx.jollymqtt`. The subsequent `Official Release` run archived
both iOS and macOS successfully and verified one bundle version in each
archive. This advances past the earlier CloudKit provisioning failure. The
14:26 export attempt could not find an App Store Connect app record visible to
its credentials. A later 14:54 retry reached App Store Connect package
validation, despite logging the same cached-credential lookup warning for
`pst@estos.de` (missing `Xcode-Token`); that warning was non-fatal for this
retry. Package validation rejected the iOS app for missing icon metadata and
sizes. No successful TestFlight upload is recorded yet.

## 2026-10-03 distributed macOS sync failure

The installed `/Applications/JollysMQTT.app`, version `0.1.0`, build
`20261003.082220.3`, repeatedly displays the generic profile-sync failure.
Read-only inspection of the installed app and its unified logs established:

- Strict signature verification passes outside the filesystem sandbox.
- The app has App Sandbox, outgoing-network access, Production CloudKit,
  `iCloud.eu.jinx.jollymqtt`, and production push entitlements. Its signature
  also contains `beta-reports-active`.
- The CloudKit daemon approves access to the expected Production container
  and successfully saves the `EncryptedBrokerProfiles` zone.
- Each of the three profile-record saves fails. The daemon reports
  `Syntax error in request`; the app receives `CKErrorDomain` code 2
  (`partialFailure`). The per-record descriptions are privacy-redacted.
- The adapter currently reduces this partial failure to `internalFailure`,
  producing the generic banner and Retry action. That banner alone cannot
  distinguish a schema error from other CloudKit failures.

This rules out absent app entitlements and failure to reach the container for
the observed run. After the user signed in, CloudKit Console inspection of
team `5V8J7476Q9`, container `iCloud.eu.jinx.jollymqtt`, confirmed that **both
Development and Production contain only the built-in `Users` record type**.
`EncryptedBrokerProfile` is absent in both environments. This confirms the
missing Production schema that prevents profile creation; successful sync
after deployment remains to be verified. No `cktool` management token is
configured.

The required additive schema change is:

| Item | Required value |
|---|---|
| New record type | `EncryptedBrokerProfile` |
| New application field | `profilePayload` |
| Field type | **Encrypted Bytes**, not ordinary Bytes |
| Application-field indexes | none; encrypted fields cannot be indexed |
| Record storage | existing private `EncryptedBrokerProfiles` zone |

The codec already writes `Data` to `CKRecord.encryptedValues["profilePayload"]`.
Create the type and field in Development, inspect the resulting schema, and
review the deployment diff before promoting it. Apple's
[encrypted-field instructions](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)
require the encrypted field type and prohibit converting an existing ordinary
field into an encrypted field. No public-database records, real test profile,
zone reset, or deletion is needed to prepare the schema.

After explicit user authorization, Development now contains the record type
with exactly one application field, `profilePayload ENCRYPTED BYTES`, and no
indexes. All ten `CloudKitProfileRecordCodecTests` passed locally. The
Production deployment preview confirms the new type and field, while leaving
the existing `Users` type unchanged. Deployment makes the type and field a
permanent part of the Production schema; it does not copy Development records.

CloudKit Console gives new types default public-database grants: `_world`
Read, `_icloud` Create, and `_creator` Write. These roles govern the public
database and do not expose the app's private records. With separate explicit
user authorization, all three grants were removed from the new type. The
existing `Users` type and its grants were preserved. The final deployment
diff contained only the new type's six standard metadata fields and
`profilePayload ENCRYPTED BYTES`, with no grants or indexes.

The user explicitly authorized Production deployment, and CloudKit Console
confirmed **Changes Deployed — The schema is deployed to Production** on
2026-10-03. This supersedes the earlier pending schema-creation/promotion
status; it does not establish two-device acceptance. The UI automation
connection to the installed app failed, so the user was asked to press
**Retry iCloud Sync** for the post-deployment verification. At this point,
successful profile upload and another device's fetch remain unverified.

App Store distribution does not deploy the CloudKit schema.
See Apple's [schema deployment instructions](https://developer.apple.com/documentation/CloudKit/deploying-an-icloud-container-s-schema).
Establish and validate it in Development before an authorized release operator
reviews and deploys it to Production. Then retry
sync in this same installed build and confirm both upload and another device's
fetch. Do not delete the local replica or reset the CloudKit zone to investigate
this error.

Run `codesign` inspection outside the restricted filesystem sandbox when it
reports an invalid entitlement blob: this app produced that misleading warning
inside the sandbox but passed verification with all expected entitlements
outside it. No broker endpoints, profile contents, credentials, or record UUIDs
are retained in this acceptance note.

## Build families

| Configuration | Profile adapter | CloudKit container | CloudKit environment | Push environment |
|---|---|---|---|---|
| `Debug` | `LocalOnlyProfileSync` | none | none | none |
| `Release` | `LocalOnlyProfileSync` | none | none | none |
| `Official Development` | `CloudKitProfileSync` | intended `iCloud.eu.jinx.jollymqtt` | Development | development |
| `Official Release` | `CloudKitProfileSync` | intended `iCloud.eu.jinx.jollymqtt` | Production | production |

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

No provisioning profile is checked into the repository. The TestFlight
release script records the same default Apple team identifier used by
SmartyBox and permits an explicit override; that identifier is not evidence of
container ownership, profile availability, or access.

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
absence of credential/history/workspace keys. Development schema creation and
inspection in CloudKit Console passed on 2026-10-03, followed by the explicitly
authorized Production deployment recorded above. Signed Development writes
and the full two-device checks below remain pending.

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

1. Confirm the Apple team owns `iCloud.eu.jinx.jollymqtt`; create it if
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

The initial schema was deployed on 2026-10-03 to repair the distributed app,
with explicit user authorization. That deployment does not complete the full
release acceptance checklist below. For later schema changes, establish these
checks before promotion:

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
