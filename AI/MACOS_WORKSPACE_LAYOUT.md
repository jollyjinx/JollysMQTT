---
title: "macOS Connected Workspace Layout"
description: "Desktop-specific information density, toolbar placement, split-view sizing, and adaptive-control rules for the connected MQTT workspace."
area: "ui"
doc_type: "implementation-notes"
status: "active"
last_reviewed: "2026-10-03"
tags:
  - "macos"
  - "swiftui"
  - "adaptive-layout"
  - "topic-outline"
---

# macOS Connected Workspace Layout

## Broker list and connection windows

The app has one persistent Brokers window and a typed `WindowGroup` for
connection workspaces. Double-clicking a broker, Connect, or Command-O first
uses the existing draft/credential checks, then saves a fresh workspace record
and opens that workspace. The broker list stays visible and does not acquire a
feed lease. Repeating Connect creates another independently selectable window;
the registry still shares the feed for the same effective broker configuration.

Command-N and the connection toolbar’s Brokers button bring the Brokers window
forward (or reopen it). They do not disconnect or replace a connection window.
Closing a connection releases only its lease. Saving the new workspace must
succeed before opening the window; failure leaves the broker list available
and presents the workspace persistence alert. iOS/iPadOS keep their existing
in-scene Connect behavior.

The connected macOS workspace is an inspection surface, so its broker data
starts immediately below the window toolbar. Broker identity, connection state,
disconnect/retry, broker-list navigation, and Help belong in the titlebar
toolbar rather than in a large header inside the document.

Routine connected state consumes no content-height banner. A compact banner
below the toolbar shows the current preparation, connection, or subscription
stage while a connection attempt is active. It also shows a connection failure
or retry, changed broker generation, or degraded durable history. Removing the
condition removes the banner and returns the space to the workspace.

The primary layout remains a native adjustable `NavigationSplitView`:

- the topic outline has a 320-point minimum and 640-point ideal width. Its
  maximum is beyond practical window widths so the divider can give it the
  additional space available when the window grows;
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

macOS topic rows are intentionally denser than touch-platform rows. The outline
uses a plain native list with no separators or vertical row insets and a
22-point minimum row height. Topic names, payload summaries, and descendant counts use
the primary semantic foreground for black text in light appearance and readable
text in dark appearance. Topic labels and counts stay on one line rather than
increasing row height as the pane narrows. Disclosure targets are 16 points,
indentation advances by 12 points, and current payload summaries stay inline
with the topic segment. Indexed summaries flatten payload
line breaks into one display line, and the row gives that line the available
width before its alignment spacer. Branch counts sit immediately after the
name/value instead of floating at the far edge of the pane. iPhone and iPad retain 44-point
custom interaction targets and the two-line row, with zero vertical row insets
and row spacing. The iPad topic pane prefers 480 points instead of 360.
Structural JSON rows use the same platform distinction: compact desktop rows
and 44-point touch rows. Desktop JSON rows have no extra stack spacing or
vertical padding.

A received message briefly tints its row green and adds a leading activity bar;
the highlight fades after 800 ms. Reduced Motion disables the fade. A coalesced
subtree message counter drives the highlight, so identical payloads and updates
below collapsed ancestors remain visible. Only mounted rows own cancellable
highlight tasks. Freeze View suppresses highlights until Jump to Live. Old
rows do not flash merely because they were scrolled into view.

Secondary commands do not remain expanded in the reading flow. Payload copy
variants live in one Copy menu. Single-topic and subtree retained-value deletion
live in a Retained Values menu; confirmation still explains the exact MQTT
semantics and destructive scope, and active or completed operation feedback
appears inline only while it is relevant.

## Broker profile editor

The shared profile form explicitly uses the grouped form style on macOS so it
scrolls within the available editor height. The default macOS form sizes to its
contents; expanding Advanced Settings or adding subscriptions must not increase
the window's minimum height beyond the screen. Keep the inline editor header
and Save/Revert footer outside the scrolling form.

Port fields disable numeric grouping: display `1883`, never `1.883` or `1,883`,
regardless of the locale's thousands separator.

## Acceptance

- A healthy connected macOS workspace shows no in-content broker/status header.
- Topics and the selected workflow begin directly below the toolbar and use the
  remaining window height.
- The toolbar exposes broker identity, connection state, disconnect/retry,
  broker-list navigation, and Help.
- Topic payload summaries are inline on macOS, and substantially more topic rows
  fit in the same height than in the touch presentation.
- At normal text sizes, macOS topic rows use a 22-point minimum without
  additional list spacing; topic text retains full contrast when inactive.
- Widening the window lets the topic column grow past 680 points so long
  payload previews can use the extra width.
- Copy and retained-value actions remain reachable without permanent vertical
  button stacks.
- Charts at a fitting regular width presents three independently resizable
  regions in topic-outline, topic-information, and dashboard order. Chart cards
  preserve identity, order, pause state, settings, and clear boundaries while
  topic selection changes.
- Connection-stage banners appear during an active connection attempt. Failure,
  generation-change, and history-degradation banners appear only while their
  exceptional state exists.
- Compact iPhone/iPad navigation and 44-point touch targets are preserved.

## Verification notes

On 2026-09-30, an isolated light-appearance macOS UI fixture confirmed the
640-point preferred topic pane, 24-point row spacing, black topic names and
counts even in an inactive window, and inline current payload summaries.
Disclosure controls expanded both nested topic levels successfully.

Accessibility inspection after selecting a value-bearing row crashed in
recursive SwiftUI/AppKit accessibility-label resolution on macOS 27.2 / Xcode
27.2. The same inspection crashed an isolated build of the unchanged original
sidebar implementation, so this is a pre-existing limitation of this check,
not evidence of a layout regression. It remains unresolved; the visual fixture
does not establish selected-row accessibility acceptance.

On 2026-10-03, the package build, macOS Debug build, and unsigned generic iOS
build passed. The package suite had 479 passing tests and eight disabled
Mosquitto integration tests. New regression tests cover fresh connection
workspace records, unchanged broker-list routing, failed saves, shared feeds,
lease release, collapsed-parent activity, identical payloads, and Freeze View.

A separate-bundle preview using in-memory fixture brokers verified Connect,
double-click of the second broker, the persistent broker list, Command-N,
Brokers navigation, and closing one connection while another remains open.
The dense fixture displayed 22-point single-line rows and inline JSON values;
widening the native divider exposed the complete sample payloads. Repeated
synthetic messages visibly highlighted their leaf and both ancestors, including
the collapsed root. Freeze View immediately removed activity highlighting.
Set `JOLLYSMQTT_UI_DENSE_TOPICS=1` and `JOLLYSMQTT_UI_ACTIVITY=1` with
`--ui-testing-connected` to reproduce this local fixture. Its activity task is
bounded and cancelled when its feed releases.

The Xcode UI-test invocation failed before tests executed: the scheme-based run
used the previously documented bare app path; the generated `.xctestrun` had
the correct `.app` path, but its runner was killed before establishing a test
connection. The new window UI tests are checked in but are not recorded as
automatically passed. The native-app checks above used the computer-use tools.
