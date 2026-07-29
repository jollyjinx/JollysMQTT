---
title: "Bounded Numeric Chart Implementation"
description: "Durable identity, restoration, deduplication, bounded-work, and workspace invariants for the first pinned MQTT chart."
area: "charting"
doc_type: "implementation-notes"
status: "active"
last_reviewed: "2026-07-29"
tags:
  - "charts"
  - "history"
  - "mqtt"
  - "persistence"
  - "swiftui"
---

# Bounded Numeric Chart Implementation

The first chart is one workspace-owned series. Its stable identity is the
broker profile ID, exact MQTT topic, and optional canonical nonroot JSON
Pointer. The current history-source ID is deliberately not part of that
identity: restoration always queries the source attached to the current live
feed.

Only received messages with stored payload bytes participate. Durable and live
copies are deduplicated by connection epoch, connection ordinal, and delivery
direction. Timestamp and value equality are never used for identity. History
retains durable input order, including equal timestamps; the bounded display
window is stably ordered by timestamp immediately before downsampling.

Chart work has independent public caps for queried messages, bytes per payload,
aggregate bytes per load, JSON depth and node count, retained raw samples, and
display samples. SQLite filters exact source/topic/direction and oversized or
metadata-only rows before copying payload bytes. The store defensively repeats
those checks because alternate `BrokerHistoryReading` implementations use the
same API.

Raw retention is capped in arrival or durable input order before presentation
sorting. This ensures a new live point remains retained if the device clock
moves backward. While restoration, parsing, or pause prevents an immediate
append, the store retains at most the newest pending live message.

`autoScroll == false` requires a persisted visible-range end anchor. Invalid
legacy or programmatically constructed `false` plus no-anchor configurations
normalize safely to auto-scroll on. Turning auto-scroll off without any sample
is rejected; once samples exist, the latest arrival timestamp becomes the
fixed anchor. Swift Charts receives the complete explicit time domain, not
only filtered samples, so a five-minute range continues to render as five
minutes when data covers less time.

Workspace persistence remains document version 1 with an additive optional
chart field. A nonnil chart can be saved only while connected to the matching
profile. Connected restoration and broker changes sanitize mismatched series.
A server-list workspace may retain the chart for its last selected broker, but
it is detached from feed snapshots until that broker reconnects.
