---
title: "Adaptive UX and Accessibility Acceptance"
description: "Release evidence and remaining device-only checks for adaptive navigation, localization, accessibility, and in-app help."
area: "ui"
doc_type: "acceptance"
status: "active"
last_reviewed: "2026-08-08"
tags:
  - "accessibility"
  - "adaptive-layout"
  - "localization"
  - "testing"
---

# Adaptive UX and Accessibility Acceptance

This document records the release evidence for the first-pass adaptive
workspace and distinguishes automated or source-audited behavior from checks
that still require physical Apple devices.

## Automated release gates

- Package tests cover the compact and regular presentation policy, restoration
  of all four workspace destinations, completeness of the seven operational
  help concepts, the String Catalog source language and required keys, and
  package-bundle localization usage.
- Storage tests cover destination round trips and default older workspace
  records to Topics when the new field is absent.
- UI tests launch a deterministic anonymous broker fixture. They do not use the
  network, Keychain, CloudKit, a real broker, or real credentials.
- The compact UI test forces the tab presentation at the largest accessibility
  text category and verifies that Topics, Details, Publish, and Charts remain
  independently reachable.
- The regular UI test forces the split presentation and verifies that the topic
  column remains present alongside Details, Publish, and Charts.
- UI tests restore Charts directly, open Help without depending on a keyboard,
  and exercise Command-Return publishing on macOS.
- Broker-list UI tests verify that macOS presents Add Broker as a visible,
  correctly named sidebar action, that Command-Shift-N invokes the same action,
  and that both paths work when the list is empty.
- macOS and generic iOS builds compile the same package UI and String Catalog.

## Keyboard, editing, and alternate input

- Publish topic and payload editing use native `TextField` and `TextEditor`
  controls, preserving the system responder-chain commands for focus,
  selection, copy, paste, and undo.
- The publish action is a semantic `Button` with Command-Return. It remains
  available on screen for touch, Voice Control, Switch Control, and pointer
  users.
- Existing payload copy actions are semantic buttons and retain their explicit
  keyboard shortcuts. No workflow depends on a custom gesture.
- Compact navigation uses the native tab bar; regular navigation uses
  `NavigationSplitView` plus native tabs, so Full Keyboard Access and platform
  focus traversal receive standard control semantics.

## VoiceOver and visual accessibility source audit

- Interactive controls use `Button`, `Toggle`, `Picker`, `TextField`, or
  `TextEditor`; icon-only controls have localized labels.
- Topic rows expose a stable label, value, selected state, and labeled
  expand/collapse action. Structural JSON rows expose their deterministic JSON
  path and value.
- Custom topic disclosure controls and structural JSON rows provide at least a
  44-point interaction height.
- Statuses pair text and symbols with color, so errors, warnings, connection
  state, and activity do not rely on color alone.
- Text uses Dynamic Type styles rather than fixed point sizes. Primary and
  secondary content use semantic foreground styles; platform controls provide
  system contrast and button-shape behavior.
- The only recurring visual effect, the topic activity pulse, is replaced by a
  static symbol when Reduce Motion is enabled. No workflow requires animation.
- Help is globally reachable and explains broad subscriptions, retained
  delivery, background suspension, device-local credentials, overload
  protection, history gaps, and local-only profile behavior.

## Device-only checks still required

Before a public release candidate is signed off on physical hardware, perform
one manual pass on iPhone, iPad, and Mac with:

1. VoiceOver reading order and actions through broker selection, all workspace
   destinations, publish, chart controls, and Help.
2. Voice Control command disambiguation and Switch Control scanning.
3. Full Keyboard Access traversal, including field editing, copy/paste, tab
   changes, disclosure controls, and publish.
4. Accessibility Inspector checks for clipped text, contrast under Increase
   Contrast, Differentiate Without Color, Bold Text, Reduce Transparency, and
   Reduce Motion.
5. Portrait and landscape at the largest accessibility text categories.

CloudKit two-device verification is explicitly deferred because the required
provisioned devices are not currently available. This ticket makes no
two-device synchronization claim; the deterministic UI fixture remains
local-only.
