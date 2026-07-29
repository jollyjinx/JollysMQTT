---
title: "Numeric Chart Dashboard Implementation"
description: "Persistent multi-card identity, bounded aggregate work, clear-boundary semantics, and adaptive dashboard layout."
area: "charting"
doc_type: "implementation-notes"
status: "active"
last_reviewed: "2026-07-29"
tags:
  - "charts"
  - "history"
  - "performance"
  - "persistence"
  - "swiftui"
---

# Numeric Chart Dashboard Implementation

The dashboard persists an ordered array of cards. Every card has an independent
UUID even when several cards show the same topic and JSON path. Reordering
changes only array order; it does not recreate chart stores or use collection
indices as SwiftUI identity.

Workspace document version 1 remains readable. New records encode
`numericChartDashboard`. A ticket-18 record containing the former
`numericChart` field migrates to one card whose deterministic ID is the
workspace UUID. Connected restoration keeps only cards for the connected
broker, preserves their relative order, and applies the global card limit.

## Bounded aggregate work

The default dashboard admits at most 12 cards and at most three concurrent
history loads. Each dashboard card uses this policy:

- 512 requested history messages,
- 1 MiB aggregate payload bytes per query,
- 64 KiB per payload,
- 512 retained raw samples,
- 512 samples before pixel-width downsampling.

The fixed dashboard ceilings are therefore 12 MiB of requested history payload,
6,144 examined history messages, 6,144 retained raw samples, and 6,144
pre-resolution display samples. The store defensively examines only the newest
requested suffix when an alternate history reader over-returns rows. A shared
cancellation-aware permit gate bounds concurrent query and extraction work.
Removing a queued card cancels its waiter; a cancellation racing a permit grant
returns the granted permit before failing.

The regression fixture uses all 12 cards and makes every fake history query
over-return 4,096 rows. It verifies the examined-message ceiling, newest
durable-order suffix, request-byte ceiling, raw/display ceilings, and bounded
query concurrency.

## Pause and clear semantics

Pause is presentation-local. It freezes one card while broker ingestion,
durable history writes, and every other card continue. Resume admits the newest
bounded pending live point without replaying an unbounded event backlog.

Clear Displayed Samples never calls a history mutation API. Its persisted
marker contains the greatest displayed SQLite durable order plus the bounded
set of displayed sample identities. Durable order, rather than timestamps,
defines the clear boundary. This prevents old samples from reappearing after
restoration while allowing genuinely newer samples whose device timestamp
moved backward. Exact identities cover live samples that had not received a
durable order when Clear was invoked. SQLite durable order is monotonic across
history-source changes, so the boundary also survives reconnect and current
source transitions.

## Adaptive presentation

Wide layouts pack stable-ID cards into a semantic SwiftUI `Grid`. The grid uses
one, two, or three columns according to available width and honors automatic,
full, half, and third spans. Compact Charts uses a vertical card list so every
control remains reachable without hover or secondary click. Each card exposes
Pause/Resume and Remove in its header. Its secondary controls are collapsed in
a native Settings disclosure by default; disclosure expansion is transient UI
state and is not persisted. Those settings cover time range, auto-scroll,
automatic/fixed Y range, multiplier, line/point/step style, system-safe color,
adaptive span, clear, and move earlier/later.
