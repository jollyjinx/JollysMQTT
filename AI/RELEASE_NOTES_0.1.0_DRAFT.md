---
title: "JollysMQTT 0.1.0 Draft Release Notes"
description: "Human-readable draft notes for the first JollysMQTT release candidate."
area: "release"
doc_type: "release-notes"
status: "draft-unapproved"
last_reviewed: "2026-08-09"
tags:
  - "release-notes"
  - "0.1.0"
  - "draft"
---

# JollysMQTT 0.1.0

> Draft for review. These notes are not approved for publication and do not
> indicate that signing, CloudKit production, artwork, or device acceptance is
> complete.

JollysMQTT is a native MQTT explorer for iPhone, iPad, and Mac. This first
release candidate focuses on inspecting busy brokers without hiding overload,
keeping credentials private, and preserving useful workspace state across
windows and launches.

## Highlights

- Create, reorder, edit, and connect to broker profiles with device-local
  credentials stored separately in Keychain.
- Browse a live hierarchical topic outline with stable selection, expansion,
  search, sort, activity, and freeze controls.
- Inspect text, JSON, numeric, and binary payloads with explicit truncation and
  safety limits.
- Publish text or binary values at supported QoS levels, set retained values,
  and explicitly clear a retained topic.
- Keep bounded local SQLite history, compare messages, identify coverage gaps,
  and chart numeric topic values in configurable dashboards.
- Use independent iPad and Mac windows whose navigation, topic presentation,
  publish drafts, history position, and chart layout restore locally.
- Choose device-only profile storage. Officially provisioned builds are
  designed to synchronize encrypted profile metadata through the user's
  private CloudKit database while keeping credentials device-local.

## Privacy and reliability

- Broker addresses, usernames, topics, payloads, and history are treated as
  private. Payload bodies and credentials are not logged by default.
- Message history and workspace state stay on the device and history is
  excluded from backup. iOS applies data protection where available.
- Incoming traffic crosses bounded queues. If a broker exceeds the safe
  capacity, JollysMQTT disconnects with a visible overload reason instead of
  allowing memory to grow without a bound.
- Local profile, workspace, and history formats are versioned and include
  deterministic migration, recovery, and future-version safeguards.

## First-release limitations

- iPhone and iPad connections are foreground sessions; JollysMQTT is not a
  background monitoring service.
- Credentials do not synchronize. A second device prompts for its own password
  or secret before connecting.
- CloudKit profile synchronization is available only to an officially signed
  and provisioned build. Open-source and ordinary self-built variants default
  to device-only profiles.
- MQTT 3.1.1 over TCP with system-trusted TLS is the supported transport.
  WebSockets, custom certificate authorities, and client-certificate
  authentication are not part of 0.1.0.
- History is intentionally bounded and local. Overload or retention can create
  visible gaps rather than implying a complete audit log.

See `AI/RELEASE_READINESS_ACCEPTANCE.md` for the automated evidence and the
external gates that must be completed before these notes can be published.
