---
title: "Bounded Feed Ingestion and Coalesced Topic Snapshots"
description: "Transport-boundary message identity, actor-owned exact topic indexing, bounded durable-history batches, and newest-wins UI delivery."
area: "architecture"
doc_type: "adr"
status: "accepted"
last_reviewed: "2026-07-29"
tags:
  - "mqtt"
  - "ingestion"
  - "topic-trie"
  - "sqlite"
  - "bounded-memory"
  - "swift-concurrency"
---

# ADR 0009: Bounded Feed Ingestion and Coalesced Topic Snapshots

## Context

ADR 0002 bounds the application-owned handoff from mqtt-nio and defines local
overload teardown. ADR 0008 gives every active profile generation one shared
topic-index and history-writer identity. Those seams need concrete ownership
without sending each publication through a main-actor reducer, awaiting SQLite
at the mqtt-nio subscription boundary, or introducing another unbounded queue.

MQTT topics are exact protocol strings. Leading, trailing, and repeated `/`
characters create meaningful empty levels, and one topic may simultaneously
hold a value and be the parent of other values.

## Decision

The transport subscription iterator is the sole `ByteBuffer` boundary. Before
copying, it checks the configured byte limit. It then performs one owned
`Data` copy and attaches:

- one `ConnectionEpochID` created for the successful connection scope,
- a monotonically increasing ordinal within that epoch, and
- the local receive time.

The connection scope owns one mutex-backed identity allocator shared by every
subscription sequence and iterator created during that scope. Starting a new
or concurrent subscription therefore cannot restart its ordinal at one or
duplicate another message's `(epoch, ordinal)` identity.

The existing fixed-capacity ingress adapter offers that immutable message to
its ring buffer. Database work, topic-tree mutation, snapshot construction, and
main-actor work remain downstream of the bounded handoff.

Each feed generation constructs one `BrokerFeedIngestion` actor and one lazy
`SQLiteBrokerHistoryWriter`. The ingestion actor owns:

- an exact trie keyed independently at each MQTT level,
- latest payload references and exact/subtree counters,
- at most one pending fixed-size history batch,
- one periodic partial-batch flush task, and
- one presentation coalescing task.

Full history batches synchronously backpressure the ingress consumer while the
writer is busy. At most one additional batch can wait behind the batch being
written; continued transport input therefore fills the already bounded ingress
queue and reaches its explicit overload contract instead of growing a second
unbounded array. Partial batches flush on an injected clock and shutdown
forces the final append before the writer checkpoint and release.

The SQLite schema is version 2. It stores nullable connection epoch and ordinal
columns so version-1 rows remain readable while new rows preserve their live
identity. SQLite's integer row ID remains the durable total order.

Topic snapshots contain immutable nodes with stable `(broker ID, exact full
topic)` identity. Snapshot construction preserves every empty level and sorts
only presentation output; dictionary/trie identity is not localized or
position-based. Snapshot materialization uses an iterative postorder walk into
a flat immutable arena; public node values are lightweight handles into that
arena. The live trie is also detached iteratively during shutdown. A
protocol-valid topic containing an extreme number of empty `/` levels therefore
uses bounded call-stack space during snapshot construction, consumption, and
release without imposing a non-protocol topic-depth limit.

The actor emits no more than the configured snapshot rate (10 Hz by default)
through a single-slot `bufferingNewest(1)` stream. The shared registry observes
that stream once and fans each revision out to every lease through another
single-slot channel. A main-actor `TopicOutlineStore` rejects stale revisions.
No task, reducer action, or UI invalidation is created per MQTT publication.

History failure is distinct from live failure. The actor marks subsequent
snapshots unhealthy, counts messages not durably stored, stops retaining
history handoff payloads, and continues bounded live indexing. A minimal
localized workspace warning exposes that degraded state.

Last-lease retirement calls the feed's structured shutdown. Shutdown cancels
the coalescer and timer, stops accepting new messages, and acquires the same
serialized history-flush ownership used by timer and manual flushes. Ownership
is acquired atomically before an asynchronous append begins and is held through
the final batch, SQLite checkpoint, and writer shutdown. Concurrent force-flush
callers re-wait when another caller wins ownership, and concurrent shutdown
callers wait for the first shutdown to complete. Shutdown then removes the full
trie and payload cache, finishes snapshot delivery, and releases the feed.

## Consequences

- Accepted messages have one connection-local identity in live state and
  durable history.
- Slow storage cannot create an unbounded history queue.
- Slow or frozen windows retain only the newest presentation revision.
- Same-profile windows see one shared topic tree and do not duplicate history
  writes.
- The live outline is intentionally minimal in this slice; search, sorting,
  activity styling, freeze behavior, stale-generation presentation, and
  history retry/coverage-gap controls remain in their dependency-ordered
  tickets.
- mqtt-nio's internal subscription buffer remains the upstream limitation
  measured and accepted by ADR 0002; this decision bounds JollysMQTT-owned
  memory after that edge.
