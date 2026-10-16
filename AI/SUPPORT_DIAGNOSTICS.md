---
title: "Bounded Support Diagnostics"
description: "Connection and iCloud log ownership, privacy allow-list, retention, archive sharing, and validation."
area: "diagnostics"
doc_type: "implementation-note"
status: "implemented"
last_reviewed: "2026-10-16"
tags:
  - "logging"
  - "privacy"
  - "cloudkit"
  - "support"
---

# Bounded Support Diagnostics

`JollysMQTTStorage/DiagnosticLogStore` owns serialized file writes, rotation,
retention, and coherent export snapshots. The shipping composition injects it
into each `MQTTBrokerFeedAttempt`. An opaque connection UUID identifies the
pooled feed throughout its reconnect attempts. Windows sharing a feed share
its connection log. An application file records profile-sync states and numeric
CloudKit error codes, including per-record failures reported by automatic sync.

Files live in `Application Support/JollysMQTT/diagnostic-logs` inside the app's
container when sandboxed. Each connection and each application run has a
separate stream, rotated into 1 MB segments. All retained diagnostic files
together are capped at **20,000,000 bytes**. The oldest files are removed first,
including segments belonging to live connections; no file handle survives a
write. Files last modified more than ten days ago are removed. Startup scans
apply the same budget to prior launches. Writes await the storage actor, so
logging introduces no unbounded task or event queue. MQTT message reception
does not perform per-message diagnostic writes.

`DiagnosticLogEvent` admits only fixed event names, typed failure categories,
numeric CloudKit codes, counts, and anonymous connection IDs. Raw upstream
logger messages stay disabled. Broker names/addresses, profile IDs, usernames,
client IDs, subscription filters, topics, payloads, credentials, and arbitrary
error descriptions never enter logs. Directory/file permissions are 0700/0600;
logs and exports are excluded from backups and receive iOS data protection.
macOS relies on the sandbox and volume protection for encryption at rest.

**Help → Share Log Files…** opens a preparation/share sheet on macOS. iOS and
iPadOS expose the action in the toolbar's **More** menu. Export copies a
consistent snapshot under the writer actor, then creates a ZIP with Foundation
file coordination away from that actor and the main actor. The ZIP also
contains app/build and OS versions. Native sharing requires the user to select
a destination; it never sends logs automatically. macOS additionally offers
**Save ZIP…**, using user-selected read/write sandbox access. Temporary export
workspaces older than one day are reclaimed on the next export; exported
snapshots are separate from retained diagnostic files.

Logging failures do not fail a broker connection. Archive preparation reports
write/export failures and offers Retry. Tests cover independent streams,
connection failure wiring, redaction, global retention across launches, live
stream eviction/recreation, age pruning, permissions/backup exclusion, ZIP
validation, and unwritable storage.

## Validation on 2026-10-16

- `swift build` and `swift test --parallel` passed. The separate
  `JOLLYSMQTT_MQTT_INTEGRATION=1` run passed all 26 isolated transport tests.
- Debug macOS and unsigned generic iOS Xcode builds passed with the checked-in
  dependency versions. A concurrent initial Xcode resolution attempt failed;
  the builds were then run sequentially using the resolved-file flags.
- The macOS debug broker-list fixture exposed **Help → Share Log Files…**,
  prepared a ZIP, opened the native share choices, and successfully saved it
  through the native Export panel. Python's ZIP reader verified its contents
  and CRCs. No share recipient was selected.
- New Swift files pass strict formatting. The string catalog compiles, and
  all ten support UI strings are present in the combined macOS/iOS compiler
  extraction. The existing macOS-only `audit_localizations.sh` still reports
  six older unextracted catalog keys and the new iOS-only **More** key; it
  cannot validate this cross-platform catalog by itself.
- CloudKit conflict regression tests pass. Live signed Production relaunch
  and two-device convergence remain unverified with this fixed build.
