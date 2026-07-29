import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@Suite("SQLite broker history writer")
struct SQLiteBrokerHistoryWriterTests {
  @Test("Concurrent windows receive the exact same repository actor")
  func poolSharesRepositoryActor() async {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    let pool = SQLiteBrokerHistoryRepositoryPool(
      directoryURL: directory
    )
    let brokerID = UUID()

    async let first = pool.repository(for: brokerID)
    async let second = pool.repository(for: brokerID)
    let pair = await (first, second)
    let other = pool.repository(for: UUID())

    #expect(pair.0 === pair.1)
    #expect(pair.0 !== other)
  }

  @Test("History pages use durable order and an exclusive cursor")
  func pagesUseDurableOrderAndExclusiveCursor() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3")
    )
    let epoch = ConnectionEpochID()
    try await repository.append(
      (1...5).map {
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: UInt64($0),
          topic: "events",
          payload: Data([$0]),
          receivedAtMicroseconds: 10
        )
      }
    )

    let first = try await repository.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        limit: 2
      )
    )
    let firstCursor = try #require(first.nextCursor)
    let second = try await repository.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        beforeDurableOrder: firstCursor,
        limit: 2
      )
    )
    let secondCursor = try #require(second.nextCursor)
    let final = try await repository.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        beforeDurableOrder: secondCursor,
        limit: 2
      )
    )

    #expect(first.messages.map(\.payload) == [Data([5]), Data([4])])
    #expect(second.messages.map(\.payload) == [Data([3]), Data([2])])
    #expect(final.messages.map(\.payload) == [Data([1])])
    #expect(firstCursor == first.messages.last?.durableOrder)
    #expect(second.messages.map(\.durableOrder).allSatisfy { $0 < firstCursor })
    #expect(final.nextCursor == nil)
  }

  @Test("A page isolates source and topic and bounds source-wide coverage gaps")
  func pageIsolationAndBoundedGaps() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3")
    )
    let epoch = ConnectionEpochID()
    try await repository.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 1,
        topic: "wanted",
        payload: Data([0xA1]),
        receivedAtMicroseconds: 100
      ),
      BrokerHistoryMessage(
        historySourceID: "source-b",
        connectionEpoch: epoch,
        ordinal: 2,
        topic: "wanted",
        payload: Data([0xB1]),
        receivedAtMicroseconds: 100
      ),
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 3,
        topic: "other",
        payload: Data([0xA2]),
        receivedAtMicroseconds: 100
      ),
    ])
    for offset in 0..<3 {
      try await repository.recordCoverageGap(
        BrokerHistoryCoverageGap(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          startedAtMicroseconds: Int64(90 + offset),
          endedAtMicroseconds: 110,
          minimumMissingMessageCount: 1,
          reason: .storageFailure,
          isOpenEnded: false
        )
      )
    }
    try await repository.recordCoverageGap(
      BrokerHistoryCoverageGap(
        historySourceID: "source-b",
        connectionEpoch: epoch,
        startedAtMicroseconds: 90,
        endedAtMicroseconds: 110,
        minimumMissingMessageCount: 1,
        reason: .localOverload,
        isOpenEnded: false
      )
    )

    let page = try await repository.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "wanted",
        limit: 10,
        coverageGapLimit: 2
      )
    )

    #expect(page.messages.map(\.payload) == [Data([0xA1])])
    #expect(page.coverageGaps.count == 2)
    #expect(page.coverageGaps.allSatisfy { $0.historySourceID == "source-a" })
  }

  @Test("A checkpointed repository lazily reopens for a later feed generation")
  func repositoryReopensAfterShutdown() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3")
    )
    let epoch = ConnectionEpochID()
    try await repository.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 1,
        topic: "events",
        payload: Data([1]),
        receivedAtMicroseconds: 1
      )
    ])
    try await repository.shutdown()
    try await repository.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 2,
        topic: "events",
        payload: Data([2]),
        receivedAtMicroseconds: 2
      )
    ])

    let page = try await repository.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        limit: 10
      )
    )

    #expect(page.messages.map(\.payload) == [Data([2]), Data([1])])
  }

  @Test("A shutdown policy error cannot brick later repository operations")
  func shutdownErrorDoesNotBrickRepository() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let policy = FailingOnceHistoryFilePolicy()
    let repository = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3"),
      filePolicy: policy
    )
    let epoch = ConnectionEpochID()
    try await repository.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 1,
        topic: "events",
        payload: Data([1]),
        receivedAtMicroseconds: 1
      )
    ])
    await policy.failNextApplication()

    await #expect(throws: FailingOnceHistoryFilePolicy.Failure.self) {
      try await repository.shutdown()
    }
    let page = try await withThrowingTaskGroup(
      of: HistoryPage.self
    ) { group in
      group.addTask {
        try await repository.page(
          HistoryPageRequest(
            historySourceID: "source-a",
            topic: "events",
            limit: 10
          )
        )
      }
      group.addTask {
        try await Task.sleep(for: .seconds(1))
        throw RepositoryTimeout()
      }
      let first = try #require(await group.next())
      group.cancelAll()
      return first
    }
    #expect(page.messages.map(\.payload) == [Data([1])])
  }

  @Test("A directory creation error cannot wedge repository acquisition")
  func directoryCreationErrorDoesNotWedgeRepository() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .notDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(
      FileManager.default.createFile(
        atPath: directory.path,
        contents: Data([0])
      )
    )
    let repository = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3")
    )
    let message = BrokerHistoryMessage(
      historySourceID: "source-a",
      connectionEpoch: ConnectionEpochID(),
      ordinal: 1,
      topic: "events",
      payload: Data([1]),
      receivedAtMicroseconds: 1
    )

    await #expect(throws: (any Error).self) {
      try await repository.append([message])
    }
    await #expect(throws: (any Error).self) {
      try await repository.append([message])
    }
  }

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

  @Test("The feed writer durably exposes coverage gaps")
  func persistsCoverageGap() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "history.sqlite3")
    let writer = SQLiteBrokerHistoryWriter(databaseURL: databaseURL)
    let epoch = ConnectionEpochID()
    let gap = BrokerHistoryCoverageGap(
      historySourceID: "source-a",
      connectionEpoch: epoch,
      startedAtMicroseconds: 10,
      endedAtMicroseconds: 20,
      minimumMissingMessageCount: 4,
      reason: .storageFailure,
      isOpenEnded: false
    )

    try await writer.recordCoverageGap(gap)
    try await writer.shutdown()

    let store = try await SQLiteHistoryStore.open(databaseURL: databaseURL)
    let stored = try #require(
      try await store.coverageGaps(historySourceID: "source-a").first
    )
    #expect(stored.connectionEpoch == epoch.rawValue)
    #expect(stored.startedAtMicroseconds == 10)
    #expect(stored.endedAtMicroseconds == 20)
    #expect(stored.minimumMissingMessageCount == 4)
    #expect(stored.reason == .storageFailure)
    #expect(stored.isOpenEnded == false)
  }
}

private struct RepositoryTimeout: Error {}

private actor FailingOnceHistoryFilePolicy: HistoryFilePolicy {
  struct Failure: Error {}
  private var shouldFail = false

  func failNextApplication() {
    shouldFail = true
  }

  func apply(to url: URL, role: HistoryFileRole) throws {
    if shouldFail {
      shouldFail = false
      throw Failure()
    }
  }
}
