#if os(macOS)
  import AppKit
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
  }
#endif
