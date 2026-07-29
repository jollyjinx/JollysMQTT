# JollysMQTT

JollysMQTT is a planned native SwiftUI MQTT client for iOS, iPadOS, and macOS.
It is designed around the topic-tree workflow of MQTT Explorer, with live
payload inspection, JSON formatting, publishing, retained-message operations,
history, diffs, and numeric charts.

The app will support multiple independent windows on macOS and iPadOS. A new
window begins at the broker list; connecting turns that same window into a
broker workspace. Window contents and graph configuration are restored across
launches. Broker definitions synchronize through encrypted records in the
user's private CloudKit database, while credentials remain device-only
Keychain items and message history remains local to each device.

Official App Store and Developer ID builds use the project's production
CloudKit container. The source can be published independently; self-built
variants remain fully usable with local-only profiles unless the builder
configures their own CloudKit container and signing identity.

As in JollysFastVNCSwiftUI, the Xcode application is intended to be a thin shell
over a local Swift package. The package owns the MQTT transport adapter, domain
logic, persistence, and nearly all SwiftUI.

The project is currently in the architecture and implementation-planning phase.
See [AI/IMPLEMENTATION_PLAN.md](AI/IMPLEMENTATION_PLAN.md) for the detailed
plan, [AI/MODBUS2MQTT_FINDINGS.md](AI/MODBUS2MQTT_FINDINGS.md) for reusable
patterns found in the existing bridge,
[AI/MQTT_EXPLORER_FINDINGS.md](AI/MQTT_EXPLORER_FINDINGS.md) for behaviors
derived from the checked-in product reference, and [AGENTS.md](AGENTS.md) for
contributor constraints.
