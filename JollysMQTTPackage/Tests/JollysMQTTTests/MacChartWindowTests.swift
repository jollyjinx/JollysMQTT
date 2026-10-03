#if os(macOS)
  import AppKit
  import JollysMQTTCore
  import JollysMQTTStorage
  import Testing
  @testable import JollysMQTT

  @Suite("Chart window placement")
  @MainActor
  struct MacChartWindowTests {
    @Test("New charts open immediately right of their server when space is available")
    func rightHandPlacement() {
      let anchor = NSRect(x: 100, y: 100, width: 900, height: 800)
      let result = MacChartWindowController.initialFrame(
        saved: nil, anchor: anchor, screens: [NSRect(x: 0, y: 0, width: 2560, height: 1440)]
      )
      #expect(result.minX == anchor.maxX + 12)
      #expect(result.maxY == anchor.maxY)
    }

    @Test("Restored geometry keeps another display's position and recovers from a removed display")
    func restoresAndClamps() {
      let anchor = NSRect(x: 100, y: 100, width: 900, height: 800)
      let main = NSRect(x: 0, y: 0, width: 1440, height: 1000)
      let left = NSRect(x: -1440, y: 0, width: 1440, height: 1000)
      let saved = ChartWindowFrame(x: -1300, y: 80, width: 700, height: 800)
      let result = MacChartWindowController.initialFrame(saved: saved, anchor: anchor, screens: [main, left])
      #expect(result == NSRect(x: -1300, y: 80, width: 700, height: 800))
      let recovered = MacChartWindowController.initialFrame(saved: saved, anchor: anchor, screens: [main])
      #expect(main.contains(recovered))
    }

    @Test("Detaching and closing a chart preserves its identity, settings, and store")
    func detachedChartReturnsToDashboard() throws {
      _ = NSApplication.shared
      let dashboard = NumericChartDashboardStore()
      let series = NumericChartSeries(
        id: NumericChartSeriesID(brokerID: UUID(), topic: "fixture/value"),
        conversion: NumericChartValueConversion(kind: .number)
      )
      let id = NumericChartCardID()
      #expect(dashboard.pin(series, id: id))
      let store = try #require(dashboard.cardStore(for: id))
      let preferences = BrokerChartPreferencesStore(repository: MemoryBrokerChartRepository())
      let controller = MacChartWindowController(dashboard: dashboard, preferences: preferences)
      let anchor = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false
      )
      anchor.isReleasedWhenClosed = false
      controller.attach(to: anchor, title: "Fixture Charts")
      defer {
        controller.close()
        anchor.close()
      }

      controller.detach(id)
      let identifier = NSUserInterfaceItemIdentifier("chart.window.\(id.rawValue)")
      let detached = try #require(NSApp.windows.first { $0.identifier == identifier })
      #expect(controller.detachedCardIDs == [id])
      #expect(dashboard.cardStore(for: id) === store)
      #expect(dashboard.state.cards.map(\.id) == [id])

      controller.detach(id)
      #expect(NSApp.windows.filter { $0.identifier == identifier }.count == 1)
      store.send(.setPaused(true))
      controller.returnToDashboard(id)
      #expect(controller.detachedCardIDs.isEmpty)
      #expect(!detached.isVisible)
      #expect(detached.contentView == nil)

      controller.detach(id)
      let reopened = try #require(NSApp.windows.first {
        $0.identifier == identifier && $0.isVisible
      })
      reopened.close()

      #expect(controller.detachedCardIDs.isEmpty)
      #expect(dashboard.cardStore(for: id) === store)
      #expect(dashboard.state.cards.first?.chart.isPaused == true)
      #expect(!reopened.isVisible)
      #expect(reopened.contentView == nil)
    }

    @Test("Removing a detached card and closing its workspace close the corresponding windows")
    func detachedWindowsFollowCardAndWorkspaceLifetime() throws {
      _ = NSApplication.shared
      let dashboard = NumericChartDashboardStore()
      let series = NumericChartSeries(
        id: NumericChartSeriesID(brokerID: UUID(), topic: "fixture/value"),
        conversion: NumericChartValueConversion(kind: .number)
      )
      let firstID = NumericChartCardID()
      let secondID = NumericChartCardID()
      #expect(dashboard.pin(series, id: firstID))
      #expect(dashboard.pin(series, id: secondID))
      let controller = MacChartWindowController(
        dashboard: dashboard,
        preferences: BrokerChartPreferencesStore(repository: MemoryBrokerChartRepository())
      )
      let anchor = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false
      )
      anchor.isReleasedWhenClosed = false
      controller.attach(to: anchor, title: "Fixture Charts")
      defer {
        controller.close()
        anchor.close()
      }
      controller.detach(firstID)
      controller.detach(secondID)
      let first = try #require(NSApp.windows.first {
        $0.identifier?.rawValue == "chart.window.\(firstID.rawValue)"
      })
      let second = try #require(NSApp.windows.first {
        $0.identifier?.rawValue == "chart.window.\(secondID.rawValue)"
      })

      dashboard.send(.remove(firstID))
      controller.reconcileDetachedWindows()
      #expect(!first.isVisible)
      #expect(first.contentView == nil)
      #expect(second.isVisible)
      #expect(controller.detachedCardIDs == [secondID])
      #expect(dashboard.cardStore(for: firstID) == nil)

      controller.close()
      #expect(!second.isVisible)
      #expect(second.contentView == nil)
      #expect(controller.detachedCardIDs.isEmpty)
      #expect(dashboard.state.cards.map(\.id) == [secondID])
    }
  }
#endif
