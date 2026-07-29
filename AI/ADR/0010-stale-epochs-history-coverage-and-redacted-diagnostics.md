---
title: "Stale Epochs, History Coverage, and Redacted Diagnostics"
description: "Decision record for reconnect freshness, durable coverage gaps, history recovery ordering, overload handoff, and privacy-safe failure diagnostics."
area: "architecture"
doc_type: "architecture-decision-record"
status: "accepted"
last_reviewed: "2026-07-29"
tags:
  - "mqtt"
  - "history"
  - "sqlite"
  - "diagnostics"
  - "privacy"
  - "swift-concurrency"
---

# ADR 0010: Stale Epochs, History Coverage, and Redacted Diagnostics

## Context

An MQTT explorer cannot infer current broker state from values received before
a reconnect. Durable history can also become incomplete independently of live
topic ingestion, and local ingress overload is conservative because upstream
buffers may contain publications JollysMQTT cannot count.

These states must be visible without copying broker endpoints, usernames,
topics, payloads, credentials, or arbitrary third-party error text into
feature state or diagnostics.

## Decision

Every successful transport connection announces its `ConnectionEpochID` to the
shared ingestion actor before subscription work begins. A value-bearing topic
is stale when its latest delivery belongs to another epoch. Stable topic
identity, counters, selection, and expansion remain intact, but stale payload,
QoS, retained, and activity metadata cannot satisfy current-value search or be
presented as current broker state. A value-bearing parent remains stale even
when one of its descendants is observed in the new epoch.

History append failure opens one actor-owned coverage interval at the receive
time and epoch of the first message in the failed batch. The failed batch,
already pending messages, and later live messages increment its exact locally
known missing count while topic indexing continues. The UI exposes
`historyDegraded`, the count, and an explicit Retry History intent.

Recovery is ordered by the same serialized history-operation ownership used by
append, flush, and shutdown. Pending coverage is represented by at most one
conservative interval per typed reason. Repeated failures of the same reason
merge their epochs, boundaries, and counts, while storage failure and local
overload remain separate. This keeps recovery bounded without losing an
earlier interval when recording a later gap also fails.

The actor remains degraded while it awaits durable gap recording. An ingress
call that interleaves during that await updates the live index, then waits
before it can append. Recovery records and removes each interval in durable
order; a partial failure retains every interval not yet recorded. Successful
recording closes storage-failure intervals at the supplied recovery boundary
and append resumes only after every pending interval is durable. Failed
recording leaves persistence degraded.

SQLite schema version 3 stores coverage gaps independently of topic rows. Each
gap has durable order, history source, optional connection epoch, start and
optional end, a minimum missing-message count, a typed reason, and an
open-ended flag. Range-and-limit queries let history, diff, and chart features
display coverage without unbounded loading.

Milestone 0 overload reports retain the first-rejection wall-clock boundary and
minimum locally missing count. The connection and subscription scopes unwind
before the application writes the conservative open-ended gap. The feed then
enters terminal overload and never reconnects until explicit user Retry.

Failures retain a structured diagnostic category and reason code. Categories
cover DNS, TCP, TLS, CONNACK, SUBACK, local overload, storage, cancellation,
configuration, credentials, and protocol failures. Diagnostic values contain
no arbitrary strings or connection/content metadata. SwiftUI maps the typed
state to localized, user-readable text and semantic controls.

## Consequences

- Reconnect never makes cached values look current.
- Storage failure does not interrupt bounded live ingestion.
- Durable consumers can distinguish complete history from closed and
  conservative open-ended gaps.
- Gap recovery, concurrent ingestion, flush, and shutdown cannot make
  contradictory durability claims through actor reentrancy.
- Overload persistence cannot extend mqtt-nio structured teardown.
- Diagnostics remain actionable without becoming a privacy side channel.
