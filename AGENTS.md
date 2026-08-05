---
title: "JollysMQTT Agent Guide"
description: "Repository map, architectural boundaries, validation commands, and safety rules for the JollysMQTT Apple-platform MQTT client."
area: "repo"
doc_type: "agent-guidance"
status: "active"
last_reviewed: "2026-08-05"
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
| `JollysMQTTPackage/Sources/JollysMQTTStorage/` | Profiles, encrypted CloudKit sync, Keychain credentials, local SQLite history, workspace records |
| `JollysMQTTPackage/Sources/CSQLite/` | Module map for the system SQLite library |
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
- Allow only one active effective configuration for a profile. Saving
  connection-affecting edits never mutates a running feed; applying them
  requires an explicit reconnect of all attached workspaces.
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
- Treat the mqtt-nio subscription sequence as an unbounded upstream edge.
  Consume it into an explicitly bounded ingress queue and disconnect with a
  visible overload error rather than allowing unbounded memory growth.
- The application queue does not bound mqtt-nio's internal buffer. Milestone 0
  must measure total-process memory under overload; feature work is blocked on
  an upstream fix, a narrow patch, or a verified newer release if teardown
  cannot satisfy the memory budget.

## Persistence and privacy

- Synchronize broker profile metadata through encrypted fields in the user's
  private CloudKit database in official signed builds. Keep a local-first
  profile replica so the app remains usable without an iCloud account,
  network, CloudKit entitlement, or configured container.
- Open-source and self-built variants default to local-only profiles unless
  their builder supplies an Apple team, bundle identifier, CloudKit container,
  entitlements, and schema. Never grant third-party builds access to the
  official production container.
- Store passwords and private keys in Keychain, never in profile JSON, iCloud
  records, logs, fixtures, or documentation.
- Credentials are device-local in the first release. A device receiving a
  synced profile without credentials prompts on connect.
- Window/workspace state and message history are local to a device. They are
  not iCloud-synchronized.
- Preserve deleted-profile tombstones long enough to prevent an older device
  from resurrecting deleted profiles. V1 retains them indefinitely; do not
  introduce time-based compaction without proof that every returning replica
  has observed the deletion.
- Treat broker addresses, usernames, topic names, payloads, and history as
  private data.
- Do not log payload bodies or credentials by default.
- Protect local profile, workspace, and history files with platform data
  protection where available and exclude volatile message history from device
  backups.

## mqtt-nio dependency rule

The requested mqtt-nio major version 3 is prerelease. Use the
[`jollyjinx/mqtt-nio`](https://github.com/jollyjinx/mqtt-nio) fork pinned to
revision `e670a69ee3122bd11ef04f668757ffc01c263468`. That revision is one commit
on top of upstream `3.0.0-alpha.2` and prevents MQTT task timeout double
completion. Do not depend on `main`; keep the immutable revision pin until the
fix is available in a verified upstream release. See
`AI/MQTT_NIO_FORK.md` for the exact delta and adoption notes. Changes to the
pin require:

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

- Follow `AI/MACOS_WORKSPACE_LAYOUT.md` for connected macOS toolbar placement,
  split-view sizing, desktop row density, and exceptional-state banners.
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
