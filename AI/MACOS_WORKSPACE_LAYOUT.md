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

The primary layout is a native adjustable `HSplitView`. Topics stay visible
and take the full window width when the trailing Details/Publish pane is hidden.
The toolbar’s Hide Details / Show Details control (Option-Command-S) controls
that trailing pane. Topics have a 320-point minimum and 640-point ideal width;
details have a 360-point minimum and 440-point ideal width.

Charts live in a separate, independently movable and resizable macOS window.
Pinning opens it, and the Charts toolbar button reopens a manually closed chart
window. Initial placement is immediately to the right of its server window,
top-aligned when space permits. Saved geometry is clamped to an available screen
if a display was removed. Closing charts leaves the server connection running;
closing the server closes its companion and flushes its chart preferences.

Each connection keeps its own dashboard stores and borrows its existing feed;
the chart window does not acquire another lease. Card edits and window geometry
are saved per broker in local `broker-charts/<broker UUID>.json` records, outside
the seven-day closed-workspace pruning policy. Future connections seed their
cards and geometry from that record, including card order, JSON paths, settings,
pause state, and clear boundaries. Concurrent connection windows keep independent
live presentation; the latest card edit supplies the next connection’s defaults.
Geometry-only changes do not overwrite card edits from another window. An
explicitly empty saved dashboard overrides stale cards in an old workspace.
Existing workspace charts migrate on first restoration when no broker record
exists. These preferences are device-local and never synchronized via CloudKit.

iPhone/iPad retain their adaptive in-scene chart destinations. Selecting a JSON
leaf remains stable across same-topic updates while that path still exists. Copy
and Pin to Chart evaluate the newly inspected value at that path. A removed path
falls back to the root; a nonnumeric replacement disables chart pinning.

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

Clicking or tapping a topic's name, value, or remaining row content selects it
and toggles its children just like its disclosure triangle, including when the
topic is already selected. The disclosure triangle remains a separate expansion
action, so one click never toggles twice. Leaf topics only select their value;
search-forced expansion keeps the existing disclosure rules.

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

History is a native disclosure section, collapsed by default in each workspace
on every platform. Expanding it loads the latest selected topic's history page
and enables payload comparisons. Collapsing cancels page/comparison tasks,
invalidates their pending results, and releases the displayed history state.
While collapsed, the store retains only the latest context without observable
state updates, database queries, or diff generation; reopening starts at the
latest page. This controls history browsing only: broker ingestion, durable
message recording, retention, and independent chart cards keep running.

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
- Hide Details leaves Topics visible; Show Details restores the trailing pane.
- Pinning opens a separate chart window. Its cards and geometry return on a
  later connection to that broker, including after a process restart.
- Selecting another topic does not replace existing chart cards, and live JSON
  updates preserve the selected leaf while that path exists.
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


The later 2026-10-03 chart-window change passed the package build and full suite
(485 passed, eight opt-in Mosquitto tests skipped), macOS Debug build including
the UI-test target, and unsigned generic iOS build. Regression tests cover live
JSON leaf selection, new connections restoring persisted chart settings and
geometry, explicit removal of the last chart, per-broker isolation, partial
frame updates, unreadable preference preservation, and off-screen recovery.

An isolated `JollysMQTT Charts Preview` fixture verified Hide Details / Show
Details while Topics stayed visible, an independent empty chart window, and
closing that chart window without losing the server. A selected `/temperature`
leaf kept Pin to Chart visible through incoming messages (including identical
payloads). Pinning then persisted the expected topic and JSON path. The native
UI automation helper disconnected immediately after pinning and could not be
reconnected; the preview process remained alive. Consequently manual dragging
and subsequent connection restoration were not visually verified in this run;
those persistence and geometry paths are covered by package tests. UI tests
were compiled but not executed. `JOLLYSMQTT_UI_PREVIEW=brokers` (Debug only) and
`JOLLYSMQTT_UI_CHART_DIRECTORY` support isolated persistence verification without
real brokers or credentials.
