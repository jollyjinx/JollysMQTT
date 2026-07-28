import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@Suite("SQLite broker history writer")
struct SQLiteBrokerHistoryWriterTests {
  @Test("A feed batch persists its live identity and order")
  func persistsFeedBatch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "history.sqlite3")
    let writer = SQLiteBrokerHistoryWriter(databaseURL: databaseURL)
    let epoch = ConnectionEpochID()

    try await writer.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 1,
        topic: "events",
        payload: Data([1]),
        receivedAtMicroseconds: 10
      ),
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 2,
        topic: "events",
        payload: Data([2]),
        receivedAtMicroseconds: 10
      ),
    ])
    try await writer.shutdown()

    let store = try await SQLiteHistoryStore.open(
      databaseURL: databaseURL
    )
    let messages = try await store.newestMessages(
      historySourceID: "source-a",
      topic: "events",
      limit: 10
    )
    #expect(messages.map(\.payload) == [Data([2]), Data([1])])
    #expect(messages.map(\.connectionEpoch) == [epoch.rawValue, epoch.rawValue])
    #expect(messages.map(\.connectionOrdinal) == [2, 1])
  }
}
