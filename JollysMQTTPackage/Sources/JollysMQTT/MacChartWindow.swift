#if os(macOS)
  import AppKit
  import JollysMQTTCore
  import JollysMQTTStorage
  import Observation
  import SwiftUI

  /// The dashboard and detached chart windows for one connection borrow that
  /// workspace's dashboard and never acquire another broker-feed lease.
  @MainActor
  @Observable
  final class MacChartWindowController: NSObject, NSWindowDelegate {
    private(set) var detachedCardIDs: Set<NumericChartCardID> = []
    private let dashboard: NumericChartDashboardStore
    private let preferences: BrokerChartPreferencesStore
    @ObservationIgnored private weak var anchor: NSWindow?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var detachedWindows: [NumericChartCardID: NSWindow] = [:]
    @ObservationIgnored private var restoredBrokerID: UUID?
    @ObservationIgnored private var title = ""

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
            .environment(self)
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

    func detach(_ id: NumericChartCardID) {
      if let existing = detachedWindows[id] {
        existing.makeKeyAndOrderFront(nil)
        return
      }
      guard let anchor,
        let card = dashboard.state.cards.first(where: { $0.id == id })
      else { return }
      let chartWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      chartWindow.isReleasedWhenClosed = false
      chartWindow.title = card.chart.series.id.topic
      chartWindow.identifier = NSUserInterfaceItemIdentifier("chart.window.\(id.rawValue)")
      chartWindow.contentMinSize = NSSize(width: 320, height: 320)
      chartWindow.contentView = NSHostingView(
        rootView: MacDetachedChartPane(cardID: id, dashboard: dashboard)
          .environment(self)
      )
      let source = window?.frame ?? anchor.frame
      let offset = CGFloat(detachedWindows.count + 1) * 24
      let frame = Self.initialFrame(
        saved: ChartWindowFrame(
          x: source.minX + offset, y: source.maxY - 420 - offset,
          width: 680, height: 420
        ),
        anchor: source,
        screens: NSScreen.screens.map(\.visibleFrame)
      )
      chartWindow.setFrame(frame, display: false)
      chartWindow.delegate = self
      detachedWindows[id] = chartWindow
      detachedCardIDs.insert(id)
      chartWindow.makeKeyAndOrderFront(nil)
    }

    func returnToDashboard(_ id: NumericChartCardID) {
      closeDetachedWindow(id)
      show()
    }

    /// Removal cancels the existing card store; a detached window must not
    /// retain an empty presentation after that card leaves the dashboard.
    func reconcileDetachedWindows() {
      let currentIDs = Set(dashboard.state.cards.map(\.id))
      for id in detachedCardIDs.subtracting(currentIDs) {
        closeDetachedWindow(id)
      }
    }

    func close() {
      saveFrame()
      for id in Array(detachedWindows.keys) {
        closeDetachedWindow(id)
      }
      window?.close()
      window?.delegate = nil
      window?.contentView = nil
      window = nil
      anchor = nil
      restoredBrokerID = nil
    }

    func windowDidMove(_ notification: Notification) {
      if notification.object as? NSWindow === window { saveFrame() }
    }

    func windowDidResize(_ notification: Notification) {
      if notification.object as? NSWindow === window { saveFrame() }
    }

    func windowWillClose(_ notification: Notification) {
      guard let closing = notification.object as? NSWindow else { return }
      if closing === window {
        saveFrame()
      } else if let id = detachedWindows.first(where: { $0.value === closing })?.key {
        closing.delegate = nil
        closing.contentView = nil
        detachedWindows[id] = nil
        detachedCardIDs.remove(id)
        show(makeKey: false)
      }
    }

    private func closeDetachedWindow(_ id: NumericChartCardID) {
      let detached = detachedWindows.removeValue(forKey: id)
      detached?.delegate = nil
      detached?.close()
      detached?.contentView = nil
      detachedCardIDs.remove(id)
    }

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

  private struct MacDetachedChartPane: View {
    let cardID: NumericChartCardID
    @Bindable var dashboard: NumericChartDashboardStore

    var body: some View {
      ScrollView {
        if let card = dashboard.state.cards.first(where: { $0.id == cardID }) {
          NumericChartCard(card: card, dashboard: dashboard)
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .top)
            .padding(8)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("detached-chart-pane")
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
