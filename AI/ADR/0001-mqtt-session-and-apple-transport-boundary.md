---
title: "MQTT Session and Apple Transport Boundary"
description: "Decision record for clean-session defaults, process-local mqtt-nio session ownership, NIOTS TLS, and cancellation behavior."
area: "transport"
doc_type: "architecture-decision-record"
status: "accepted"
last_reviewed: "2026-07-28"
tags:
  - "mqtt"
  - "mqtt-nio"
  - "session"
  - "tls"
  - "concurrency"
---

# MQTT Session and Apple Transport Boundary

## Context

mqtt-nio `3.0.0-alpha.2` exposes connections and subscriptions as scoped
operations. Its `MQTTSession` is a reference object containing inflight and
subscription state, and the dependency permits only one connection at a time
to borrow one session. Apple clients must explicitly use
`NIOTSEventLoopGroup.singleton.any()`; mqtt-nio otherwise defaults to its
POSIX event loop.

JollysMQTT needs MQTT 3.1.1 clean sessions, an opt-in persistent-session path,
prompt cancellation, system-trust TLS, and a transport-neutral public package
boundary.

## Decision

- A clean session is represented by `MQTTSessionPolicy.clean(clientID:)`.
  Each connection receives its client ID directly and mqtt-nio sends
  `cleanSession = true`.
- Persistent MQTT 3.1.1 behavior uses
  `MQTTSessionPolicy.inProcessPersistent`. Its `MQTTInProcessSession` owns one
  mqtt-nio `MQTTSession` entirely inside `JollysMQTTTransport`.
- The session handle is intentionally not `Codable` and is never written to a
  workspace or profile. It can resume broker and inflight state only while the
  current process retains it. Reopening the application creates a new session;
  this decision makes no promise of session restoration across launches.
- The future feed registry owns one process-local session per effective
  persistent connection and must serialize connection borrows. Concurrent
  borrows fail as the typed `.sessionAlreadyInUse` transport failure.
- Every connection uses mqtt-nio's `withConnection` scope and every
  subscription uses its scoped `subscribe` operation. Public endpoints,
  messages, QoS values, failures, session policies, and async sequences expose
  no MQTTNIO or NIO type.
- Apple connections always pass
  `NIOTSEventLoopGroup.singleton.any()`. Production TLS creates
  `TSTLSConfiguration` with full verification and `nil` trust roots, selecting
  the user's system trust store. A test-only adapter initializer can provide a
  generated local root certificate; it is not part of the public API.

## Cancellation behavior

An adapter-owned, mutex-protected cancellation bridge closes a registered
connection when its parent task is cancelled. Subscription setup distinguishes
two phases:

1. While waiting for SUBACK, cancellation closes the channel immediately so
   mqtt-nio's non-cancellation-aware continuation is resumed by channel
   teardown.
2. After SUBACK, cancellation first lets the structured subscription operation
   unsubscribe. The adapter then closes explicitly before propagating
   `CancellationError`.

Closing concurrently with mqtt-nio alpha.2's internal unsubscribe task can
strand that task, so active and starting phases must not be collapsed.

Connection establishment has a dependency limitation: mqtt-nio awaits NIO
`EventLoopFuture.get()`, whose own source warns that cancellation is not
respected. Before mqtt-nio yields a connection there is no public channel for
the adapter to close. The adapter therefore:

- checks cancellation before entering the dependency,
- closes immediately if cancellation was recorded before a connection becomes
  registerable,
- configures finite TCP and MQTT response timeouts, and
- remaps the eventual dependency failure to `CancellationError`.

The deterministic silent-TCP fixture verifies the accepted socket reaches EOF,
so the cancellation test checks teardown rather than merely elapsed time.

## TLS proof and limitation

The automated local suite proves:

- the production policy selects full verification with default system roots,
- a generated test CA and localhost certificate complete a verified
  Network.framework TLS connection through the same mqtt-nio adapter,
- the same certificate without the test root becomes the typed, redacted
  `.tlsTrustFailed` failure, and
- a refused TCP connection on a TLS endpoint remains `.brokerUnavailable`.

The local trusted-root success is proof of NIOTS/TLS wiring, not proof that a
public system root was accepted. A deterministic system-root success fixture
cannot be created without either mutating the user's trust store or contacting
a real external broker. Both are excluded from automated tests. A one-time
manual system-root probe may be run only against an explicitly authorized
broker; it is not part of this ticket's automated evidence.

mqtt-nio alpha.2 also loses Network.framework's underlying trust error and
reports the local untrusted handshake as `ChannelError.connectTimeout`.
The compatibility mapper treats only TLS setup channel-close/connect-timeout
errors as trust failures; DNS and POSIX connection failures are not re-labeled.
Revisit this narrow mapping when mqtt-nio preserves the underlying `NWError`.

The mqtt-nio compatibility integration suite is serialized. Concurrent
connections through alpha.2's shared Apple event-loop path can race an
untrusted TLS teardown with another fixture and resume the dependency's packet
continuation twice. Swift then terminates the test process with a continuation
misuse rather than reporting a test failure. Independent brokers and ports do
not isolate that process-global dependency state. Serialization is restricted
to this integration suite; ordinary transport unit tests remain parallel.
Remove the trait only after an upgraded dependency passes repeated parallel TLS
and non-TLS connection runs.

## Consequences

- Persistent sessions work across reconnects in one run without implying
  cross-launch recovery.
- The feed registry has a clear single-owner invariant for `MQTTSession`.
- App and core modules remain independent of mqtt-nio and NIO.
- Active cancellation is prompt and observable at the broker, while
  pre-connection cancellation remains bounded by the pinned dependency's
  timeout rather than being natively cancellation-aware.
- System trust remains the production default without adding a custom-CA
  product feature.
- The compatibility suite takes slightly longer because alpha.2 integration
  cases execute serially, avoiding a known process-wide teardown race.
