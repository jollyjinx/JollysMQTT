# JollysMQTT

JollysMQTT is a planned native SwiftUI MQTT client for iOS, iPadOS, and macOS.
It is designed around the topic-tree workflow of MQTT Explorer, with live
payload inspection, JSON formatting, publishing, retained-message operations,
history, diffs, and numeric charts.

The app supports multiple independent windows on macOS and iPadOS. On macOS,
the Brokers window stays open: double-click a broker or choose Connect to open
a separate connection window. Command-N shows the broker list again. On iPad,
a new scene begins at the broker list and Connect opens its workspace in that
scene. On macOS, charts open in a separate movable window beside their server.
Each chart has a Settings popover and can move into its own window; closing
that window returns the chart to the dashboard. The chart topics, settings,
and dashboard window position are remembered for future
connections to that broker. Hide Details collapses the detail pane while keeping
the topic outline visible. Window contents are restored across launches. Broker definitions synchronize through encrypted records in the
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

## TestFlight

To archive the committed official iOS and macOS builds and upload both to
TestFlight, run:

```bash
Tools/build-and-upload-testflight.sh
```

Use `--archive-only`, `--preflight`, or `--dry-run` for non-uploading modes.
Pass `--version X.Y.Z` to set the marketing version for both uploads in this
command, or `--version auto` to derive it from the commit date. Without this
option, the script uses the Xcode project's marketing version.
See [AI/TESTFLIGHT_RELEASE.md](AI/TESTFLIGHT_RELEASE.md) for signing,
authentication, versioning, and release-gate details.
