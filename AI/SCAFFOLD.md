---
title: "JollysMQTT Scaffold"
description: "Buildable app/package scaffold, dependency boundaries, project generation, and validation commands."
area: "build"
doc_type: "implementation-notes"
status: "active"
last_reviewed: "2026-09-23"
tags:
  - "swift"
  - "swiftui"
  - "swiftpm"
  - "xcode"
---

# JollysMQTT Scaffold

The checked-in `JollysMQTT.xcodeproj` is generated from `project.yml` with
XcodeGen:

```bash
xcodegen generate --spec project.yml
```

Regenerate the project after changing the app target, build settings, local
package reference, assets, plist properties, or schemes. Commit both the source
spec and generated project so building the repository does not require
XcodeGen.

The app target's Swift module is named `JollysMQTTApp`, while its product and
scheme remain `JollysMQTT`. This prevents build-output collisions with the
package's `JollysMQTT` composition module.

macOS Debug builds use ad hoc signing with the network-client entitlement, so
they can connect to local brokers without an Apple development team. They do
not enable App Sandbox, preserving the existing local profile and history
locations used by earlier unsigned Debug builds. Generic iOS validation builds
remain unsigned. Official configurations retain their separately signed,
sandboxed entitlements and CloudKit capabilities.

An unsigned macOS Debug app launched through Launch Services timed out before
opening a connection to a broker on the local subnet, while the same executable
run directly from a terminal connected. The ad hoc signed Debug app with the
network-client entitlement connected using the saved profile. Keep the Debug
signing rule when regenerating the project from `project.yml`.

## Package boundaries

The package dependency graph is intentionally acyclic:

```text
JollysMQTTCore
├── JollysMQTTTransport
├── JollysMQTTStorage ── CSQLite
└── JollysMQTT ── Core + Transport + Storage
```

The application imports only SwiftUI and the package's `JollysMQTT` product.
The MQTTNIO/NIO dependency was deliberately absent from the initial scaffold.
Ticket #2 added mqtt-nio only to `JollysMQTTTransport` and proved its Apple
Transport Services lifecycle without exposing dependency types to other
modules. The current dependency policy follows `jollyjinx/mqtt-nio` `main` and
checks in the resolved revision.

## Validation

From `JollysMQTTPackage`:

```bash
swift build
swift test --parallel
```

From the repository root:

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
