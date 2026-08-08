---
title: "macOS Connected Workspace Layout"
description: "Desktop-specific information density, toolbar placement, split-view sizing, and adaptive-control rules for the connected MQTT workspace."
area: "ui"
doc_type: "implementation-notes"
status: "active"
last_reviewed: "2026-08-08"
tags:
  - "macos"
  - "swiftui"
  - "adaptive-layout"
  - "topic-outline"
---

# macOS Connected Workspace Layout

The connected macOS workspace is an inspection surface, so its broker data
starts immediately below the window toolbar. Broker identity, connection state,
disconnect/retry, broker-list navigation, and Help belong in the titlebar
toolbar rather than in a large header inside the document.

Routine connected state consumes no content-height banner. Exceptional state
may insert a compact banner below the toolbar for a connection failure or
retry, changed broker generation, or degraded durable history. Removing the
condition removes the banner and returns the space to the workspace.

The primary layout remains a native adjustable `NavigationSplitView`:

- the topic outline has a 320-point minimum, 480-point ideal, and 680-point
  maximum initial column width;
- the outline and the active Details, Publish, or Charts destination occupy the
  full content height;
- the user can resize or collapse the topic column through native macOS split
  behavior.

When Charts is active and the window can fit all regions, the detail region
uses a native horizontal split so the topic outline, selected-topic
information, and chart dashboard remain visible in that order. The selected
topic information has a 360-point minimum, 440-point ideal, and 600-point
maximum width. The dashboard has a 320-point minimum and 640-point ideal width.
Together with the topic outline and native divider widths, this makes 1,002
points the regular graph-workspace threshold. Below that fit the workspace uses
the compact tab presentation, where Charts remains a dedicated destination and
keeps the same dashboard state.

Navigating the outline only changes the information region; it does not dismiss
or rebuild chart cards. Pinning from topic information updates the already
visible dashboard. An empty dashboard keeps its region visible and explains
how to select a numeric or Boolean payload and pin it.

macOS topic rows are intentionally denser than touch-platform rows. Disclosure
targets are 20 points, indentation advances by 12 points, and current payload
summaries stay inline with the topic segment. iPhone and iPad retain 44-point
custom interaction targets and the more spacious two-line row. Structural JSON
rows use the same platform distinction: compact desktop rows and 44-point touch
rows.

Secondary commands do not remain expanded in the reading flow. Payload copy
variants live in one Copy menu. Single-topic and subtree retained-value deletion
live in a Retained Values menu; confirmation still explains the exact MQTT
semantics and destructive scope, and active or completed operation feedback
appears inline only while it is relevant.

## Acceptance

- A healthy connected macOS workspace shows no in-content broker/status header.
- Topics and the selected workflow begin directly below the toolbar and use the
  remaining window height.
- The toolbar exposes broker identity, connection state, disconnect/retry,
  broker-list navigation, and Help.
- Topic payload summaries are inline on macOS, and substantially more topic rows
  fit in the same height than in the touch presentation.
- Copy and retained-value actions remain reachable without permanent vertical
  button stacks.
- Charts at a fitting regular width presents three independently resizable
  regions in topic-outline, topic-information, and dashboard order. Chart cards
  preserve identity, order, pause state, settings, and clear boundaries while
  topic selection changes.
- Failure, generation-change, and history-degradation banners appear only while
  their exceptional state exists.
- Compact iPhone/iPad navigation and touch target sizing are unchanged.
