---
title: "Profile Replica Convergence Implementation"
description: "Ticket M5 logical revisions, independent registers, durable tombstones, migration, and CloudKit conflict boundaries."
area: "storage"
doc_type: "implementation-note"
status: "implemented"
last_reviewed: "2026-07-28"
tags:
  - "cloudkit"
  - "profiles"
  - "conflict-resolution"
  - "migration"
---

# Profile Replica Convergence Implementation

Ticket M5 adds a pure `ProfileReplica` domain beneath the existing
`ProfileRepositoryProtocol` interface. UI callers continue to read and replace
ordered live profiles. The local repository translates each replacement into
independently versioned replica records and retains deleted records.

## Domain order and merge

- `ProfileLogicalRevision` orders first by an unsigned counter and then by the
  canonical UUID representation of the installation identity. Dates and
  CloudKit metadata do not participate.
- One local replacement operation uses one new revision strictly greater than
  every content, rank, or tombstone counter observed locally. Exhausting
  `UInt64` fails rather than wrapping.
- Profile content and reorder rank are separate last-writer-wins registers.
  A concurrent reorder therefore cannot replace a content edit.
- A tombstone is permanently remove-wins for its UUID, including against a
  malformed later live revision. Recreating a broker requires a new UUID.
  Version 1 never compacts tombstones.
- Equal revisions with unequal values are rejected as corrupt forked state.
  They are not silently resolved according to merge operand order.
- Replica decoding re-enters validation and canonical sorting. Duplicate IDs,
  mismatched profile IDs, invalid profiles, and incomplete live records cannot
  enter the merge implementation through synthesized decoding.

The merge is deterministic, idempotent, commutative, and associative for valid
replicas. The tests exercise equal-counter edits, unrelated edits,
rank/content races, repeated merge, stale resurrection, and the algebraic
laws.

## Migration and identity

Local profile documents are version 2 and encrypted CloudKit envelopes are
version 2. Both readers accept version 1 ranked-profile data and assign
`ProfileLogicalRevision.legacy`: counter zero and the all-zero UUID. This
receiver-independent sentinel ensures two devices decode the same legacy
bytes into identical domain state.

The shipping composition injects the same persisted installation UUID used by
MQTT transport into `LocalProfileRepository`. Sync does not create a second
device identity. The installation UUID remains local metadata; synced records
contain it only as the logical revision tie-breaker.

## CloudKit transport conflicts

`CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave` supplies the
attempted record and `CKError`. For `.serverRecordChanged`, the delegate reads
`CKRecordChangedErrorServerRecordKey`, decodes that server record into the
domain replica, and retains the server `CKRecord` only as the base for a retry.
The installed SDK exposes failed saves as an array, so every failure is
processed in record-ID order; every server conflict becomes a merge input and
the first deterministic non-conflict failure remains visible.

Apple requires the app to resolve `serverRecordChanged` and schedule another
save; `CKSyncEngine` does not treat it like an automatically retained
retryable transport failure. The safe ordering is:

1. fetch or retain every server domain record and its transport base,
2. return those records before calling `sendChanges`,
3. merge and persist them in `LocalFirstProfileRepository`,
4. stage the merged snapshot, which explicitly re-adds each `.saveRecord`, and
5. build the later retry from the retained server `CKRecord`, preserving only
   its current change tag.

Re-adding work in the event callback would be unsafe because automatic sync
could send the still-stale staged snapshot with the current server tag. Change
tags never leave the CloudKit delegate and never decide domain order.

Tombstones are encrypted CloudKit records, not CloudKit record deletions.
Credentials, history, workspace data, endpoints, usernames, ranks, revisions,
and tombstones remain inside the single encrypted payload field; only the
profile UUID appears as the record name.
