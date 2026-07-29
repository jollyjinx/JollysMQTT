---
title: "Encrypted CloudKit Profile Sync Implementation"
description: "Ticket K5 implementation boundaries, privacy invariants, state recovery, and deferred convergence work."
area: "storage"
doc_type: "implementation-note"
status: "implemented"
last_reviewed: "2026-07-29"
tags:
  - "cloudkit"
  - "profiles"
  - "privacy"
  - "swift-concurrency"
---

# Encrypted CloudKit Profile Sync Implementation

Ticket K5 introduces a local-first profile repository and an opt-in CloudKit
adapter without provisioning an iCloud container or changing entitlements.
The shipping composition uses `LocalFirstProfileRepository` with
`LocalOnlyProfileSync` by default. A signed, configured build can instead
construct `CloudKitProfileSync` with an explicit container identifier, custom
zone name, and local opaque-state store.

## Ownership and concurrency

- `LocalFirstProfileRepository` owns the atomic local repository and a
  `ProfileSyncing` adapter.
- Reads come from the local document. Writes commit through the local
  repository before their snapshot is staged for sync.
- Local writes and remote application share one owned FIFO task chain. Local
  mutation generations and sync-attempt identifiers reject stale completions.
- `CloudKitProfileSync` serializes engine operations with a separate owned
  task chain. Cancellation cannot remove a live predecessor from that chain.
- The real `CKSyncEngine` delegate is a dedicated actor. No sync callback
  retains or references the profile repository.

## CloudKit and privacy boundary

`CKSyncEngineProfileDriver` uses `CKContainer(...).privateCloudDatabase`, one
configurable custom zone, one record per profile, and automatic scheduled
synchronization. Record names are exactly lowercase profile UUID strings.

The record codec writes one versioned JSON payload through
`CKRecord.encryptedValues`. No ordinary record value contains a display name,
endpoint, username, subscription, client policy, or reorder rank. Credentials,
message history, and workspace records are absent from the synced domain type.

CloudKit types remain inside `JollysMQTTStorage`. The repository and test
engine boundary exchange only sendable profile snapshots, status values, and
failures.

## Opaque engine-state recovery

`CKSyncEngine.State.Serialization` is property-list encoded only inside the
CloudKit driver. `LocalProfileSyncStateStore` atomically retains primary and
backup byte sequences. Configuration attempts the primary serialization,
falls back to the backup, and promotes a selected backup before the next save
so corrupt primary bytes cannot overwrite the last-known-good backup.

## Deliberately deferred to M5/C5

- logical-revision conflict convergence
- separately versioned reorder registers
- deletion-dominant, non-expiring tombstones
- account-change and encrypted-data-reset user recovery flows
- official container/schema/entitlement provisioning
- production schema promotion and real two-device acceptance

An empty remote exchange is not treated as delete-all. Deletion becomes
authoritative only when M5 adds explicit tombstones.
