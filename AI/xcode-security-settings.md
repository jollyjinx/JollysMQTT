---
title: "JollysMQTT Xcode Security Settings"
description: "Persistent decisions for security-oriented Xcode build settings and hardened-process capabilities."
area: "release"
doc_type: "security-decision-record"
status: "active"
last_reviewed: "2026-08-09"
tags:
  - "xcode"
  - "security"
  - "build-settings"
  - "entitlements"
---

# JollysMQTT Xcode Security Settings

This is the single source of truth for security build-setting decisions. It
records the current state without treating a proposed capability as approved.
`project.yml` is the source of truth for generated Xcode configurations.

## Enabled settings

- `ENABLE_USER_SCRIPT_SANDBOXING` to `YES`: active at project level in every
  configuration.
- `SWIFT_STRICT_CONCURRENCY` to `complete`: active at project level in every
  configuration. The app and package compile in Swift 6 language mode.
- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`: active in the generated Xcode
  configurations.
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`: active in the generated
  Xcode configurations.
- `CLANG_WARN_DIRECT_OBJC_ISA_USAGE` to `YES_ERROR`: active in the generated
  Xcode configurations.
- `CLANG_WARN_OBJC_ROOT_CLASS` to `YES_ERROR`: active in the generated Xcode
  configurations.

No additional Clang-only warning or analyzer setting was enabled by the
2026-07-29 audit. JollysMQTT has no project-owned C, C++, or Objective-C source;
`CSQLite` is a system-library module map. Dependency source remains covered by
its own package settings.

The 2026-08-09 R6 re-audit resolved Debug, Release, Official Development, and
Official Release for macOS and generic iOS. All eight unsigned builds passed
without project-source or concurrency warnings. `ENABLE_ENHANCED_SECURITY` and
`ENABLE_POINTER_AUTHENTICATION` still resolve disabled, and no project-owned
C, C++, Objective-C, opaque binary framework, or XCFramework has been added.
This evidence preserves the deferred decision below; unsigned builds are not a
substitute for its required signed hardware validation.

## Disabled settings

No security setting was explicitly rejected. Settings that need confirmation
or hardware validation remain deferred.

## Deferred

- `ENABLE_ENHANCED_SECURITY` to `YES`: not enabled. Adding the capability
  changes build settings and all applicable entitlement files. It requires
  explicit confirmation, signed device builds, dependency compatibility
  validation, and rollback testing.
- `ENABLE_POINTER_AUTHENTICATION` to `YES`: not enabled. iOS/iPadOS device and
  macOS destinations support arm64e, while iOS Simulator requires an explicit
  `NO` override. Every SwiftPM dependency is source-based and no XCFramework or
  other opaque binary dependency was found, but the full source dependency
  graph must be rebuilt and tested as arm64e before adoption.
- `com.apple.security.hardened-process`: not added. If Enhanced Security is
  approved, this main entitlement, version string `2`, hardened heap, read-only
  dyld state, and platform restrictions string `2` should be added to every
  applicable app entitlement file.
- `com.apple.security.hardened-process.checked-allocations`: hardware memory
  tagging is not enabled. It is a separately gated, default-off option with
  narrower hardware support and moderate overhead. Start with soft mode on
  supported test hardware only after Enhanced Security is accepted.
- `ENABLE_C_BOUNDS_SAFETY` and
  `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS`: not applicable to the project-owned
  Swift sources. Re-evaluate if project-owned C or C++ is introduced.

## Confirmation-ready Enhanced Security proposal

If explicitly approved, apply the capability to the `JollysMQTT` application
target in Debug, Release, Official Development, and Official Release:

1. Set `ENABLE_ENHANCED_SECURITY = YES` and
   `ENABLE_POINTER_AUTHENTICATION = YES` in `project.yml`.
2. Set a target-level, SDK-qualified
   `ENABLE_POINTER_AUTHENTICATION = NO` for `iphonesimulator*`.
3. Set `iOSPackagesShouldBuildARM64e = YES` and
   `macOSPackagesShouldBuildARM64e = YES` in the shared embedded-workspace
   settings so source Swift packages build for arm64e.
4. Create `JollysMQTTApp/JollysMQTT.iOS.entitlements` for ordinary Debug and
   Release iOS builds, then add the default-on keys below to it and to:
   `JollysMQTT.macOS.entitlements`,
   `JollysMQTT.official.iOS.entitlements`, and
   `JollysMQTT.official.macOS.entitlements`.
5. Add:
   `com.apple.security.hardened-process = true`,
   `com.apple.security.hardened-process.enhanced-security-version-string = "2"`,
   `com.apple.security.hardened-process.hardened-heap = true`,
   `com.apple.security.hardened-process.dyld-ro = true`, and
   `com.apple.security.hardened-process.platform-restrictions-string = "2"`.
6. Leave hardware memory tagging keys absent unless separately approved.
7. Build every configuration for macOS, generic iOS, and iOS Simulator; then
   run the full package, MQTT integration, signed-device, archive, and launch
   validation matrix before release.

The dependency graph is all source SwiftPM packages, including mqtt-nio,
SwiftNIO, SwiftNIO SSL, and their vendored C sources. No binary framework or
XCFramework arm64e blocker was found. That makes pointer-authentication
adoption feasible, but it is not proof of runtime compatibility.
