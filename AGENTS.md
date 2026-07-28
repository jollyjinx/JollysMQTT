---
title: "JollysMQTT Agent Guide"
description: "Repository map, architectural boundaries, validation commands, and safety rules for the JollysMQTT Apple-platform MQTT client."
area: "repo"
doc_type: "agent-guidance"
status: "active"
last_reviewed: "2026-07-28"
tags:
  - "documentation"
  - "agents"
  - "swift"
  - "swiftui"
  - "mqtt"
---

# JollysMQTT Agent Guide

JollysMQTT is a planned SwiftUI MQTT explorer for iOS, iPadOS, and macOS. The
shipping Xcode target is deliberately thin. MQTT behavior, persistence, window
workspace state, and reusable SwiftUI live in a local Swift package.

The repository is currently in the planning phase. Read
`AI/IMPLEMENTATION_PLAN.md`, `AI/MODBUS2MQTT_FINDINGS.md`, and
`AI/MQTT_EXPLORER_FINDINGS.md` before scaffolding or changing architecture.

## Intended repository boundaries

| Path | Responsibility |
|------|----------------|
| `JollysMQTT.xcodeproj/` | Apple app targets, signing, entitlements, local package reference |
| `JollysMQTTApp/` | Thin `@main` scene declaration, assets, plists, app icon |
| `JollysMQTTPackage/Sources/JollysMQTTCore/` | Domain values, feature state/reducers, topic trie, payload interpretation |
| `JollysMQTTPackage/Sources/JollysMQTTTransport/` | The only target that imports mqtt-nio/NIO |
| `JollysMQTTPackage/Sources/JollysMQTTStorage/` | Profiles, iCloud merge, Keychain credentials, local history, workspace records |
| `JollysMQTTPackage/Sources/CSQLite/` | Module map for the system SQLite library, if the history benchmark confirms the planned SQLite backend |
| `JollysMQTTPackage/Sources/JollysMQTT/` | Reusable SwiftUI root, window workspace UI, platform adapters, Charts |
| `JollysMQTTPackage/Tests/` | Unit, reducer, persistence, transport, and integration tests |
| `AI/` | Architecture, decisions, implementation plans, and durable findings |

Do not move MQTT protocol behavior or persistence into the app target. The app
target should compose package scenes and own only capabilities that must be
declared by an application bundle.

## Core architectural rules

- Use Swift 6.2.3 or newer with complete concurrency checking.
- Keep reusable domain values immutable and `Sendable`.
- Keep user-interface stores `@MainActor` and `@Observable`.
- Isolate each live broker feed, topic trie, and history writer behind actors.
- Pool a live feed by its effective connection configuration. Multiple windows
  for the same profile have independent UI state but normally share one MQTT
  connection, topic index, and history writer.
- Use feature-scoped MVI for workflows; do not create a single app-wide
  reducer containing every topic update.
- Views render state and send intents. They do not call mqtt-nio, Keychain,
  iCloud, or the history database directly.
- `JollysMQTTTransport` is the only target allowed to import `MQTTNIO` or expose
  NIO types internally. Its public package-facing API uses JollysMQTT domain
  values and `AsyncSequence`.
- Every long-lived task has a clear owner and cancellation path. Closing a
  workspace releases its broker-feed lease; the last lease cancels
  subscription, reconnect, batching, and persistence tasks for that feed.
- Use stable topic identity based on broker ID plus exact full topic. Never use
  collection indices or regenerated UUIDs for outline identity.
- Coalesce high-frequency transport events before updating SwiftUI. Do not
  invalidate the whole topic outline for every MQTT message.

## Persistence and privacy

- Synchronize broker profile metadata through iCloud key-value storage.
- Store passwords and private keys in Keychain, never in profile JSON, iCloud
  KVS, logs, fixtures, or documentation.
- Credentials are device-local in the first release. A device receiving a
  synced profile without credentials prompts on connect.
- Window/workspace state and message history are local to a device. They are
  not iCloud-synchronized.
- Preserve deleted-profile tombstones long enough to prevent an older device
  from resurrecting deleted profiles.
- Treat broker addresses, usernames, topic names, payloads, and history as
  private data.
- Do not log payload bodies or credentials by default.

## mqtt-nio dependency rule

The requested mqtt-nio major version 3 is prerelease as of 2026-07-28.
`modbus2mqtt` has already resolved and begun migrating to
`3.0.0-alpha.2` (revision `c980b0f86a3d211f04391a0f5ea627b0960751d3`).
Pin `3.0.0-alpha.2` exactly during the initial implementation; do not depend on
`main` or use `from:` with a prerelease. Changes to the pin require:

1. reading the upstream release notes,
2. building all package targets,
3. running transport integration tests against Mosquitto, and
4. recording API or behavioral changes in `AI/`.

The v3 API uses structured lifetimes for connections and subscriptions.
Connection ownership must follow that structure instead of retaining an
unscoped MQTT client globally.

On Apple platforms, pass an event loop from
`NIOTSEventLoopGroup.singleton.any()` and use the Transport Services TLS
configuration. Do not inherit mqtt-nio's default POSIX event loop on iOS.

## UI rules

- New macOS windows (`Command-N`) and new iPad scenes start at the server list.
- Connecting transforms the current workspace; it does not implicitly create a
  second window.
- Each workspace has independent selection, expansion, history navigation,
  publish drafts, and graph configuration. Connection/topic/history state can
  come from a shared broker feed.
- Prefer native semantic colors, text styles, controls, and spacing.
- Use separate `View` types for meaningful screen regions with narrow inputs.
- macOS may use an `NSOutlineView` representable where SwiftUI's outline cannot
  meet throughput, expansion-state, or selection requirements. Keep that
  adapter behind a package protocol.
- iOS/iPadOS use a native adaptive SwiftUI hierarchy.
- All package-localized strings resolve from the package resource bundle.
- Treat `Documentation/MQTT-Explorer` as a behavioral reference only. Its
  package metadata and license file conflict; do not copy source, assets, text,
  or styles into JollysMQTT without a separate license review.

## Validation commands

These commands become mandatory after the scaffold exists:

```bash
cd JollysMQTTPackage
swift build
swift test --parallel
```

```bash
xcodebuild -project JollysMQTT.xcodeproj \
  -scheme JollysMQTT \
  -destination 'platform=macOS' \
  -configuration Debug build
```

```bash
xcodebuild -project JollysMQTT.xcodeproj \
  -scheme JollysMQTT \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Transport integration tests may start an isolated Mosquitto broker in a
container. Do not point automated tests at a real broker or use real
credentials.

For documentation-only changes before the scaffold exists, run:

```bash
git diff --check
```
