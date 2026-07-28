---
title: "MQTT Explorer Reference Findings"
description: "Behavioral and product-design findings from the checked-in MQTT Explorer reference, with explicit adaptation and licensing boundaries for JollysMQTT."
area: "product-research"
doc_type: "reference-findings"
status: "active"
last_reviewed: "2026-07-28"
tags:
  - "mqtt"
  - "mqtt-explorer"
  - "swiftui"
  - "product-design"
  - "licensing"
---

# MQTT Explorer Reference Findings

## Review scope

The local reference is the Git submodule at
`Documentation/MQTT-Explorer`, currently at:

- revision `52c576a141d91de47a651f50b118b518f2490bcf`
- authored `2026-07-06`
- upstream mirror `gitmaster.jinx.eu:jnxpublic/MQTT-Explorer.git`
- package version `0.4.0-beta.5`

The review covered the connection editor, topic-tree model and rendering,
search, payload details, history and diff behavior, publishing, chart state and
settings, responsive layout, screenshots, and UI scenario tests.

This is a behavioral reference, not an implementation dependency. JollysMQTT
must implement the useful workflows independently in Swift and SwiftUI.

## Product behaviors worth preserving

### 1. The outline carries useful live context

MQTT Explorer presents more than a topic segment:

- collapsed branches show descendant topic and message counts,
- leaf and parent topics can show an inline current value after `=`,
- JSON is formatted for display and long inline values are truncated,
- updates can briefly highlight the changed row,
- nodes preserve independent expansion and selection state,
- keyboard arrows traverse the visible hierarchy.

JollysMQTT should preserve these information-dense behaviors while using native
row styling, semantic colors, Dynamic Type, and stable topic identities.

The reference can order siblings by:

- broker/discovery order,
- alphabetical topic name,
- descending descendant message count, or
- descending descendant topic count.

JollysMQTT should expose the same useful sort concepts, with alphabetical as the
predictable default. Sorting is presentation state and must not alter topic
identity.

### 2. Search includes topic and current value

The reference search is designed to match:

- the exact full topic path, or
- the current decoded payload text.

Results retain the ancestor chain needed to understand their position and
auto-expand to expose matches. Incoming messages continue to be tested against
the active filter.

For JollysMQTT, apply consistent case and diacritic folding to both fields and
use the latest indexed payload summary rather than scan all durable history.
Search results must preserve exact topic paths, including empty MQTT levels.
Debounce search input and prepare filtered snapshots outside SwiftUI `body`.

### 3. `$SYS` requires an explicit subscription

The reference defaults to both:

- `#` at QoS 0, and
- `$SYS/#` at QoS 0.

This matters because an MQTT wildcard filter beginning with `#` or `+` does not
match topics whose first level starts with `$`. JollysMQTT should therefore
offer both filters in a new profile by default, with a warning that broad
subscriptions can be expensive and with either filter removable before
connecting.

### 4. Pausing the tree is a presentation operation

MQTT Explorer can freeze tree updates while buffering incoming changes. It
shows the pending change count and applies the buffered state when resumed.

JollysMQTT should provide a clearer native version named **Freeze View**:

- the broker feed, counters, bounded history, and database continue ingesting,
- the workspace retains its current outline snapshot,
- the toolbar shows a bounded pending-change count,
- **Jump to Live** obtains a fresh coalesced snapshot rather than replaying
  thousands of row mutations through SwiftUI,
- buffer pressure cannot grow without bound.

This is distinct from disconnecting and from pausing one graph.

### 5. Details distinguish value, metadata, and actions

The selected-topic view provides:

- breadcrumb/full-topic display,
- copy topic,
- current local receive time,
- QoS and retained flag,
- current value,
- copy decoded value,
- save raw payload to a file,
- retained-value deletion,
- per-topic message/subtopic totals,
- history and diff.

JollysMQTT should retain this hierarchy, while also exposing direction and
payload byte count. The retained flag must be described as packet metadata:
the broker commonly sets it for retained delivery to a new subscription, not
as a durable proof that every live message remains stored.

### 6. Diff has a simple baseline rule

The reference defaults to comparing the current value with the immediately
previous message. Selecting an older history entry changes the baseline;
selecting it again clears that override.

JollysMQTT should use the same rule:

1. no explicit selection: current versus immediately previous,
2. selected history entry: current versus selected,
3. activate the selected entry again: clear the selection,
4. raw mode: show current and selected values without a synthetic diff.

History rows should include receive time, elapsed time from the newer message,
QoS/retain/direction where space permits, and a row-level copy action.

### 7. Publishing is integrated with selection

Selecting a topic pre-fills the publish topic unless the user has deliberately
edited it. The reference provides:

- topic input,
- raw, JSON, and XML editor modes,
- JSON format/validation,
- file import,
- QoS 0/1/2,
- retain on/off,
- `Command-Return`/`Control-Return`,
- a short deduplicated publish history that can repopulate the editor.

For JollysMQTT v1:

- use text, JSON, and hex modes; XML needs no special mode,
- keep a workspace-local publish draft,
- preserve a bounded, deduplicated successful-publish history,
- add history only after mqtt-nio reports publish success,
- let standard Paste and Paste and Match Style work in the focused editor,
- never overwrite a manually edited topic when outline selection changes.

The retained-delete workflow must remain explicit. Recursive deletion should
operate only on locally known value-bearing topics in the selected subtree,
confirm the exact count, publish zero-byte retained messages, and report
partial failures rather than pretending the whole operation succeeded. The UI
must say that this attempts to clear broker-retained state; received retain
flags alone are not a complete retained-message inventory.

### 8. Numeric JSON leaves can become independent charts

The reference can plot:

- a numeric scalar payload, or
- a numeric property inside a JSON payload, identified by a property path.

Clicking the chart affordance pins a card without replacing the outline.
Multiple cards can coexist. Each card supports:

- Pause/Resume,
- Y-axis fixed or automatic range,
- time range including a custom duration,
- curve interpolation,
- automatic, full, half, or third width,
- color,
- clear displayed samples,
- move earlier,
- remove.

JollysMQTT should retain those controls in native terminology:

- line, point, and step presentation rather than reproducing library-specific
  curve names,
- adaptive grid span rather than percentage widths,
- drag reorder on touch platforms and keyboard/menu reorder everywhere,
- a safe color palette with system-default as an option,
- clear graph samples without clearing topic history,
- per-card pause that freezes that card while ingestion continues.

Card order, span, pause state, axis policy, time range, style, and color belong
to the workspace record. Data is rebuilt from local history after restoration.

### 9. Compact UI is four functional destinations

The newer mobile source separates:

1. Topics,
2. Details,
3. Publish,
4. Charts.

This is a better basis for JollysMQTT on iPhone than compressing a desktop split
view. Use a native `TabView` or an equivalent accessible compact navigation
model. Keep destination state alive while switching, return to the selected
topic when navigating back to Topics, and move to Details after a user selects
a leaf or value-bearing topic. iPad can graduate to `NavigationSplitView` while
retaining explicit access to Publish and Charts.

### 10. Connection profiles have a progressive editor

The reference separates common connection fields from advanced settings:

- display name, host, port, username, password, encryption,
- transport and WebSocket base path,
- subscription filters and requested QoS,
- client ID,
- CA, client certificate, and client key.

For JollysMQTT, the progressive layout is useful, but v1 remains intentionally
narrower:

- TCP and system-trust TLS,
- username and device-local Keychain password,
- client ID policy, clean session, keepalive, reconnect, subscriptions,
- WebSocket, custom CA, and client identity deferred.

The broker list should show display name plus a secondary endpoint, support
keyboard selection, and make Connect a clear primary action. Destructive delete
requires confirmation.

## Useful implementation ideas, adapted rather than copied

### Coalesced rendering

The reference buffers messages, merges them on a roughly 300 ms cadence, and
stages large child lists during idle periods. This validates the need for the
existing JollysMQTT split between loss-aware ingestion and coalesced
presentation. JollysMQTT should use actors and immutable snapshots rather than
timers embedded in views.

### Bounded memory

The reference history and chart buffers are bounded by both count and byte
capacity. JollysMQTT should preserve the dual-limit principle even though its
durable limits are larger and enforced by a storage actor.

### Stable chart identity

The reference identifies a chart by topic plus optional JSON property path.
JollysMQTT must additionally include broker/profile identity so two brokers
with the same topic cannot collide.

### Scenario-shaped UI tests

The checked-in scenarios cover connect, reconnect, topic expansion, search,
JSON preview, diff/raw switching, copy topic/value, publish, retained deletion,
advanced subscriptions, and numeric chart settings. These should inform
JollysMQTT's UI-test vocabulary and deterministic Mosquitto fixtures.

## Deliberate differences

- JollysMQTT is native SwiftUI, not Electron/React.
- History is durable and queryable, not only an in-memory ring.
- Secrets are Keychain records and never part of serialized profile objects.
- Broker definitions sync through iCloud; workspace/history data remains local.
- Multiple native windows have independent workspace state and can share one
  actor-owned broker feed.
- Transport is mqtt-nio v3 over Apple Transport Services, not MQTT.js.
- Payload support starts with text, JSON, and hex; Sparkplug B, XML-specific
  editing, WebSockets, custom CAs, and client certificates are deferred.
- Search and outline updates use indexed snapshots; they do not clone and
  rebuild a mutable UI tree for each query.
- Resume from Freeze View jumps to a current snapshot instead of replaying
  every buffered presentation mutation.

## Licensing boundary

The reference contains conflicting license signals:

- `package.json` declares `CC-BY-SA-4.0`,
- `LICENSE.md` contains Creative Commons Attribution-NoDerivatives 4.0 text and
  an additional attribution/donation-page condition.

Until ownership and applicable terms are clarified:

- do not copy source, text, icons, screenshots, styles, or other assets into
  JollysMQTT,
- do not translate reference components line-for-line into Swift,
- use the checkout only to identify behavior and interoperability
  expectations,
- implement JollysMQTT from its own plan, domain model, tests, and native Apple
  design principles,
- include attribution only if reference material is ever intentionally shipped,
  after a separate license review.

## Resulting plan changes

The implementation plan now explicitly includes:

- default `#` and `$SYS/#` subscription filters,
- topic and current-payload search,
- outline sort modes,
- Freeze View and Jump to Live,
- a defined history comparison baseline,
- successful-publish draft history,
- partial-failure-safe recursive retained deletion,
- complete persisted chart-card settings,
- compact Topics/Details/Publish/Charts destinations,
- UI tests corresponding to the reference's core scenarios,
- a strict no-copy boundary for the reference checkout.
