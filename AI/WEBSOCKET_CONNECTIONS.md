---
title: "MQTT and WebSocket Broker Connections"
description: "Broker protocol selection, WebSocket request paths, TLS, legacy-profile defaults, and connection/history identity."
area: "transport"
doc_type: "implementation-notes"
status: "implemented"
last_reviewed: "2026-10-01"
tags:
  - "mqtt"
  - "websocket"
  - "profiles"
  - "tls"
---

# MQTT and WebSocket Broker Connections

The broker editor's Connection section exposes Protocol with MQTT (the
default) and WebSocket choices. Use TLS applies independently to either
protocol; WebSocket with TLS uses a verified `wss` connection. The WebSocket
Path field appears only for WebSocket profiles and defaults to `/mqtt`.
Changing protocol preserves the entered port: the user supplies the broker's
WebSocket listener port rather than relying on a broker-specific port guess.

`BrokerConnectionProtocol` is a transport-neutral Core value. `BrokerProfile`
stores it and the WebSocket path, and its decoder defaults missing fields to
MQTT and `/mqtt`. Existing local documents and encrypted CloudKit profile
envelopes remain readable without a storage or CloudKit schema change. Save,
revert, duplication, and profile synchronization preserve the new fields.

WebSocket request targets must start with one `/`, contain only printable ASCII,
and exclude fragments. Query strings and percent-encoded paths are accepted;
spaces, line breaks, header injection, and full URLs are rejected before a
connection begins. Validation applies only to an active WebSocket profile.

`MQTTBrokerEndpoint` carries the protocol and path into `JollysMQTTTransport`.
The adapter selects mqtt-nio's TCP or WebSocket transport and uses the same
Network.framework event loop, system-root TLS verification, MQTT 3.1.1 session,
authentication, and structured connection/subscription lifetimes for both.
The WebSocket frame ceiling accommodates the default 1 MiB inbound payload
boundary plus a maximum MQTT topic and packet headers, avoiding the upstream
16 KiB default. The mqtt-nio resolved revision is unchanged.

Effective connection keys and fixed-client-ID endpoint namespaces include the
protocol and active WebSocket path. Editing these fields requires the existing
explicit reconnect of attached workspaces; saving does not mutate a live feed.
Unused WebSocket paths do not change an MQTT feed's effective connection key.
History source identity includes WebSocket framing and its path while preserving
the exact existing MQTT source hashes.

## Validation

Regression coverage includes decoding pre-setting profiles, serialization and
local-repository relaunch, path validation, editor save/duplication, connection
keys, and history-source separation. The isolated Mosquitto integration fixture
optionally enables plain and TLS WebSocket listeners. Both transmit and receive
a 32,000-byte MQTT payload on `/custom/mqtt` with QoS 1; the TLS case uses a generated
local test CA without changing the user's trust store.
The same suite exercises bounded overload teardown and untrusted-certificate
rejection through WebSocket connections as well as direct MQTT.
The broker fixture waits asynchronously for termination. A macOS 27.2 sample
showed the test helper stranded in Foundation `Process.waitUntilExit()` after
Mosquitto had exited; its cleanup no longer invokes that redundant blocking wait.

The resolved mqtt-nio implementation has a separate pending-upgrade limitation:
its HTTP WebSocket upgrade promise has no response deadline. TCP connection and
MQTT packet timeouts do not cover that phase, and the adapter cannot register
the channel for cancellation until the upgrade completes. A peer that accepts
TCP but never answers the upgrade can therefore stall connection/cancellation.
The existing finite-timeout cancellation guarantee is not established for that
WebSocket phase; fixing it requires an upstream handler timeout or channel hook.

Run the integration suite with:

```bash
cd JollysMQTTPackage
JOLLYSMQTT_MQTT_INTEGRATION=1 swift test --filter MQTTTransportIntegrationTests
```

On 2026-10-01, package Debug and Release builds, macOS and unsigned iOS builds,
and the complete parallel package suite with isolated transport integration
enabled passed. The Release localization audit passed with 456 extracted and
catalogued strings. Localization auditing uses the Release extraction;
the existing Debug extraction additionally includes two uncatalogued test-only
workspace resize labels.
