---
title: "Shared Feed Registry and Explicit Generation Switch"
description: "Profile-owned feed pooling, reference-counted workspace leases, stale configuration presentation, and non-overlapping generation replacement."
area: "architecture"
doc_type: "adr"
status: "accepted"
last_reviewed: "2026-07-28"
tags:
  - "mqtt"
  - "broker-feed"
  - "multiwindow"
  - "configuration-generation"
  - "structured-concurrency"
---

# ADR 0008: Shared Feed Registry and Explicit Generation Switch

## Context

ADR 0007 gives one raw broker feed a structured connection, subscription,
publish, retry, and cancellation lifetime. Creating that feed independently
for every workspace would duplicate wildcard traffic and history writes, and
fixed client identifiers or persistent mqtt-nio sessions could cause broker
takeover or simultaneous session use.

An edit made in one broker-list window must also become visible to every
workspace using that profile. Applying such an edit cannot briefly overlap the
old and new MQTT generation.

## Decision

`BrokerFeedRegistry` is a process-wide actor and the primary lookup is the
broker profile UUID. One profile entry contains exactly one active immutable
`BrokerConnectionKey`; a changed key becomes a pending generation inside that
same entry and can never create a second entry for the profile.

The secret-free key canonicalizes numeric IPv4 and IPv6 hosts from their
`inet_pton` bytes (after removing IPv6 brackets), lowercases DNS names, and
normalizes the enabled subscription set. It contains endpoint, transport,
username, client-ID policy, session policy, keepalive, reconnect policy,
subscription filters and QoS, and credential revision. Profile name, reorder
rank, subscription identity, and disabled filters do not alter the effective
connection. Fixed-client-ID broker namespaces use the same canonical host
identity.

Every registry generation has explicit identities for its:

- connection,
- MQTT client/session,
- subscription set,
- topic index, and
- history writer.

Every workspace lease for that generation receives the same identity set and
one broadcast connection snapshot. Ticket #10 will install the concrete topic
index and history writer behind these generation-owned seams.

Leases are reference counted. Canceling, disconnecting, or closing one
workspace detaches only that lease. The raw feed remains active while another
lease exists. The last release starts an injected-clock grace period; a lease
arriving during the grace period cancels retirement and reuses the generation.
Raw feed retirement remains reserved until its structured release completes,
so another generation cannot acquire its fixed client ID during teardown.

Scene activity is aggregated across attached leases. The shared feed suspends
only when every attached scene is inactive and resumes when any lease is
active. A zero-lease grace period deliberately leaves the feed unchanged until
retirement.

Successful profile persistence and credential mutation notify the registry.
A connection-affecting change records a monotonic pending revision and
broadcasts it to existing leases. A new workspace always attaches to the
active generation and receives the same warning; it never silently starts the
pending configuration.

Profile repository writes and their successful registry notifications share
one serialized persistence tail. A later write cannot begin until the prior
write's notification completes, so actor reentrancy cannot leave an older
profile snapshot as the registry's final desired generation.

The registry retains the latest persisted desired configuration independently
of a live generation. A detached workspace retry after grace retirement
therefore uses profile and credential edits that arrived while no feed entry
existed. A profile missing from the complete persisted profile snapshot is
tombstoned and its cached configuration is discarded, so a stale detached
lease cannot resurrect a deleted profile.

`ConnectionFeature` keeps **Apply Later** local to one workspace by remembering
the exact pending revision it dismissed. Other and newly opened workspaces
continue to warn, and a newer pending revision warns again.

**Reconnect All Windows to Apply** performs one ordered switch:

1. reserve the pending configuration and reject a fixed-ID conflict,
2. stop observing and fully release the old raw feed,
3. create the new feed only after old release completes, and
4. attach every remaining lease to the new shared identities.

Profile edits arriving during teardown become a later pending revision instead
of mutating the selected switch target. If every lease disappears during
teardown, no replacement feed is created.

An explicit client ID conflicts only with a distinct active or retiring
profile in the same normalized broker namespace: host, port, and transport.
The registry rejects an initial conflicting lease with a typed terminal
failure. A conflict discovered before an all-window switch leaves the old
generation running and marks the pending generation blocked.

## Consequences

- Same-profile windows share one client/session, subscriptions, topic index,
  and history writer while retaining independent selection and presentation
  state.
- There is no overlap in raw feed or mqtt-nio session ownership across a
  generation switch.
- Display-only edits do not reconnect or churn history identity.
- Credential changes remain observable without putting credential material in
  a key, snapshot, feature state, log, or diagnostic.
- A fixed client ID can still be used against unrelated brokers; only a
  collision within the same broker namespace is blocked.
- Grace timing, stale revisions, switch ordering, conflict behavior, and
  workspace-local warning dismissal are deterministic without wall sleeps.
