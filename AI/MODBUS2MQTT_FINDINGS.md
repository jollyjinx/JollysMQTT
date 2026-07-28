---
title: "Reusable modbus2mqtt Findings"
description: "Patterns, mqtt-nio v3 details, UI references, and non-reusable choices discovered while reviewing the existing modbus2mqtt project for JollysMQTT."
area: "architecture"
doc_type: "research"
status: "active"
last_reviewed: "2026-07-28"
tags:
  - "swift"
  - "mqtt"
  - "mqtt-nio"
  - "structured-concurrency"
  - "reuse"
---

# Reusable modbus2mqtt Findings

## Review scope

Reviewed `/Users/jolly/GitHub/modbus2mqtt`, including:

- repository and `AI/` guidance,
- package manifest and resolved dependencies,
- MQTT connection/subscription migration,
- multi-device resource ownership,
- serving-session supervision tests,
- publication policy and deterministic tests,
- MQTT routing and validation,
- the checked-in MQTT Explorer screenshot, and
- the resolved mqtt-nio `3.0.0-alpha.2` source and DocC.

The modbus2mqtt worktree contains an uncommitted mqtt-nio v2-to-v3 migration.
Treat it as a valuable implementation reference, not a package dependency or a
finished API to copy verbatim.

## Directly reusable patterns

### 1. Structured mqtt-nio lifetime

The migration replaces a retained v2 `MQTTClient` and disconnect callback with:

```text
MQTTConnection.withConnection
  → connection.subscribe
    → throwing task group
      → subscription consumer
      → publisher/poller workers
```

When the subscription sequence throws after broker disconnect, the throwing
task group cancels its sibling workers. Scope unwinding unsubscribes and closes
the connection before the executable's outer restart loop retries.

JollysMQTT should use the same ownership principle. Its workers differ:

- subscription consumer,
- publish-command consumer,
- topic-index ingestion,
- history batching, and
- connection/session monitoring.

The SwiftUI store should receive connection-state actions; it must not own the
raw mqtt-nio connection.

### 2. Share resources at their natural key

modbus2mqtt uses:

- one MQTT connection per process,
- one Modbus actor per physical `(host, port)`, and
- independent logical-device state above those shared resources.

JollysMQTT's equivalent is:

- one `BrokerFeed` per effective broker connection descriptor,
- one shared topic index and history writer per feed, and
- independent window presentation state.

A `BrokerFeedRegistry` actor should issue reference-counted leases. Opening the
same profile twice must not create two wildcard subscriptions or duplicate
history writes. Releasing the last lease cancels the feed.

### 3. Failure scope follows resource scope

modbus2mqtt distinguishes logical-device, physical-endpoint, and shared-MQTT
failure. JollysMQTT should similarly distinguish:

- payload decode failure: affects one message/presentation,
- history write failure: degrades history while live display can continue,
- subscription or connection failure: affects all windows attached to a feed,
- profile/iCloud failure: affects saved configuration, not an already running
  immutable feed snapshot,
- workspace-state failure: affects one window.

This produces clearer UI errors and avoids reconnecting a broker because one
JSON payload was malformed.

### 4. Advance state only after success

`MQTTPublicationGate` separates `shouldPublish` from
`recordSuccessfulPublication`, so a failed network publish does not pretend the
value was sent.

JollysMQTT should apply the same rule:

- add an outgoing history entry only after mqtt-nio reports publish success,
- keep a pending publish state while QoS acknowledgement is outstanding,
- do not clear or replace a publish draft on failure,
- mark a retained deletion complete only after successful publish.

### 5. Inject time and streams in tests

modbus2mqtt tests publication timing using caller-supplied dates rather than
sleeping. Its serving-session tests use controlled `AsyncStream` values to
prove that a disconnect error cancels sibling workers and escapes the session.

JollysMQTT should use:

- injected `Clock` and jitter source,
- controlled transport `AsyncThrowingStream`,
- no wall-clock sleeps in reducer/reconnect tests,
- events proving every long-lived worker stops after the last feed lease,
- separate Mosquitto integration tests for the real transport.

### 6. Validate before entering the runtime

modbus2mqtt normalizes configuration and rejects duplicate routes, wildcard
publication topics, empty values, and conflicting shared-resource settings at
startup.

JollysMQTT should validate a `BrokerProfile` before saving or connecting:

- nonempty normalized hostname,
- valid port,
- valid publish topics and subscription filters,
- MQTT v3 username requirement when a password exists,
- at least one enabled subscription,
- TLS/client-ID/session combinations,
- duplicate/conflicting explicit client IDs among active feeds.

Validation belongs in transport-neutral domain code and is covered by
table-driven Swift Testing tests.

### 7. Contextual logging

modbus2mqtt attaches endpoint, unit, and topic context to operational messages.
mqtt-nio v3 accepts a `swift-log` logger directly and also supports task-local
logging.

JollysMQTT should pass one logger per feed with non-secret metadata such as:

- profile UUID,
- redacted/display broker name,
- connection attempt number,
- workspace attachment count.

Do not copy payload, password, private-key, or full username logging.

### 8. Keep third-party types at the dependency edge

The modbus2mqtt migration moves the mqtt-nio product dependency to the target
that imports it. JollysMQTT should go further:

- only `JollysMQTTTransport` imports MQTTNIO/NIO,
- convert `MQTTPublishInfo` and `ByteBuffer` to package domain values/`Data`
  immediately,
- keep profile, history, reducer, and SwiftUI targets independent of mqtt-nio.

## mqtt-nio 3.0.0-alpha.2 facts

The local checkout resolves:

```text
version: 3.0.0-alpha.2
revision: c980b0f86a3d211f04391a0f5ea627b0960751d3
Swift tools: 6.2.3
minimums: iOS 18, macOS 15
```

Relevant API behavior:

- `MQTTConnection` is an actor running on its channel event-loop executor.
- `withConnection` automatically sends CONNECT and DISCONNECT.
- Identifier-based `withConnection` uses a clean session.
- `MQTTSession` is required for MQTT session continuity and rejects concurrent
  connections using the same instance with
  `MQTTError.alreadyConnectedWithSession`.
- Connection subscriptions and session subscriptions are scoped closures over
  `MQTTSubscription`, an `AsyncSequence`.
- Incoming `MQTTPublishInfo` includes QoS, retain, duplicate flag, exact topic,
  properties, and `ByteBuffer` payload.
- `close()` is public and nonisolated.
- The default event loop is a POSIX `MultiThreadedEventLoopGroup`.
- mqtt-nio documentation says iOS should always use NIO Transport Services.
- Apple TLS is configured with `TSTLSConfiguration`; full certificate
  verification is available and is the required default.

JollysMQTT implications:

1. Pin alpha.2 exactly, not `from:`.
2. Pass `NIOTSEventLoopGroup.singleton.any()` explicitly on Apple platforms.
3. Map clean-session mode to the appropriate mqtt-nio overload.
4. Keep only one active connection per `MQTTSession`.
5. Explicitly close on feed cancellation.
6. Do not promise persistence of mqtt-nio's in-memory inflight/session state
   across app termination; its public session object is not a Codable store.

## MQTT Explorer UI findings

`modbus2mqtt/Images/mqtt-explorer.png` provides the concrete reference intended
by the original request.

Useful behaviors visible in the image:

- branch rows show descendant topic and message counts,
- leaf rows show a compact latest JSON value inline,
- multiple selected numeric values remain visible as simultaneous graph cards,
- graph cards have Pause, Settings, and Remove actions,
- the hierarchy remains visible while graphs are displayed.

JollysMQTT should implement this as a native adaptive workspace:

- outline and selected-topic inspector in the upper/primary region,
- a resizable pinned-graph dashboard in a lower region on Mac/iPad,
- adaptive card grid on wide windows,
- focused chart/list presentation on iPhone,
- persisted graph order, size, pause state, series path, and axis settings.

This improves the earlier plan, which treated graphing mostly as one detail
section and did not specify the multi-card dashboard.

The later full-source review in
[MQTT_EXPLORER_FINDINGS.md](MQTT_EXPLORER_FINDINGS.md) expands these screenshot
observations into behavioral requirements for search, freeze, history/diff,
publishing, charts, compact navigation, and connection profiles.

## Choices not to copy

### Password in a sendable settings value

modbus2mqtt's CLI-only `MQTTServer` contains username and password because
process options are ephemeral. JollysMQTT must keep secrets in Keychain and
pass them to the transport only for connection setup.

### Fixed-delay process restart

A headless bridge can log, sleep, and restart indefinitely. A GUI client needs:

- typed, visible connection state,
- exponential backoff with jitter,
- Retry and Cancel controls,
- network-path awareness,
- scene/background policy,
- no reconnect after an explicit user disconnect.

### Default mqtt-nio event loop

The modbus2mqtt executable targets macOS/Linux and currently relies on the
default event loop for non-TLS connection calls. JollysMQTT targets iOS and must
explicitly select NIO Transport Services for all Apple connection paths.

### Global CLI logging

JLog's process-wide level and signal controls make sense for a service.
JollysMQTT should use structured `swift-log` metadata with an Apple logging
backend and app settings, not Unix signal handlers or a global payload-verbose
mode.

### Direct reuse of the bridge package

The bridge's domain is Modbus polling and request routing. Linking it would add
unrelated dependencies and expose credentials/models inappropriate for an app.
Reuse the design lessons and tests, not its production target.

## Follow-up implementation probes

Milestone 0 should answer:

1. Does alpha.2 build unchanged in the thin Xcode app for device and simulator?
2. Does `NIOTSEventLoopGroup.singleton.any()` work for TCP and TLS on both iOS
   and macOS?
3. Does canceling the feed task promptly terminate a subscription and close the
   connection, or must the cancellation handler call `connection.close()`?
4. Which error escapes when a broker drops an active connection, and how should
   it map to the UI?
5. Can one session-level subscription span reconnects without losing or
   duplicating messages at QoS 1/2?
6. What behavior is honest to promise for clean-session-off across app
   termination?
7. Does a reference-counted shared feed remain memory-stable with two or more
   window consumers at the performance target?
