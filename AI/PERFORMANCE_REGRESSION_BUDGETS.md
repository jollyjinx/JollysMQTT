---
title: "JollysMQTT Performance Regression Budgets"
description: "Release workload, measurement schema, baseline review policy, overload diagnosis, and manual interaction gates."
area: "performance"
doc_type: "acceptance-plan"
status: "active"
last_reviewed: "2026-07-29"
tags:
  - "performance"
  - "regression"
  - "sqlite"
  - "mqtt"
  - "release"
---

# JollysMQTT Performance Regression Budgets

Ticket `jnxprivate/JollysMQTT#23` establishes a reproducible release
performance gate. The gate is not a synthetic SQLite-only benchmark: it
exercises the bounded MQTT ingress adapter, broker-feed ingestion, topic
snapshots, the outline reducer on the main actor, SQLite history, publish
queueing, search, selection, Freeze view, scroll preparation, chart
downsampling, last-lease release, and post-stop memory sampling.

## Standard fixture

The standard fixture is defined by
`PerformanceWorkloadFixture.standard`:

| Property | Value |
|---|---:|
| Topics | 10,000 exact topic strings |
| Message rate | 100,000 messages/minute |
| Duration | 600 seconds |
| Total messages | 1,000,000 |
| Payload size | 256 bytes |
| Hot distribution | 1,000 topics receive 80% of messages |
| Cold distribution | 9,000 topics receive 20% of messages |
| Payload distribution | 50% scalar, 40% JSON, 10% binary |

The generator is deterministic. Tests prove that its first 45,000 messages
visit all 10,000 topic strings and that every 100-message cycle contains the
exact declared payload mix. The recorded topic-distribution seed
`0x4A4D515454` is reserved for fixture-schema stability and a future reviewed
shuffle. The current arithmetic distribution does not consume the seed;
changing that behavior creates a new fixture and invalidates existing
baselines.

## Recorded result

Every accepted raw result records:

- hardware model, operating system, architecture, release/debug
  configuration, and Xcode version;
- elapsed time, ingested message count and throughput;
- successfully committed history message count and measured SQLite append
  throughput;
- configured history database cap, highest observed post-maintenance SQLite
  footprint, and fully converged footprint;
- ingress, history, and publish queue baseline, high-water mark, and settled
  depth;
- main-actor outline update count and update rate;
- median, p95, and maximum costs for snapshots, outline updates, search,
  selection, Freeze view, scroll preparation, and chart downsampling;
- baseline, peak, and settled resident memory plus post-stop samples;
- memory stabilization and final broker-feed lease/state release.

An accepted result requires exact history parity:
`historyWrittenMessageCount == ingestedMessageCount`. All three queues must
return to baseline, the last lease must release feed-owned state, memory must
stabilize, and the main-actor update rate must not exceed 10 updates/second.
The observed and converged SQLite footprints must remain below the configured
broker cap.

## Regression tolerances

The absolute main-actor gate remains 10 updates/second. Relative baselines use
percentage tolerances:

| Metric group | Allowed regression |
|---|---:|
| Ingest and SQLite throughput | 10% lower |
| Main-actor update rate | 5% higher |
| Snapshot and interaction p95 costs | 20% higher |
| Peak and settled resident-memory deltas | 15% higher |

Every `PerformanceMetric` must occur exactly once in a baseline. A partial
baseline is rejected. Updating a baseline requires a non-empty reviewer,
review reference, review timestamp, a complete result, clean lifecycle
settling, and complete metric coverage. The update advances the baseline
revision while retaining each reviewed percentage and direction.

## Running the probe

From `JollysMQTTPackage`:

```bash
swift run -c release JollysMQTTPerformanceProbe \
  --output ../AI/Performance/YYYY-MM-DD-Hardware-release-run.json \
  --baseline ../AI/Performance/macOS-Hardware-release.json
```

Create or explicitly review a baseline:

```bash
swift run -c release JollysMQTTPerformanceProbe \
  --output ../AI/Performance/YYYY-MM-DD-Hardware-release-run.json \
  --accept-baseline ../AI/Performance/macOS-Hardware-release.json \
  --reviewed-by "reviewer" \
  --review-reference "jnxprivate/JollysMQTT#23"
```

`--quick` runs a small integration fixture for development. `--unpaced`
removes producer pacing and is not acceptance evidence for the declared
100,000 messages/minute workload.

## Overload diagnosis and fix

The acceptance work retained unsuccessful evidence instead of weakening the
fixture or increasing ingress capacity:

1. The first exact run overloaded around six minutes. History retention ran
   full convergence synchronously in the ingestion path.
2. An asynchronous two-batch handoff plus incremental convergence moved the
   overload to about eight and a half minutes. One append-maintenance step
   still inherited the configured 5,000-row and 8,192-page limits.
3. Capping append maintenance at 500 rows and 256 pages moved overload to
   about nine minutes but did not fix the scaling cause.
4. A later full process was terminated by the task/session infrastructure.
   Its tool result was only `aborted`; the process and session disappeared,
   there was no stdout/stderr, no atomic output, and no macOS crash report.
   It is classified as inconclusive, not as an application gate result.
5. The captured run after affected-topic pruning exited 0 and passed every
   hard gate.

The final diagnosis used a database seeded above the default 150 MiB
high-water trigger. Run the repeatable opt-in phase harness with:

```bash
JOLLYSMQTT_PHASE_DIAGNOSTIC=1 \
  swift test --filter \
  PerformanceProbeTests.retentionMaintenanceKeepsIngressLive
```

Measured on `Mac16,7` in a debug test build:

| Phase | Duration |
|---|---:|
| Global per-topic window prune | 87.369 ms |
| Affected-topic scoped window prune | 2.308 ms |
| Diagnostics | 3.120 ms |
| Standalone truncate checkpoint | 157.689 ms |
| 500-row broker maintenance call | 4.969 ms |
| Following incremental-vacuum call | 2.785 ms |
| Maximum end-to-end writer append in paced seam | 8.465 ms |

The global `ROW_NUMBER() OVER (PARTITION BY topic_id)` scan ran over the
entire retained message table on every 128-message append even when no topic
exceeded its limit. At 87.369 ms per batch, its theoretical capacity was
about 1,465 messages/second, below the required 1,667 messages/second, so
ingress backlog was inevitable.

Append-time topic retention now scopes the same window calculation to the
source/topic identities affected by the committed batch. Scope inputs are
deduplicated, empty scope is a no-op, and tests prove that an identically
named topic in another history source remains untouched. Live broker
maintenance is capped at 500 deleted rows and 256 vacuum pages per append.
Once broker size crosses the 60% high-water mark, the writer remembers that
state and continues bounded work until reaching the 50% target. Explicit
`applyRetention()` and shutdown still perform full global convergence.

The feed-to-writer handoff holds one in-flight batch and one pending batch by
default (`2 * historyBatchSize`). Both message count and payload bytes are
bounded and observable. Snapshots include in-flight messages in their
not-yet-durable count. Durable publish completion, coverage-gap recovery, and
shutdown explicitly synchronize with the writer.

## Accepted Mac release result

The accepted result was generated at `2026-07-29T13:21:24Z` on `Mac16,7`
using macOS build `26A5388g`, arm64, Xcode `27A5228h`, and a release build.

| Measurement | Accepted value |
|---|---:|
| Elapsed ingestion time | 599.943531375 s |
| Ingested / history committed | 1,000,000 / 1,000,000 |
| Ingest throughput | 1,666.8235 messages/s |
| SQLite append throughput | 5,798.8281 messages/s |
| Ingress queue high-water / settled | 232 / 0 |
| History queue high-water / settled | 256 / 0 |
| Publish queue high-water / settled | 32 / 0 |
| Main-actor update rate | 8.3191 updates/s |
| Observed SQLite peak / cap | 157,284,168 / 262,144,000 bytes |
| Converged SQLite footprint | 146,699,384 bytes |
| Process resident-memory peak | 109,199,360 bytes |
| Settled resident memory | 94,617,600 bytes |
| Memory stabilized | yes |
| Last feed state released | yes |

The exact raw result is
`AI/Performance/2026-07-29-Mac16,7-release-run.json`. The reviewed
revision-one baseline is
`AI/Performance/macOS-Mac16,7-release.json`.

## Independent SQLite footprint gate

After an exact probe succeeds, run the existing full storage probe. It samples
the physical database, WAL, and shared-memory files every 1 ms, independently
of post-append lifecycle diagnostics:

```bash
swift run -c release JollysMQTTStorageProbe \
  > ../AI/Performance/YYYY-MM-DD-Hardware-storage-probe.json
```

Acceptance requires both the lifecycle-sampled and independent physical
main+WAL+SHM peaks to stay below the 250 MiB broker cap, periodic maintenance
to converge, per-topic and broker-size retention to converge, no orphan
topics after settling, target throughput, bounded queueing, and successful
crash recovery.

The accepted full storage probe exited 0. It inserted 1,000,000 messages at
68,077.39 messages/second. Its 1 ms sampler captured 6,963 samples and observed
a physical main+WAL+SHM peak of 237,270,184 bytes, below the 262,144,000-byte
cap. Periodic, per-topic, and broker-size retention converged; the database
settled at 133,779,456 bytes with 100,000 messages, 100 topics, no orphan
topics, and a zero-byte WAL. The eight-batch queue reached its configured
4,000-message bound and producer suspension was observed. Crash recovery
passed. The exact result is
`AI/Performance/2026-07-29-Mac16,7-storage-probe.json`.

## Manual interaction gates

Automated costs exercise search, selection, Freeze view, scroll preparation,
and chart downsampling, but release acceptance also requires functional
interaction checks on macOS and an iOS/iPadOS simulator:

- search updates promptly while messages continue;
- topic selection remains responsive;
- Freeze view stops the visible value without stopping ingestion;
- outline/list scrolling remains responsive;
- chart navigation and updates remain responsive;
- closing the last workspace releases its feed state.

Physical-device performance remains pending until suitable devices are
available. Simulator checks are functional evidence only, not physical-device
performance evidence. CloudKit multi-device verification is intentionally
outside this ticket and deferred at the user's request.

### iOS simulator functional evidence

The functional pass used an iPhone 17 simulator
(`04D96431-53F8-4CBB-B572-CAFC6ED72566`) running iOS 27.0
(`24A5390f`). Xcode built, installed, and launched
`eu.jinx.JollysMQTT`; the process remained running for the entire pass. The
interaction session was closed after verification.

Every coordinate came from the center of the relevant element in the
immediately preceding hierarchy capture. The exact interaction sequence was:

```text
""                                                        initial capture
t 364 84                                                  Add Broker
t 201 250.3 sender keyboard kbd Ticket 23 Fixture         name
t 201 302.3 sender keyboard kbd fixture.invalid           reserved test host
sender keyboard kbd \u{000A}                              dismiss keyboard
t 201 655.3                                               expand Advanced Settings
t 340.5 759.3                                             disable Clean Session
t 58.3 100                                                Cancel
t 364 84                                                  controlled retry: Add Broker
t 201 250.3 sender keyboard kbd Retry Name                controlled text retry
t 58.3 100                                                Cancel
```

The initial and final hierarchies contained enabled `Edit` and `Add Broker`
controls plus `No Brokers` and `Add a broker profile to get started.` Adding a
broker opened `Broker Profile` with enabled `Cancel` and `Save` controls and
the expected name, host, port, transport, authentication, and device-local
password fields. The host became exactly `fixture.invalid`; no username or
password was entered, and Save/connect was never invoked. Expanding Advanced
Settings changed its disclosure state from collapsed to expanded and exposed
Client ID, Clean Session, Keepalive, and Automatic Reconnect. Clean Session
changed from on to off. Cancel discarded the draft and restored the empty
broker list.

Full-size screenshots showed no overlapping, unreadable, or unexpectedly
cropped controls in the broker list, profile editor, or expanded advanced
settings. One synthetic keyboard command omitted the final character of the
first test name. A single controlled retry delivered `Retry Name` exactly, so
the anomaly was not reproducible and is retained as a transient synthetic
input event rather than an application defect.

The hierarchy and screenshot artifacts use the prefix:

```text
/var/folders/3d/729mktvn7d1bpnbfgndkw14c0000gn/T/ActionArtifacts/default/DeviceInteractionSynthesize/JollysMQTT Ticket 23 Functional Verification
```

Key before/after captures are `-15_38_39_687` (initial broker list),
`-15_38_53_715` (profile editor), `-15_39_48_645` (advanced settings),
`-15_40_01_572` (Clean Session off), and `-15_42_06_925` (final broker
list), each with `-hierarchy.txt` and `-screenshot.png` suffixes.

This first simulator pass is disconnected functional evidence, not a
performance baseline. The connected high-volume pass is recorded below.
Physical-device responsiveness and timing remain pending.

### Connected high-volume simulator evidence

The connected pass used Mosquitto 2.1.2 with an isolated, anonymous,
non-persistent listener bound only to `127.0.0.1:18883`. The simulator used a
disposable `Ticket 23 Local` profile with the `#` subscription and no
credentials. No real or remote broker was contacted.

The retained fixture contained exactly 10,000 deterministic topics:

```text
ticket23/site/%02d/device/%04d/telemetry
```

Each topic held a small JSON object with deterministic `topic` and `value`
numbers. A wildcard subscriber independently counted exactly 10,000 retained
deliveries before the app test:

```bash
mosquitto_sub -h 127.0.0.1 -p 18883 \
  -t 'ticket23/site/#' -C 10000 -W 30 | wc -l
```

Connecting directly to that preloaded retained set caused Mosquitto to replay
it as an uncontrolled burst. The app deliberately disconnected after 6,529
topics/messages and presented `Connection overloaded` and `Messages arrived
faster than this device could process them.` This result is retained as valid
safe-overload evidence, not hidden or reclassified as a pass. An
instantaneous broker replay is not the declared paced 100,000-message/minute
fixture.

After clearing all retained records, the app reconnected to the empty broker.
Forty-eight bounded local publishers then discovered the same 10,000 topics
while the app was connected. The processes completed in 14.44 seconds, an
observed end-to-end average of 692.5 messages/second. The resulting hierarchy
remained `Connected` and showed exactly `10,000 topics, 10,000 messages`
without overload.

The selected topic then received three bounded full-rate windows containing
200,000, 100,000, and 200,000 messages. Each publisher used:

```bash
mosquitto_pub -h 127.0.0.1 -p 18883 -q 0 \
  -t ticket23/site/00/device/0000/telemetry \
  -m '{"value":VALUE,"source":"SOURCE"}' \
  --repeat COUNT --repeat-delay 0.0006
```

The commanded interval is approximately 1,666.7 messages/second. Excluding
the retained first broker counter sample, consecutive
`$SYS/broker/publish/messages/received` samples advanced from 188,991 at
15:59:20 to 205,002 at 15:59:30: 16,011 publishes in ten seconds, or an
observed 1,601.1 messages/second. The app remained connected with no overload
through all 500,000 selected-topic updates. Its final hierarchy showed
`10,000 topics, 510,000 messages`; the exact selected topic showed
`500,001 messages`.

Hierarchy-guided interaction under this workload established:

- search for `0000` expanded to and selected the exact live topic;
- Details resolved non-retained QoS 0 JSON and advanced its timestamp from
  15:59:28 to 15:59:50 during the first full-rate window;
- two frozen captures 21.7 seconds apart retained root/topic counts
  310,000/300,001 and value 84.25 while `Jump to Live (999+)` proved
  ingestion continued;
- Jump to Live cleared the pending count, advanced the root/topic counts to
  510,000/500,001, and presented the newer value 126.75;
- the centered scroll command
  `t 201 630.2 f 201 409.7 0.3` moved the topic scrollbar from 0% to 100% and
  changed visible row positions while the app remained responsive;
- selecting JSON `/value` and Pin to Chart produced a `Pinned Numeric Chart`
  for the exact topic and pointer. The chart exposed value 126.8, range
  16:05:26–16:05:56, and Pause, Settings, and Remove controls.

During this initial connected pass, successive inspections replaced the
entire Details pane with `Inspecting Payload`. The segmented control moved
between y=237.3 and y=395.3, so otherwise correct hierarchy-centered taps
could miss. This was treated as a release blocker rather than accepting the
eventual interactions.

The cause was `PayloadInspectorFeature.selectionChanged`: every new current
message cleared the completed inspection and forced the compact section back
to Details before asynchronous inspection finished. Same-topic updates now
preserve the prior completed inspection, JSON selection/mode, and compact
section when broker topic, connection epoch, and delivery direction match.
The latest request still runs, and the existing request/message identity
guards prevent a cancelled or superseded result from replacing the current
payload. A different connection epoch, topic, or unavailable selection still
clears old content.

Regression coverage proves that stable same-topic content and Chart selection
remain visible while the next inspection is pending, a superseded result
cannot replace either stable or newest content, and reconnecting with a new
connection epoch clears the prior inspection. Focused validation passed:

| Suite | Result |
|---|---:|
| Payload inspector feature | 10/10 |
| Numeric chart feature | 21/21 |
| Topic outline feature | 11/11 |

A focused post-fix simulator run repeated a bounded
`--repeat-delay 0.0006` stream. Three Details captures at 16:15:52, 16:16:09,
and 16:16:34 all retained the full ScrollView and controls while timestamps
advanced and `/value` remained visible at 7.25. `Inspecting Payload` was
absent. The segmented frame stayed exactly `{{20,221.3},{362,31}}`, with
Topics, Details, and Chart centers fixed at x=65, 155.5, and 246,
respectively, all at y=237.3. Chart remained selected across four under-load
captures and a post-stream capture; it was never forced back to Details.
This resolves the observed simulator interaction blocker.

Connected-pass artifacts use this prefix:

```text
/var/folders/3d/729mktvn7d1bpnbfgndkw14c0000gn/T/ActionArtifacts/default/DeviceInteractionSynthesize/JollysMQTT Ticket 23 Connected UI Verification
```

Key capture stems are `-15_51_07_133` (safe retained-burst overload),
`-15_57_21_917` (paced 10,000-topic pass), `-15_59_27_236` and
`-16_00_14_253` (live Details), `-16_03_35_673` and `-16_03_57_350`
(frozen pair), `-16_05_50_730` (Jump catch-up), `-16_06_16_320` (scroll),
and `-16_07_41_806` (numeric chart).

Post-fix artifacts use the same directory with prefix
`JollysMQTT Ticket 23 Inspector Fix Verification`. Key stems are
`-16_15_52_098`, `-16_16_09_051`, and `-16_16_33_935` (stable Details),
`-16_16_50_757` through `-16_17_38_000` (Chart retained under updates), and
`-16_18_05_891` (post-stream Chart). Every stem has a hierarchy text file and
screenshot.

Both simulator sessions were closed. All publishers exited, Mosquitto was
stopped, port 18883 had no listener, no broker/publisher process remained, and
the temporary broker configuration was removed. This remains simulator
functional evidence rather than physical-device timing. Physical-device
responsiveness remains pending until suitable devices are available, and
CloudKit multi-device verification remains deferred at the owner's request.
