---
title: "SQLite History Storage Strategy"
description: "Decision record for durable history ordering, WAL batching, bounded per-topic and broker-size retention, Apple file policy, and measured target-volume evidence."
area: "storage"
doc_type: "architecture-decision-record"
status: "accepted"
last_reviewed: "2026-08-09"
tags:
  - "sqlite"
  - "history"
  - "retention"
  - "benchmark"
  - "recovery"
---

# SQLite History Storage Strategy

## Context

JollysMQTT needs loss-honest local history at a planned ingest rate of 100,000
messages per minute. Receive timestamps cannot provide a total order because
multiple publications can arrive with the same timestamp. Retention has two
independent limits: 1,000 entries per topic and 250 MiB per broker database.
The database, WAL, and shared-memory sidecars contain private local data and
must receive the same iOS file protection and backup-exclusion policy.

Milestone 0 must prove the storage choice before live history, history queries,
and charts depend on it.

## Decision

- `JollysMQTTStorage` owns a minimal CSQLite layer. No other package target
  imports CSQLite.
- One actor owns each SQLite connection. Its public inputs, records, results,
  diagnostics, and file-policy protocol are immutable `Sendable` values.
- One database represents one broker profile.
- New databases create the current schema version 5 in one transaction and
  record it last in a structurally single-row `schema_version` table. Versions
  1 through 4 remain supported transactional migration inputs.
- `topics` normalizes `(historySourceID, exact topic)`. `messages` refers to a
  topic row and stores receive microseconds plus the payload as an exact BLOB.
- Both tables use `INTEGER PRIMARY KEY AUTOINCREMENT`. Message IDs are the
  durable total order, are queried descending, and are never reused after
  retention deletes. Wall-clock time is presentation metadata only.
- Append validates the complete input batch before opening a transaction.
  Prepared topic-insert, topic-lookup, and message-insert statements are reused
  for the whole batch. Topic IDs are cached only for that batch, bounding the
  cache by accepted batch size even when brokers churn through unique topics.
  Empty MQTT payloads bind as zero-length BLOBs rather than SQL NULL.
- The database uses WAL, `synchronous=NORMAL`, foreign keys, and incremental
  auto-vacuum. The release fixture uses 500-message transactions.
- Normal WAL auto-checkpoint behavior remains enabled. Idle/close and explicit
  maintenance use a truncate checkpoint. Checkpoint results and file sizes are
  observable without exposing a SQLite handle.
- Per-topic retention deletes at most 5,000 globally oldest excess rows in one
  call, using a window rank partitioned by topic, then truncate-checkpoints WAL.
  Callers repeat bounded steps until one step deletes zero rows.
- The separate 250 MiB broker cap deletes at most 5,000 globally oldest
  messages and at most 5,000 now-orphaned normalized topics per call,
  truncates WAL, and incrementally vacuums at most 8,192 pages. Each call spends
  that vacuum budget on an existing freelist before deleting more history and
  remeasures first. If reclaimable pages remain, the call reports progress
  without deleting history so later bounded calls continue vacuuming. If there
  was no existing freelist, it spends the budget after deletion. It reports
  whether the byte target was reached or more message, orphan, or freelist work
  is possible. Callers use a bounded loop and treat non-convergence as an error.
- To keep physical main+WAL+SHM allocation below that hard cap during sustained
  ingestion, maintenance starts at 60% (150 MiB) and converges to 50%
  (125 MiB). A first 90%/85% policy passed post-operation samples but an
  independent sampler observed 345,896,856 bytes while checkpointing duplicated
  live pages between the main file and WAL. The conservative thresholds leave
  room for that measured copy-over transient. The high-water and target are
  configuration-derived rather than hidden constants.
- `SystemHistoryFilePolicy` excludes the database, `-wal`, and `-shm` from
  backup. On iOS it also applies
  `completeUntilFirstUserAuthentication` data protection. Opening a store and
  explicit lifecycle refreshes reapply the policy to transient sidecars.
- V1 keeps the plan's 1,000-entry per-topic and 250 MiB per-broker defaults.
  Payloads over the later ingestion policy's 1 MiB default remain a separate
  feed-level decision; this storage layer preserves every accepted payload
  byte.

## First-release schema baseline

Version `0.1.0` is the first public release candidate. The SQLite schema is
already at internal version 5 because pre-release feature work evolved the
format while retaining migration coverage:

| Version | Added state |
|---------|-------------|
| 1 | Normalized topics, durable message order, receive time, and exact payload bytes. |
| 2 | Connection epoch and ordinal for stable transport ordering. |
| 3 | Explicit history coverage gaps. |
| 4 | Publish operation identity, direction, QoS, and retained metadata. |
| 5 | Payload-storage disposition and original payload byte count. |

The store migrates each version from 1 through 4 to version 5 transactionally.
A parameterized release regression opens representative databases at every
older version, verifies preserved history and current metadata defaults, and
then writes a current coverage gap. These are pre-release compatibility
formats, not claims of previously shipped public schemas.

## Reproducible fixture

`JollysMQTTStorageProbe` defaults to the complete target volume:

- 1,000,000 deterministic 256-byte messages, equivalent to 100,000 per minute
  for 10 minutes;
- 10,000 topics, with the second half of traffic concentrated on 100 hot
  topics so per-topic retention has real work;
- 500 messages per transaction;
- a real bounded producer/consumer queue of 8 batches, or 4,000 messages at
  the configured batch size;
- main database, WAL, and SHM lifecycle sampling plus an independent 1 ms
  filesystem sampler spanning insertion, checkpointing, and all retention;
- passive and truncate checkpoint measurement;
- incremental per-topic and broker-size retention;
- a zero-orphan-topic settled-state gate plus a focused churn regression that
  proves orphan cleanup is incremental and bounded;
- a separate recovery database whose writer process is killed with `SIGKILL`
  after an uncommitted insert, followed by integrity, count, append, and query
  checks.

Environment variables prefixed `JOLLYSMQTT_STORAGE_PROBE_` can reduce message,
topic, payload, batch, queue, retention, or iteration settings for CI. A
reduced run does not replace the committed full-volume release evidence.

The fixture intentionally ingests the ten-minute message count as fast as the
machine permits. This is stricter for write throughput and queue pressure than
sleeping between messages, while proving the exact required durable volume.

## Measured evidence

Raw output is checked in at
`AI/BENCHMARKS/2026-07-28-sqlite-history-mac16-7.json`.

Environment:

- Mac model `Mac16,7`, arm64
- macOS 27.0 build `26A5388g`
- Xcode 27.0 build `27A5228h`
- release configuration
- system SQLite 3.54.0

Observed:

| Metric | Result |
|--------|--------|
| Inserted messages | 1,000,000 |
| Insert duration | 12.0402 s |
| Insert throughput | 83,055 messages/s |
| Required average | 1,666.7 messages/s |
| Transactions | 2,000 × 500 messages |
| Queue high-water | 8 batches / 4,000 messages |
| Producer suspensions on full queue | 1,991 |
| Independent 1 ms samples | 6,944 |
| Independent peak main+WAL+SHM | 239,573,144 bytes |
| Lifecycle-sampled peak main+WAL+SHM | 158,242,296 bytes |
| Peak main database | 130,727,936 bytes |
| Peak WAL | 157,173,912 bytes |
| Periodic size maintenance | 37 cycles / 119 bounded calls / 580,000 messages / 9,900 topics |
| Passive checkpoint | 3,919/3,919 frames, not busy |
| WAL after truncate checkpoint | 0 bytes |
| Per-topic retention | 320,000 deleted, 65 bounded calls |
| Final broker-size check | converged, no additional deletion |
| Final pruning time | 6.7240 s |
| Settled rows | 100,000 |
| Settled topics / orphans | 100 / 0 |
| Settled main+WAL+SHM | 133,840,896 bytes |
| Settled WAL | 0 bytes |
| Interrupted-write recovery | passed |

Per-file peaks in the table are independent observations and need not sum to
the peak combined footprint. The prototype exceeds the required average insert
rate by about 50 times. The independent sampler kept the observed physical peak
22,570,856 bytes below the 250 MiB hard cap and the final maintenance state
remained below its high-water trigger. The SQLite plan is therefore retained.

## Consequences

- Equal timestamps are deterministic and retention cannot cause durable-order
  reuse.
- Actor ownership and prepared transactions keep the SQLite pointer and
  statement lifetimes inside the storage boundary.
- A bounded queue can apply real producer backpressure; benchmark queue depth
  is observed, not inferred.
- DELETE alone does not reduce file size. The byte cap necessarily combines
  deletion, checkpoint, and incremental vacuum.
- The settled database can retain free pages while remaining under its cap;
  later writes reuse them. Maintenance does not pay for a full blocking
  `VACUUM`.
- `synchronous=NORMAL` can lose the newest committed WAL transactions on a
  sudden power failure, but SQLite atomicity and consistency remain intact.
  The forced-process-interruption fixture proves uncommitted rows do not appear
  and the store remains writable.
- macOS relies on sandboxing and volume protection for at-rest encryption.
  iOS data-protection behavior is implemented behind the tested file-policy
  seam and is compiled in the generic iOS build; physical-device verification
  remains part of release security ticket S6.
