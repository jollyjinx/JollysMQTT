---
title: "JollysMQTT Scaffold"
description: "Buildable app/package scaffold, dependency boundaries, project generation, and validation commands."
area: "build"
doc_type: "implementation-notes"
status: "active"
last_reviewed: "2026-07-28"
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

Debug builds disable code signing so a fresh checkout and self-built variant
can run the documented macOS and generic iOS validation commands without an
Apple development team. Release builds retain normal signing behavior for the
official capability and archive work in later tickets.

## Package boundaries

The package dependency graph is intentionally acyclic:

```text
JollysMQTTCore
├── JollysMQTTTransport
├── JollysMQTTStorage ── CSQLite
└── JollysMQTT ── Core + Transport + Storage
```

The application imports only SwiftUI and the package's `JollysMQTT` product.
The MQTTNIO/NIO dependency is deliberately absent from this scaffold. Ticket
#2 adds the exact mqtt-nio prerelease pin to `JollysMQTTTransport` and proves
its Apple Transport Services lifecycle without exposing dependency types to
other modules.

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
