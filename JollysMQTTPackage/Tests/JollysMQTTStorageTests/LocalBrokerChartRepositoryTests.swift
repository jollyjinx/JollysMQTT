import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@Suite("Broker chart preferences")
struct LocalBrokerChartRepositoryTests {
  @Test("Per-broker preferences survive relaunch and partial updates preserve unrelated settings")
  func partialUpdatesAndIsolation() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = LocalBrokerChartRepository(directoryURL: directory)
    let brokerID = UUID()
    let otherBrokerID = UUID()
    let card = NumericChartCardConfiguration(chart: .init(series: .init(
      id: .init(brokerID: brokerID, topic: "sensor/value"),
      conversion: .init(kind: .number)
    )))
    let dashboard = NumericChartDashboardConfiguration(cards: [card])
    let frame = ChartWindowFrame(x: -900, y: 80, width: 680, height: 700)
    try await repository.update(brokerID: brokerID, dashboard: dashboard, windowFrame: nil)
    try await repository.update(brokerID: brokerID, dashboard: nil, windowFrame: frame)
    let reopened = LocalBrokerChartRepository(directoryURL: directory)
    #expect(try await reopened.load(brokerID: brokerID) == .init(dashboard: dashboard, windowFrame: frame))
    #expect(try await reopened.load(brokerID: otherBrokerID) == nil)
    try await reopened.update(brokerID: brokerID, dashboard: .init(), windowFrame: nil)
    #expect(try await reopened.load(brokerID: brokerID) == .init(windowFrame: frame))
  }

  @Test("Unknown versions and corrupt chart preferences remain untouched")
  func preservesUnreadablePreferences() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = LocalBrokerChartRepository(directoryURL: directory)
    for contents in [#"{"version":999}"#, "broken"] {
      let brokerID = UUID()
      let file = directory.appending(path: "\(brokerID.uuidString.lowercased()).json")
      let data = Data(contents.utf8)
      try data.write(to: file)
      await #expect(throws: (any Error).self) { try await repository.load(brokerID: brokerID) }
      await #expect(throws: (any Error).self) {
        try await repository.update(brokerID: brokerID, dashboard: .init(), windowFrame: nil)
      }
      #expect(try Data(contentsOf: file) == data)
    }
  }
}
