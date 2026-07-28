---
title: "Bounded Ingress and Overload Memory Gate"
description: "Decision record for fixed-capacity MQTT ingress, overload teardown, conservative coverage gaps, and the mqtt-nio total-process memory compatibility budget."
area: "transport"
doc_type: "architecture-decision-record"
status: "accepted"
last_reviewed: "2026-07-28"
tags:
  - "mqtt"
  - "mqtt-nio"
  - "overload"
  - "memory"
  - "benchmark"
---

# Bounded Ingress and Overload Memory Gate

## Context

mqtt-nio `3.0.0-alpha.2` builds each `MQTTSubscription` on an unbounded
`AsyncThrowingStream`. A bounded application queue cannot retroactively bound
messages already buffered by the dependency. JollysMQTT therefore needs both a
deterministic local-overload contract and a measured total-process
compatibility gate against the actual pinned dependency.

This decision is intentionally narrower than the future `BrokerFeed`. It
establishes only the transport-to-consumer handoff, teardown semantics, and
Milestone 0 evidence.

## Decision

- `MQTTBoundedIngressAdapter` owns a fixed-size ring. Capacity means all
  accepted but not yet processed publications, including the one currently in
  the processing closure.
- The source consumer does only the transport conversion already performed by
  `MQTTMessageSequence` and an O(1) offer into the ring. It never spawns one
  task per publication.
- The first offer beyond capacity is the one rejected publication. The adapter
  atomically enters terminal `localOverload`, stops reading the source, records
  one rejection, notifies the overload observer, and closes upstream exactly
  once.
- Accepted work drains until the configured deadline. Reaching the deadline
  actively cancels the cooperative processing child and counts every remaining
  queued or in-process accepted publication as discarded.
- An overload coverage gap is always open-ended. Its minimum count is the
  locally known rejected plus discarded count; mqtt-nio, Network.framework,
  the kernel, or the broker may have held additional publications when the
  connection closed.
- An overload report never allows automatic reconnect. A later feed may start
  a fresh adapter only after explicit user Retry.
- `overloadDrainDuration` measures first rejection to local drain completion.
  The release probe separately timestamps first rejection before close and
  measures through completion of the entire mqtt-nio connection task.

Processing closures must cooperate with Swift task cancellation. Swift cannot
forcibly stop arbitrary suspended user work; package-owned consumers must use
cancellation-aware operations.

## Compatibility budgets

The Milestone 0 release probe is an executable regression gate with these
provisional limits:

| Metric | Budget |
|--------|--------|
| Peak total-process resident memory | 128 MiB absolute |
| Peak resident-memory increase over pre-connection baseline | 64 MiB |
| First rejection to full mqtt-nio connection-task completion | 500 ms |

The probe fails its process when any budget is exceeded, when ingress does not
reach its exact configured high-water mark, when termination is not
`localOverload`, or when the report permits automatic reconnect.

These are compatibility budgets for the documented baseline Mac and workload,
not hardware-independent product-performance promises. Ticket Q6 will replace
or extend them after full topic indexing, history, presentation, and target
device measurements exist.

## Measured evidence

Raw results are checked in at
`AI/BENCHMARKS/2026-07-28-overload-mac16-7.json`.

Environment:

- Mac model `Mac16,7`, arm64
- macOS 27.0 build `26A5388g`
- Xcode 27.0 build `27A5228h`
- Apple Swift 6.4 (`swiftlang-6.4.0.27.1`)
- release configuration
- mqtt-nio `3.0.0-alpha.2`, revision
  `c980b0f86a3d211f04391a0f5ea627b0960751d3`
- isolated local Mosquitto

Each of three runs attempted 250,000 QoS 0 publications with deterministic
256-byte payloads from a separate raw-MQTT publisher process. The measured
release process used capacity 4,096, a 5 ms consumer delay, a 100 ms drain
deadline, 1 ms RSS sampling, and a 500 ms post-teardown settling interval.
The measured process did not construct or retain the flood payload.

Observed ranges:

| Metric | Three-run range |
|--------|-----------------|
| Publisher rate | 507,456–521,925 messages/s |
| Queue high-water | exactly 4,096 |
| Peak total-process RSS | 16,138,240–16,269,312 bytes |
| Peak RSS increase | 8,617,984–8,716,288 bytes |
| Local overload drain | 100.480–101.923 ms |
| Rejection to full connection completion | 100.590–102.029 ms |
| Settled RSS after 500 ms | 16,138,240–16,269,312 bytes |

The settled sample remains at the allocator's post-overload plateau rather than
returning to the initial process baseline, but the plateau and peak are stable
across the repeated runs and far inside both memory budgets.

## Upstream decision

The pinned mqtt-nio upstream edge stayed inside the proposed absolute, delta,
and teardown budgets in all three release runs. The dependency blocker is not
triggered, so this ticket requires neither an upstream patch nor an unverified
upgrade. The exact alpha.2 pin and compatibility gate remain in place. Any
future budget failure reopens the choice among an upstream fix, a narrow
maintained patch, or a verified newer release.

## Consequences

- Local queue memory has a strict payload-count bound and FIFO operations are
  O(1).
- Overload is visible and durable consumers can record an honest conservative
  gap rather than silent loss.
- Full connection teardown is measured separately from local drain work.
- The release probe adds a non-shipping executable and Python raw-MQTT fixture
  to the package. Mosquitto and Python are benchmark prerequisites only.
- Expected transport errors such as broken pipe or network-down may be logged
  by mqtt-nio while the deliberate overload close unwinds.
