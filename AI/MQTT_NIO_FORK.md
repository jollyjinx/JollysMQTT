---
title: "mqtt-nio Dependency and Fork History"
description: "Upstream 3.0.0-rc.1 adoption, timeout-fix fork history, and verification requirements."
area: "dependencies"
doc_type: "dependency-note"
status: "active"
last_reviewed: "2026-10-16"
tags:
  - "swift"
  - "mqtt"
  - "mqtt-nio"
  - "dependency"
---

# mqtt-nio Dependency and Fork History

JollysMQTT uses upstream
[`swift-server-community/mqtt-nio`](https://github.com/swift-server-community/mqtt-nio)
at exact version `3.0.0-rc.1`, revision
`64c9fb4d7cb9ed40a8f21a195db0e295a9c06265`. Keep the checked-in
`Package.resolved` so ordinary builds reproduce the reviewed dependency graph.

The manifest disables the optional `DistributedTracing` trait with
`traits: []`. JollysMQTT does not use tracing; disabling it preserves the
existing publish behavior without automatic trace-context user properties or
tracing dependencies in the built target graph.

## 2026-10-16 upstream release candidate

The [3.0.0-rc.1 release notes](https://github.com/swift-server-community/mqtt-nio/releases/tag/3.0.0-rc.1)
include the maintained timeout implementation (#271) that previously required
the fork. The release is four commits beyond our former fork resolution:
distributed tracing (#273), tracing documentation (#275), a CI dependency
update (#276), and explicitly non-Sendable subscription iterators (#277).

`MQTTSubscription` remains Sendable, while each iterator belongs to its
consumer. The release retains the unbounded `AsyncThrowingStream` subscription
buffer; ADR 0002's bounded ingress and overload teardown gate still apply.

Validation on macOS 27.2 (`26B5112a`), Xcode 27.2 (`27B5038j`), and Apple
Swift 6.4:

- `swift build` passed for all package targets with no adapter API changes.
- `JOLLYSMQTT_MQTT_INTEGRATION=1 swift test --parallel` passed all 508 tests.
  The eight serialized Mosquitto compatibility tests include plain and TLS
  WebSockets, QoS 0/1/2, sessions, trusted/untrusted TLS, cancellation, and
  bounded-ingress overload.
- Debug macOS and unsigned generic-iOS Xcode builds passed using the same
  dependency resolution. Optional distributed tracing was absent from the
  built target graph, and all transitive dependency versions were preserved.
- The release overload probe passed with 250,000 256-byte publications, a
  4,096-message high-water mark, 15.88 MiB peak RSS, an 8.88 MiB RSS increase,
  and 100.70 ms from rejection to full connection completion. Raw output:
  [2026-10-16-overload-rc1-mac16-7.json](BENCHMARKS/2026-10-16-overload-rc1-mac16-7.json).

## Reason for the fork

The former dependency revision,
`e670a69ee3122bd11ef04f668757ffc01c263468`, added **Prevent MQTT task timeout
double completion** on top of upstream `3.0.0-alpha.2` revision
`c980b0f86a3d211f04391a0f5ea627b0960751d3`.

Upstream's timed MQTT task failed its promise directly when its timeout fired,
but left the task registered in the channel state machine. Closing the
connection could then attempt to fail the same promise a second time. The fork
routes timeout through the channel handler's cancellation path so the timed-out
task is removed before connection teardown. It includes a regression test for
a QoS 1 publish timing out before the connection closes.

The fork's `main` branch replaced that divergent one-off commit with
the maintained timeout implementation from mqtt-nio change #271. At the time
of the 2026-08-23 review, `main` resolved to
`0d320511d859c0400b2886951996068fdb12be7a`, two commits after the alpha.2
base. The old custom revision is not an ancestor of this branch and must not
be restored as a pin.

## Pin and upgrade policy

Keep the exact upstream release requirement in `Package.swift` and its
generated version plus revision in `Package.resolved`. Do not return to the
fork unless a new upstream defect requires a separately reviewed patch.
Update the overload probe's dependency identity with each dependency update
so new benchmark output remains attributable.

Before updating the dependency, inspect the release notes and candidate changes,
build all package targets, run the full package test suite, run the serialized
Mosquitto transport integration tests, and repeat the overload memory probe
when the subscription buffering implementation changes. Record API or
behavioral changes in `AI/`.

## 2026-08-23 adoption evidence

The move from the former custom revision to `main` was validated at resolved
revision `0d320511d859c0400b2886951996068fdb12be7a`:

- The old revision and `main` diverge from the alpha.2 base. The branch contains
  mqtt-nio changes #271 and #272: maintained timeout handling and a Foundation
  linking CI check.
- `swift build` and the complete parallel package test suite passed.
- All seven serialized transport compatibility tests passed against isolated
  local Mosquitto fixtures, including QoS, sessions, NIOTS TLS, cancellation,
  and real bounded-ingress overload.
- Debug macOS and unsigned generic-iOS Xcode builds passed.
- No JollysMQTT adapter API change was required. The branch still constructs
  `MQTTSubscription` with an unbounded `AsyncThrowingStream`, so ADR 0002's
  compatibility gate remains in force.
