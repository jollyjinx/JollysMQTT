---
title: "Broker Feed Lease and Reconnect Lifecycle"
description: "Transport-neutral feed state, typed retry policy, structured MQTT ownership, and workspace lease composition."
area: "architecture"
doc_type: "adr"
status: "accepted"
last_reviewed: "2026-07-28"
tags:
  - "mqtt"
  - "broker-feed"
  - "reconnect"
  - "structured-concurrency"
  - "credentials"
  - "workspace"
---

# ADR 0007: Broker Feed Lease and Reconnect Lifecycle

## Context

A connected workspace needs visible, deterministic connection state without
exposing mqtt-nio objects to feature state or SwiftUI. Connection attempts also
own several kinds of long-lived work: a structured mqtt-nio connection,
subscription intake, publish commands, and reconnect timing.

Automatic retry must distinguish transient availability failures from failures
that need user intervention. Scene dormancy, explicit cancellation, and final
workspace release have different semantics and must not accidentally revive
terminal work.

Ticket #8 connects one workspace through one raw feed. Cross-workspace feed
pooling remains ticket #9.

## Decision

`JollysMQTTCore` owns the transport-neutral `BrokerFeed` actor. It publishes a
typed snapshot containing one of these phases:

- idle,
- resolving,
- connecting,
- subscribing,
- connected,
- waiting to reconnect,
- disconnecting,
- suspended,
- failed,
- or overloaded.

The snapshot retains the last typed failure until a connection reaches
`connected`. A waiting snapshot also contains the retry attempt, computed
delay, absolute retry date, and generation token so the UI can show the next
retry without owning a timer or MQTT object.

Only DNS, network, transport, and broker-availability failures retry
automatically. Authentication, trust, invalid configuration, subscription
rejection, local overload, missing credentials, an already-used session, and
protocol failures wait for explicit Retry. Exponential backoff is bounded by
the profile maximum and applies ±20 percent jitter. The clock, sleep operation,
and jitter source are injected so reducer and actor tests never use wall-clock
sleeps.

Every launched feed generation has a token. Cancellation increments the
generation before closing the active attempt, so a stale attempt or sleep
completion cannot publish state or restart the feed. Explicit Cancel suppresses
later scene-activity reconnects. Moving an active scene to the background
suspends the feed while preserving its failure; returning to active resumes
only a resumable feed. Final `release()` is idempotent and terminal for that raw
feed.

`JollysMQTT` adapts a broker profile to `JollysMQTTTransport` in
`MQTTBrokerFeedAttempt`. The attempt:

- resolves a device-local credential only inside the credential repository's
  scoped callback,
- creates a redacted authentication value,
- uses the profile transport, keepalive, subscriptions, and session policy,
- consumes mqtt-nio's unbounded subscription edge through the existing bounded
  ingress adapter,
- consumes a bounded publish-command stream,
- and retains an explicit active connection scope that release can close.

Subscription intake and publish consumption are siblings in one throwing task
group. Failure or cancellation of either cancels the other. Local ingress
overflow becomes the terminal overloaded state. Final release closes the
active connection and terminally finishes attempt-owned publish work even when
another cleanup operation fails.

The transport scopes capture caller-operation results and unwrap them outside
the mqtt-nio establishment and subscription error-mapping catches. This keeps
typed caller failures such as local overload intact instead of accidentally
reclassifying them as broker availability failures.

Generated MQTT 3.1.1 client identifiers use a `jm-` prefix and 20 lowercase
hexadecimal characters, staying within the portable 23-byte limit. Stable IDs
hash one installation UUID with the profile UUID. Random-per-connection IDs are
new for every attempt. A non-clean profile retains one process-local mqtt-nio
session object across reconnect attempts.

`WorkspaceSceneStore` owns a workspace-level feed adapter. It remembers scene
activity before lazy acquisition, forwards one stable snapshot stream, and
owns exactly one observation task. Show Brokers cancels and releases the raw
feed; a later Connect acquires a fresh raw feed. The scene's structured
lifecycle release also releases the feed. A scene store runs its lifecycle and
snapshot observer only once, preventing a restarted SwiftUI task from creating
a competing iterator or reconnecting restored state.

## Consequences

- SwiftUI renders typed connection and failure state and sends Retry or Cancel
  intents without importing MQTTNIO or NIO.
- Credentials do not enter feature state, snapshots, logs, descriptions, or
  reflection.
- The application-side ingress and publish queues are bounded. The separate
  mqtt-nio upstream-buffer memory gate from ADR 0002 remains in force.
- Disconnect, dormancy, final release, and explicit retry have independently
  testable behavior.
- Ticket #9 can replace the raw factory with a pooled lease registry without
  changing workspace UI or the core connection state machine.
