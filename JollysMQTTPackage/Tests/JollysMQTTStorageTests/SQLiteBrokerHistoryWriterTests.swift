import Foundation
import JollysMQTTCore
import Synchronization
import Testing

@testable import JollysMQTTStorage

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

  @Test("The smallest valid prune batch still converges after a full ingestion batch")
  func tinyPruneBatchConverges() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let policy = try HistoryRetentionPolicy(
      topicMessageLimit: 2,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 1,
      vacuumPageLimit: 1
    )
    let writer = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3"),
      retentionPolicy: policy
    )
    let epoch = ConnectionEpochID()

    try await writer.append(
      (1...128).map {
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: UInt64($0),
          topic: "busy",
          payload: Data([$0]),
          receivedAtMicroseconds: Int64($0)
        )
      }
    )

    let page = try await writer.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "busy",
        limit: 10
      )
    )
    #expect(page.messages.map(\.payload) == [Data([128]), Data([127])])
    guard case .succeeded(let report) = await writer.maintenanceStatus() else {
      Issue.record("Maintenance did not report successful convergence.")
      return
    }
    #expect(report.deletedForTopicLimit == 126)
    #expect(report.finalMessageCount == 2)
  }

  @Test("A later invalid message prevents every row in the append batch from committing")
  func validatesWholeBatchBeforeCommit() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3")
    )
    let epoch = ConnectionEpochID()

    await #expect(
      throws:
        HistoryStorageError.invalidMessage(
          index: 1,
          reason: .emptyTopic
        )
    ) {
      try await writer.append([
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: 1,
          topic: "valid",
          payload: Data([1]),
          receivedAtMicroseconds: 1
        ),
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: 2,
          topic: "",
          payload: Data([2]),
          receivedAtMicroseconds: 2
        ),
      ])
    }

    let page = try await writer.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "valid",
        limit: 10
      )
    )
    #expect(page.messages.isEmpty)
  }

  @Test("Payloads beyond the configured history limit retain honest metadata")
  func oversizedPayloadUsesMetadataOnlyHistory() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let policy = try HistoryRetentionPolicy(
      topicMessageLimit: 10,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 4,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    let writer = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3"),
      retentionPolicy: policy
    )
    let epoch = ConnectionEpochID()

    try await writer.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 1,
        topic: "events",
        payload: Data([1, 2, 3]),
        receivedAtMicroseconds: 1
      ),
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 2,
        topic: "events",
        payload: Data([1, 2, 3, 4, 5]),
        receivedAtMicroseconds: 2
      ),
    ])

    let page = try await writer.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        limit: 10
      )
    )
    let omitted = try #require(page.messages.first)
    #expect(omitted.payload.isEmpty)
    #expect(
      omitted.payloadStorage
        == .omittedByRetentionLimit(originalByteCount: 5)
    )
    #expect(omitted.originalPayloadByteCount == 5)
    #expect(page.messages.last?.payload == Data([1, 2, 3]))
    #expect(page.messages.last?.payloadStorage == .stored)
  }

  @Test("A lowered live policy keeps newest payloads without a false gap")
  func loweredPolicyKeepsNewestPayloadDeterministically() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let larger = try HistoryRetentionPolicy(
      topicMessageLimit: 10,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024 * 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    let smaller = try HistoryRetentionPolicy(
      topicMessageLimit: 10,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1_024 * 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    let policies = Mutex(larger)
    let writer = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3"),
      retentionPolicyProvider: {
        policies.withLock { $0 }
      }
    )
    let epoch = ConnectionEpochID()
    let olderPayload = Data(repeating: 0xA1, count: 1_024 * 1_024)
    let newerPayload = Data(repeating: 0xA2, count: 1_024 * 1_024)
    policies.withLock { $0 = smaller }

    try await writer.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 1,
        topic: "events",
        payload: olderPayload,
        receivedAtMicroseconds: 1
      ),
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 2,
        topic: "events",
        payload: newerPayload,
        receivedAtMicroseconds: 2
      ),
    ])

    let page = try await writer.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        limit: 10
      )
    )
    #expect(page.messages.count == 2)
    #expect(page.messages[0].payload == newerPayload)
    #expect(page.messages[0].payloadStorage == .stored)
    #expect(page.messages[1].payload.isEmpty)
    #expect(
      page.messages[1].payloadStorage
        == .omittedByRetentionLimit(
          originalByteCount: olderPayload.count
        )
    )
    #expect(page.coverageGaps.isEmpty)
  }

  @Test("A cancelled clear resumes with its original cutoff and cumulative result")
  func cancelledClearResumesOriginalScope() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let policy = try HistoryRetentionPolicy(
      topicMessageLimit: 10,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 1,
      vacuumPageLimit: 10
    )
    let cancellation = CancelFirstClearStep()
    let writer = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3"),
      retentionPolicy: policy,
      clearStepHandler: { continuation in
        try await cancellation.callAsFunction(continuation)
      }
    )
    let epoch = ConnectionEpochID()
    try await writer.append(
      (1...3).map { ordinal in
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "events",
          payload: Data([UInt8(ordinal)]),
          receivedAtMicroseconds: Int64(ordinal)
        )
      }
    )

    let partial = try await writer.clearBrokerHistory()
    #expect(partial.isComplete == false)
    #expect(partial.interruption == .cancelled)
    #expect(partial.summary.deletedMessageCount == 1)
    let continuation = try #require(partial.continuation)

    // This row is newer than the confirmation cutoff and must survive resume.
    try await writer.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 4,
        topic: "events",
        payload: Data([4]),
        receivedAtMicroseconds: 4
      )
    ])
    let completed = try await writer.resumeHistoryClear(continuation)
    #expect(completed.isComplete)
    #expect(completed.summary.deletedMessageCount == 3)

    let page = try await writer.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        limit: 10
      )
    )
    #expect(page.messages.compactMap(\.connectionOrdinal) == [4])
  }

  @Test("Concurrent pages during bounded clear leave the repository reusable")
  func concurrentPagesDuringClear() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let policy = try HistoryRetentionPolicy(
      topicMessageLimit: 500,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 1,
      vacuumPageLimit: 10
    )
    let writer = SQLiteBrokerHistoryWriter(
      databaseURL: directory.appending(path: "history.sqlite3"),
      retentionPolicy: policy
    )
    let epoch = ConnectionEpochID()
    try await writer.append(
      (1...100).map { ordinal in
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "events",
          payload: Data([UInt8(ordinal)]),
          receivedAtMicroseconds: Int64(ordinal)
        )
      }
    )

    let clear = Task { try await writer.clearBrokerHistory() }
    let pages = (0..<20).map { _ in
      Task {
        try await writer.page(
          HistoryPageRequest(
            historySourceID: "source-a",
            topic: "events",
            limit: 10
          )
        )
      }
    }
    for page in pages {
      _ = try await page.value
    }
    #expect(try await clear.value.isComplete)

    try await writer.append([
      BrokerHistoryMessage(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        ordinal: 101,
        topic: "events",
        payload: Data([101]),
        receivedAtMicroseconds: 101
      )
    ])
    let final = try await writer.page(
      HistoryPageRequest(
        historySourceID: "source-a",
        topic: "events",
        limit: 10
      )
    )
    #expect(final.messages.compactMap(\.connectionOrdinal) == [101])
  }

  #if os(macOS)
    @Test("Committed append remains successful when its follow-up maintenance fails")
    func committedAppendMaintenanceFailure() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appending(
          path: "JollysMQTTBrokerHistoryWriterTests-\(UUID().uuidString)",
          directoryHint: .isDirectory
        )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      let databaseURL = directory.appending(path: "history.sqlite3")
      let policy = try HistoryRetentionPolicy(
        topicMessageLimit: 1,
        brokerByteLimit: 16 * 1_024 * 1_024,
        payloadByteLimit: 1_024,
        messagePruneBatchLimit: 1,
        vacuumPageLimit: 1
      )
      let writer = SQLiteBrokerHistoryWriter(
        databaseURL: databaseURL,
        retentionPolicy: policy
      )
      let epoch = ConnectionEpochID()
      try await writer.append([
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: 1,
          topic: "events",
          payload: Data([1]),
          receivedAtMicroseconds: 1
        )
      ])
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/sqlite3")
      process.arguments = [
        databaseURL.path,
        """
        CREATE TRIGGER fail_history_prune
        BEFORE DELETE ON messages
        BEGIN
          SELECT RAISE(ABORT, 'maintenance blocked');
        END;
        """,
      ]
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)

      try await writer.append([
        BrokerHistoryMessage(
          historySourceID: "source-a",
          connectionEpoch: epoch,
          ordinal: 2,
          topic: "events",
          payload: Data([2]),
          receivedAtMicroseconds: 2
        )
      ])

      let page = try await writer.page(
        HistoryPageRequest(
          historySourceID: "source-a",
          topic: "events",
          limit: 10
        )
      )
      #expect(page.messages.map(\.payload) == [Data([2]), Data([1])])
      #expect(await writer.maintenanceStatus() == .failed)
    }
  #endif
}

private struct RepositoryTimeout: Error {}

private actor CancelFirstClearStep {
  private var hasCancelled = false

  func callAsFunction(
    _ continuation: HistoryClearContinuation
  ) throws {
    guard !hasCancelled else { return }
    hasCancelled = true
    throw CancellationError()
  }
}

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
