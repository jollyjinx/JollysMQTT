---
title: "mqtt-nio Fork Dependency"
description: "jollyjinx/mqtt-nio main-branch policy, timeout-fix history, and verification requirements."
area: "dependencies"
doc_type: "dependency-note"
status: "active"
last_reviewed: "2026-08-23"
tags:
  - "swift"
  - "mqtt"
  - "mqtt-nio"
  - "dependency"
---

# mqtt-nio Fork Dependency

JollysMQTT depends on the `main` branch of
[`jollyjinx/mqtt-nio`](https://github.com/jollyjinx/mqtt-nio). The manifest
intentionally tracks that branch while the checked-in `Package.resolved`
records the exact revision used by ordinary builds.

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

The fork's current `main` branch replaces that divergent one-off commit with
the maintained timeout implementation from mqtt-nio change #271. At the time
of this review, `main` resolves to
`0d320511d859c0400b2886951996068fdb12be7a`, two commits after the alpha.2
base. The old custom revision is not an ancestor of this branch and must not
be restored as a pin.

## Pin and upgrade policy

The fork's `main` branch is now the requested dependency line. Keep the branch
requirement in `Package.swift` and the generated revision plus branch name in
`Package.resolved`. Dependency updates move the resolved revision; update the
overload probe's dependency identity in the same change so new benchmark
output remains attributable.

Before updating the resolved `main` revision, inspect the candidate changes,
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
