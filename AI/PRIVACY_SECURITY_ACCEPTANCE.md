---
title: "Privacy and Security Hardening Acceptance"
description: "Redaction, TLS, file protection, entitlements, destructive deletion, deterministic validation, and pending external release gates."
area: "release"
doc_type: "acceptance-record"
status: "implemented-pending-external-acceptance"
last_reviewed: "2026-07-29"
tags:
  - "privacy"
  - "security"
  - "tls"
  - "storage"
  - "release"
---

# Privacy and Security Hardening Acceptance

Ticket #24 hardens locally testable privacy and security behavior. Signed
CloudKit and two-device verification is deliberately deferred because the
required devices and account are not available. It is not reported as passed
and remains a release gate in
`CLOUDKIT_PROVISIONING_ACCEPTANCE.md`.

## Default diagnostic privacy

Normal application diagnostics remain typed and content-free:

| Layer | Preserved signal | Excluded private content |
|---|---|---|
| DNS/TCP | category and stable failure code | broker host/address |
| TLS | trust-rejection category only when the underlying error identifies trust failure | certificate path, host, endpoint |
| MQTT | CONNACK/SUBACK/protocol category | username, password, topic/filter |
| Overload | bounded-ingress overload category | payload and topic |
| Storage | history-persistence category | database path, topic, payload |

The mqtt-nio connection and in-process session receive a dedicated no-op
SwiftLog logger. This isolates upstream packet, endpoint, and topic trace
messages even if an embedding process installs a verbose task-local logger.
Passwords use a redacted description and mirror. Payload bodies, full
usernames, topics, endpoints, and credentials are absent from default
diagnostics and test fixture descriptions.

## TLS contract

Production Apple connections use Network.framework Transport Services with
full certificate verification and default system trust roots. There is no
insecure trust override, certificate exception, or silent downgrade to TCP.

Explicit Network.framework and Security-framework trust statuses map to a
typed, redacted trust rejection. A generic channel close or connection timeout
does not prove that certificate validation failed. mqtt-nio `3.0.0-alpha.2`
collapses a real system-default NIOTS trust rejection into a channel connect
timeout without retaining the underlying status. Only for that ambiguous TLS
failure, JollysMQTT performs a bounded Network.framework diagnostic handshake
with the same server name, trust roots, and full certificate verification. An
explicitly rejected trust evaluation becomes the typed trust failure; accepted
or inconclusive evaluation remains generic broker-unavailable. The diagnostic
does not exchange MQTT credentials, topics, or payloads and emits no logs.
DNS, network reachability, broker availability, authentication, subscription,
overload, protocol, and storage failures retain independent typed diagnostics.

The release-candidate opt-in isolated Mosquitto suite passed locally with both
the trusted local CA and untrusted-certificate fixtures. Signed-device
integration remains deferred with the unavailable device matrix.

## Local data protection and backup policy

On iOS/iPadOS, local repositories apply
`completeUntilFirstUserAuthentication` protection to profile replicas and
backups, workspace records, profile-sync state/preferences, retention
settings, and the deletion cleanup journal. SQLite applies protection to the
database before schema/configuration work and refreshes protection for the
database, WAL, and shared-memory files after WAL activation.

The history database, WAL, and shared-memory files are volatile local message
history and are excluded from device backup. Profiles and workspaces are
protected but are not excluded from backup: they are durable user state, not
volatile history. On macOS, version 1 relies on the app sandbox and the
volume's at-rest protection; it does not claim application-level database
encryption.

## Broker deletion contract

The confirmation dialog separates the consequences before deletion:

| Resource | Behavior |
|---|---|
| Profile | Always removed locally and represented by a permanent sync tombstone after a successful commit |
| Workspace presentation | Topic selection, expansion, search, and chart state for the removed profile are scrubbed; stale restored workspaces are scrubbed and re-persisted |
| Credential | Device-local Keychain password is removed only when independently selected |
| History | Broker database, WAL, and shared-memory files are removed only when independently selected |
| Retention settings | Broker-scoped settings are removed after profile deletion |

Optional irreversible cleanup begins only after the recoverable profile
mutation commits. A minimal journal containing only profile UUID and the two
cleanup choices makes history, credential, and retention cleanup resumable
after a crash. If the profile still exists on relaunch, the journal entry is
discarded without deleting resources. Tombstoned replicas no longer retain a
live-profile backup that could resurrect the deleted broker after primary-file
corruption.

Each resource reports kept, removed, partially removed, or failed
independently. Failed or pending secure history cleanup remains retryable.

## Capabilities and least privilege

| Build family | macOS sandbox/network | CloudKit | Push |
|---|---|---|---|
| Debug / Release | app sandbox plus outgoing network client only | none; local-only mode | none |
| Official Development / Release | app sandbox plus outgoing network client | private CloudKit container entitlement | platform-specific remote-notification entitlement |

iOS ordinary builds have no entitlement file. All builds provide
`NSLocalNetworkUsageDescription` because user-configured local brokers are a
core feature. Credentials are Keychain items accessible after first unlock,
device-only, and non-synchronizable. No inbound network server, arbitrary
file access, location, contacts, camera, microphone, or broad background-mode
capability is requested.

`project.yml` now models the official configurations and their exact
entitlement/build-setting selection, so regenerating the Xcode project cannot
silently erase or broaden those boundaries.

Enhanced Security, pointer authentication, hardened-process entitlements, and
hardware memory tagging were audited but not enabled without confirmation.
The proposal and rationale are recorded in `xcode-security-settings.md`.

## Automated acceptance

Deterministic coverage includes:

- privacy-safe upstream logging and redacted authentication/failure values;
- TLS policy plus explicit trust mapping and ambiguous close/timeout mapping;
- profile tombstone backup recovery without resurrection;
- file-protection ordering and database/WAL/shared-memory backup exclusion;
- deletion choice independence, partial failure, retry, durable relaunch
  cleanup, minimal journal content, and live-profile journal safety;
- broker deletion workspace scrubbing, including stale relaunch state.

Local deterministic validation completed on 2026-07-29:

- `swift build` and the complete `swift test --parallel` package suite passed.
- Unsigned macOS and generic iOS Xcode builds passed for Debug,
  Official Development, and Official Release.
- The seven-test opt-in isolated Mosquitto integration suite passed, including
  trusted and untrusted NIOTS TLS fixtures.
- XcodeGen regeneration, strict formatting on changed Swift files, privacy
  scans, plist validation, and `git diff --check` passed.

These local checks do not substitute for the signed entitlement, CloudKit, or
two-device acceptance work explicitly deferred below.

## Pending release gates

- Signed official iOS/iPadOS and macOS entitlement inspection.
- Signed CloudKit Development schema inspection and all two-device scenarios.
- Explicit decision and compatibility validation before enabling any Enhanced
  Security capability.
- Signed archive validation and CloudKit Production promotion by an authorized
  release operator.
