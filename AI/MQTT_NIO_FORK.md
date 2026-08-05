---
title: "mqtt-nio Fork Dependency"
description: "Pinned jollyjinx/mqtt-nio revision, bug-fix rationale, upstream base, and verification requirements."
area: "dependencies"
doc_type: "dependency-note"
status: "active"
last_reviewed: "2026-08-05"
tags:
  - "swift"
  - "mqtt"
  - "mqtt-nio"
  - "dependency"
---

# mqtt-nio Fork Dependency

JollysMQTT depends on [`jollyjinx/mqtt-nio`](https://github.com/jollyjinx/mqtt-nio)
at immutable revision
`e670a69ee3122bd11ef04f668757ffc01c263468`.

## Reason for the fork

The pinned revision adds one commit, **Prevent MQTT task timeout double
completion**, on top of upstream `3.0.0-alpha.2` revision
`c980b0f86a3d211f04391a0f5ea627b0960751d3`.

Upstream's timed MQTT task failed its promise directly when its timeout fired,
but left the task registered in the channel state machine. Closing the
connection could then attempt to fail the same promise a second time. The fork
routes timeout through the channel handler's cancellation path so the timed-out
task is removed before connection teardown. It includes a regression test for
a QoS 1 publish timing out before the connection closes.

The public mqtt-nio API is unchanged. JollysMQTT's transport adapter therefore
requires no source changes beyond selecting the fork revision.

## Pin and upgrade policy

The fork currently has no release tag containing the fix, so the package
manifest pins the full commit revision rather than following `main`. Keep the
reported base version as `3.0.0-alpha.2`, and report the fork revision wherever
dependency identity is captured in benchmark output.

Before moving this pin, inspect the candidate changes, build all package
targets, run the full package test suite, run the serialized Mosquitto
transport integration tests, and repeat the overload memory probe when the
subscription buffering implementation changes. Prefer returning to the
upstream repository after an upstream release contains this fix and passes
those checks.
