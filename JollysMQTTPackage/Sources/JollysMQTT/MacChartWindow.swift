#if os(macOS)
  import AppKit
  import JollysMQTTStorage
  import SwiftUI

  /// One independently movable companion per connection. It borrows that
  /// workspace's dashboard and never acquires another broker-feed lease.
  @MainActor
  final class MacChartWindowController: NSObject, NSWindowDelegate {
    private let dashboard: NumericChartDashboardStore
    private let preferences: BrokerChartPreferencesStore
    private weak var anchor: NSWindow?
    private var window: NSWindow?
    private var restoredBrokerID: UUID?
    private var title = ""

    init(dashboard: NumericChartDashboardStore, preferences: BrokerChartPreferencesStore) {
      self.dashboard = dashboard
      self.preferences = preferences
    }

    func attach(to anchor: NSWindow, title: String) {
      self.anchor = anchor
      self.title = title
      window?.title = title
      guard preferences.isLoaded,
        let brokerID = preferences.brokerID,
        restoredBrokerID != brokerID
      else { return }
      restoredBrokerID = brokerID
      if !dashboard.state.cards.isEmpty { show(makeKey: false) }
    }

    func show(makeKey: Bool = true) {
      guard let anchor else { return }
      let chartWindow: NSWindow
      if let window {
        chartWindow = window
      } else {
        chartWindow = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
          styleMask: [.titled, .closable, .miniaturizable, .resizable],
          backing: .buffered,
          defer: false
        )
        chartWindow.isReleasedWhenClosed = false
        chartWindow.title = title
        chartWindow.identifier = NSUserInterfaceItemIdentifier("workspace.charts.window")
        chartWindow.contentMinSize = NSSize(width: 320, height: 320)
        chartWindow.contentView = NSHostingView(
          rootView: NumericChartDashboardPane(dashboard: dashboard, layout: .wide)
        )
        let frame = Self.initialFrame(
          saved: preferences.windowFrame,
          anchor: anchor.frame,
          screens: NSScreen.screens.map(\.visibleFrame)
        )
        chartWindow.setFrame(frame, display: false)
        chartWindow.delegate = self
        window = chartWindow
      }
      if makeKey {
        chartWindow.makeKeyAndOrderFront(nil)
      } else {
        chartWindow.orderFront(nil)
      }
      saveFrame()
    }

    func close() {
      saveFrame()
      window?.close()
      window?.delegate = nil
      window = nil
      anchor = nil
      restoredBrokerID = nil
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowWillClose(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
      guard let frame = window?.frame else { return }
      preferences.saveWindowFrame(
        ChartWindowFrame(
          x: frame.minX, y: frame.minY, width: frame.width, height: frame.height
        )
      )
    }

    /// Prefer the right-hand display for first presentation. Clamp restored
    /// frames when a display was disconnected so the title bar stays reachable.
    static func initialFrame(
      saved: ChartWindowFrame?, anchor: NSRect, screens: [NSRect]
    ) -> NSRect {
      let proposed: NSRect
      if let saved, saved.isValid {
        proposed = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
      } else {
        proposed = NSRect(x: anchor.maxX + 12, y: anchor.maxY - 700, width: 680, height: 700)
      }
      guard let screen = screens.max(by: {
        intersectionArea($0, proposed) < intersectionArea($1, proposed)
      }) else { return proposed }
      let target = intersectionArea(screen, proposed) > 0 ? screen
        : screens.max(by: { intersectionArea($0, anchor) < intersectionArea($1, anchor) })!
      let width = min(proposed.width, target.width)
      let height = min(proposed.height, target.height)
      return NSRect(
        x: min(max(proposed.minX, target.minX), target.maxX - width),
        y: min(max(proposed.minY, target.minY), target.maxY - height),
        width: width, height: height
      )
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> Double {
      let intersection = lhs.intersection(rhs)
      return intersection.isNull ? 0 : intersection.width * intersection.height
    }
  }

  struct MacChartWindowAnchor: NSViewRepresentable {
    let controller: MacChartWindowController
    let title: String
    let isReady: Bool

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
      view.controller = controller
      view.chartTitle = title
      view.attach()
    }

    final class AnchorView: NSView {
      weak var controller: MacChartWindowController?
      var chartTitle = ""

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
      }

      func attach() {
        // Window creation can change observable frame preferences. Defer it
        // past the representable update to avoid mutating state during render.
        Task { @MainActor [weak self] in
          guard let self, let window else { return }
          controller?.attach(to: window, title: chartTitle)
        }
      }
    }
  }
#endif
