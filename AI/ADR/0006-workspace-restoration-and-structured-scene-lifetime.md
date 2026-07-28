---
title: "Workspace Restoration and Structured Scene Lifetime"
description: "Typed scene identity, versioned local workspace records, process-wide dependencies, and deterministic scene release."
area: "architecture"
doc_type: "adr"
status: "accepted"
last_reviewed: "2026-07-28"
tags:
  - "workspace"
  - "restoration"
  - "swiftui"
  - "structured-concurrency"
  - "persistence"
---

# ADR 0006: Workspace Restoration and Structured Scene Lifetime

## Context

Each macOS or iPadOS window needs an independent presentation state while
profiles, credentials, and later broker feeds remain process-wide resources.
SwiftUI restores a typed value for each scene, but that value is only an
identity: it is not a durable application-state store.

Scene closure must also release one future broker-feed lease. `onDisappear`
and object deinitialization do not provide a sufficiently explicit or
awaitable correctness boundary for persistence and release.

## Decision

The app declares `WindowGroup(for: WorkspaceID.self)` with a default-value
closure. `WorkspaceID` is a lightweight UUID-backed `Codable`, `Hashable`,
`Sendable` value. The New Window command always passes a newly generated
identity. SwiftUI supplies the scene closure a nonoptional
`Binding<WorkspaceID>`; the default-value closure creates a fresh identity when
there is no restored value or a presentation value cannot be decoded.

`JollysMQTTAppDependencies.shared` constructs one process-wide profile
repository, credential repository, and workspace repository. Every scene
creates a distinct `WorkspaceSceneStore`, `WorkspaceStore`, and
`ServerListStore` from those shared dependencies. This prevents multiple
profile actors from racing on `profiles.json` while preserving independent
window selection and routing.

The canonical broker-list selection lives in the workspace record. The scene
composition projects it into the server-list feature for existing profile
editing and validation behavior; UI selection updates both values in one
main-actor operation. Startup reconciliation validates a restored selection
against loaded profiles before persisting a fallback.

Each workspace is one version-1 JSON document under local Application Support,
named by `WorkspaceID`. It contains:

- server-list or connected-profile routing,
- broker-list selection,
- selected topic,
- and an optional close date.

Writes use Foundation atomic replacement and apply
`completeUntilFirstUserAuthentication` data protection on iOS. Workspace
records remain eligible for device backup. Missing or corrupt current-version
records recover to a server-list value without crashing. An unsupported future
version is surfaced, preserved byte-for-byte, and cannot be overwritten by a
fallback.

Closed records remain for seven days. Startup pruning uses an injected clock,
removes only valid current-version records at or before the retention cutoff,
and preserves open, corrupt, and future-version files.

One SwiftUI `.task` awaits one `WorkspaceLifecycleOwner`. Cancelling that
structured scene task flushes every ordered presentation write, marks the
record closed, and invokes an injected idempotent lease releaser. The releaser
still runs if close persistence fails. Neither `onDisappear` nor `deinit`
participates in correctness.

Ticket #7 intentionally uses a no-op lease releaser. Ticket #8 can inject the
broker-feed lease implementation without changing workspace or scene
lifecycle semantics.

## Consequences

- Connecting transforms only the current scene record; it does not open
  another window.
- Two windows can show the same profile while retaining independent routing
  and selection.
- Normal quit/relaunch restores placeholder connected state and clears the
  close marker when the workspace opens.
- Persistence effects are ordered, and flush follows a moving latest-tail
  generation so a write enqueued while flushing cannot be missed.
- Workspace restoration or persistence failure has a localized visible alert.
- System-managed window geometry remains outside the workspace document.
