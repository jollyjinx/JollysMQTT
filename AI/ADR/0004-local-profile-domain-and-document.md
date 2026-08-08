---
title: "Local Profile Domain and Document"
description: "Secret-free broker profile values, validation, ordered atomic local persistence, and the feature-scoped editor workflow."
area: "architecture"
doc_type: "adr"
status: "accepted"
last_reviewed: "2026-08-08"
tags:
  - "profiles"
  - "privacy"
  - "persistence"
  - "mvi"
  - "swiftui"
---

# ADR 0004: Local Profile Domain and Document

## Context

Broker profiles must be useful before CloudKit or Keychain is available. They
also contain private metadata, must survive interruption and corruption, and
must never acquire a serialized password or a password-presence flag.

The profile editor spans simple value edits, validation, asynchronous
persistence, and connect readiness. Those responsibilities cross the Core,
Storage, and SwiftUI composition targets.

## Decision

`BrokerProfile` and its nested policy values are immutable, `Codable`,
`Hashable`, and `Sendable` Core values. The model contains an optional username
but has no secret field, credential bytes, or credential-status field.
Credentials remain a separate concern for ticket #6.

Core validation is transport-neutral and rejects:

- malformed host names and IP addresses,
- invalid ports and MQTT strings,
- wildcards in publication topics,
- misplaced wildcards in subscription filters,
- missing or duplicate enabled subscriptions,
- invalid client identifiers, keepalive values, and reconnect bounds, and
- a connection-random client ID combined with a persistent session.

New profiles explicitly contain `#` and `$SYS/#` at QoS 0. The editor presents
a warning while either broad filter is enabled.

`LocalProfileRepository` owns a version-1 JSON document containing ranked
profiles. It writes the primary and backup atomically. The first successful
write establishes both files; later successful writes preserve the prior
validated primary as the last-known-good backup. A corrupt or invalid primary
can recover from that backup and restore the primary. An unsupported future
version never falls back to an older backup, because doing so would silently
downgrade and overwrite newer data.

After every atomic replacement, and again whenever existing documents are
loaded, an injected file policy applies
`completeUntilFirstUserAuthentication` protection on iOS to both the primary
and backup. Policy failures propagate so an unprotected write cannot be
reported as fully durable. Profile documents remain eligible for device
backup; only volatile message history is excluded.

Reorder rank is explicit document data, not array-index identity. Reads sort by
rank with UUID as the deterministic tie-breaker.

The reusable SwiftUI layer uses a feature-scoped MVI loop:

```text
View intent -> pure ServerListFeature reducer -> state + effect
                                             -> repository
                                             -> action -> reducer
```

The UI store is `@MainActor` and `@Observable`. Editor bindings project through
store subscripts that dispatch intents, so views do not mutate feature state or
call storage directly. Persistence effects are serialized in intent order;
optimistic state remains visibly marked undurable after a failed write.

Regular-width iPad and macOS broker lists keep the selected saved profile's
draft in the detail pane. Compact layouts retain a dedicated modal editor.
Draft identity is the stable profile UUID, and changing selection or connecting
while the draft differs from storage enters an explicit decision state. The
user can save, discard, or continue editing; validation failure preserves the
draft and cannot replace the stored profile or begin a connection. A
Save-and-Connect continuation persists and notifies the feed-generation
coordinator before handing the saved immutable profile to the workspace, so an
existing live generation still requires the registry's explicit all-window
reconnect boundary.

## Consequences

- A serialized-profile schema allow-list can prove the absence of credential
  keys in addition to searching for forbidden names and bytes.
- Profile CRUD and reorder work in local-only builds and without an account.
- The backup is intentionally one generation, not an unbounded revision log.
- CloudKit logical revisions, tombstones, and encrypted remote fields remain a
  later synchronization layer and do not alter the connection value.
- Password entry and Keychain availability indicators are intentionally absent
  until ticket #6 provides the credential boundary.
