---
title: "Device-Only Credentials and Missing-Credential Flow"
description: "Keychain identity, accessibility, revision ownership, scoped resolution, and the secret-free connection prompt workflow."
area: "architecture"
doc_type: "adr"
status: "accepted"
last_reviewed: "2026-07-28"
tags:
  - "credentials"
  - "keychain"
  - "privacy"
  - "mvi"
  - "swiftui"
---

# ADR 0005: Device-Only Credentials and Missing-Credential Flow

## Context

Broker profiles synchronize between devices, but passwords do not. The app
must distinguish an available local password from a missing one without
loading secret bytes into observable UI state. Password changes must also
invalidate the effective connection generation shared by multiple windows.

The first release reconnects only while an Apple-platform scene is active. It
does not promise background MQTT operation while the device is locked.

## Decision

Each password is one generic-password Keychain item with:

- service `eu.jinx.JollysMQTT.credentials.password.v1`,
- account equal to the lowercased stable broker-profile UUID,
- `kSecAttrSynchronizable` explicitly set to false, and
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

`WhenUnlockedThisDeviceOnly` is deliberately stricter than first-unlock
access. The current foreground reconnect policy does not justify password
availability while the device is locked. The accessibility choice can change
only with a tested reconnect requirement and a migration plan.

The production Security translation is shared by the live client and unit
tests. Tests inspect the exact dictionaries for availability, add, update,
delete, and scoped retrieval without calling the developer's Keychain.

`CredentialRepository` is an actor. `CredentialRepository.shared` is the
process-wide default so all windows observe one revision authority. Saving,
replacing, or deleting an existing item advances that profile's non-secret
`UInt64` revision only after the synchronous Keychain mutation succeeds.
Capacity is checked before mutation. Deleting an already-missing item is a
successful no-op and does not advance the revision.

The revision is intentionally process-local. It distinguishes immutable live
connection generations; no feed survives process termination, so persisting a
counter across launch would not add freshness. The shared actor requirement is
important: constructing one repository per window would let live feed keys
diverge.

The UI receives only `CredentialStatus` (`missing` or `available`, plus the
revision). Its injected `CredentialRepositoryProtocol` exposes status, save,
and delete operations but no load operation. The concrete actor separately
provides `withCredential(for:expectedRevision:operation:)` for the future
connection-preparation runner. It validates the expected generation, retrieves
bytes immediately before that scoped operation, and never places them in
feature state, a feed key, a profile, or a diagnostic. The transient wrapper's
only public material accessor is a synchronous `withUTF8String` closure for
constructing transport authentication input.

`TransientCredential` is non-Codable and redacts description, debug
description, and reflection. Swift `String` and Foundation `Data` may copy
their backing storage, so complete zeroization cannot be guaranteed. The UI
clears its secure-field string promptly, limits the wrapper to one effect, and
never logs it. This is a best-effort lifetime reduction, not a claim of
cryptographic memory erasure.

Profiles without a username connect anonymously and do not query Keychain.
Profiles with a username require a local password. A missing password opens a
secure prompt; save success produces a one-shot connect-ready handoff holding
only the immutable profile, credential revision, and request ID. Cancellation,
denial, and stale responses preserve the profile. Interactive sheet dismissal
is disabled while a Keychain mutation is in flight.

Profile deletion offers two explicit choices:

- delete the profile but retain its device password, or
- delete the password first and remove the profile only after Keychain
  success.

## Consequences

- A profile synchronized to a new device can be displayed and edited before
  its local password exists.
- Anonymous brokers remain usable without manufacturing an empty credential.
- Replacing a password changes a non-secret feed-key input without disclosing
  the password.
- Keychain denial or cancellation cannot silently delete or corrupt the
  durable profile.
- Ticket L2 can prepare authentication through the scoped concrete-repository
  API without importing Security or loading bytes through a UI store.
- A future locked-device reconnect requirement needs an explicit accessibility
  review rather than silently weakening the current policy.
