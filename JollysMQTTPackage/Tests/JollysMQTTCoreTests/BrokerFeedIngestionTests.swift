import Foundation
import Testing

@testable import JollysMQTTCore

@Suite("Broker feed ingestion")
struct BrokerFeedIngestionTests {
  @Test("The topic tree preserves every empty level and value-bearing parent")
  func exactTopicTreeShape() async throws {
    let brokerID = UUID()
    let ingestion = BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: "source",
      historyWriter: RecordingHistoryWriter(),
      policy: .init(
        historyBatchSize: 8,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    let epoch = ConnectionEpochID()

    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "/plant/")
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 2, topic: "/plant//")
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 3, topic: "/plant//temperature")
    )
    let snapshot = await ingestion.flush()

    let emptyRoot = try #require(snapshot.roots.first)
    #expect(emptyRoot.level == "")
    #expect(emptyRoot.fullTopic == "")
    let plant = try #require(emptyRoot.children.first)
    #expect(plant.level == "plant")
    #expect(plant.fullTopic == "/plant")
    let emptyMiddle = try #require(plant.children.first)
    #expect(emptyMiddle.level == "")
    #expect(emptyMiddle.fullTopic == "/plant/")
    #expect(emptyMiddle.latest?.topic == "/plant/")
    #expect(emptyMiddle.children.map(\.level) == ["", "temperature"])
    #expect(emptyMiddle.children[0].fullTopic == "/plant//")
    #expect(emptyMiddle.children[0].latest?.topic == "/plant//")
    #expect(emptyMiddle.children[1].fullTopic == "/plant//temperature")
    #expect(emptyMiddle.children[1].latest?.topic == "/plant//temperature")
  }

  @Test("A protocol-valid deeply nested topic snapshots every empty level")
  func deeplyNestedTopicSnapshotIsIterative() async throws {
    let separatorCount = 8_192
    let topic = String(repeating: "/", count: separatorCount)
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: RecordingHistoryWriter(),
      policy: .init(
        historyBatchSize: 8,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )

    await ingestion.ingest(
      .fixture(
        epoch: ConnectionEpochID(),
        ordinal: 1,
        topic: topic
      )
    )
    let snapshot = await ingestion.flush()

    var levelCount = 0
    var everyLevelIsEmpty = true
    var everyLevelHasAtMostOneChild = true
    var next = snapshot.roots.first
    while let node = next {
      everyLevelIsEmpty = everyLevelIsEmpty && node.level.isEmpty
      everyLevelHasAtMostOneChild =
        everyLevelHasAtMostOneChild && node.children.count <= 1
      levelCount += 1
      next = node.children.first
    }
    #expect(everyLevelIsEmpty)
    #expect(everyLevelHasAtMostOneChild)
    #expect(levelCount == separatorCount + 1)
    #expect(snapshot.valueTopicCount == 1)
    #expect(snapshot.totalMessageCount == 1)
    await ingestion.shutdown()
  }

  @Test("Accepted messages are written in deterministic bounded batches")
  func deterministicHistoryBatches() async {
    let writer = RecordingHistoryWriter()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source-a",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 2,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    let epoch = ConnectionEpochID()

    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "a")
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 2, topic: "b")
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 3, topic: "a")
    )
    let snapshot = await ingestion.flush()

    #expect(await writer.ordinals == [[1, 2], [3]])
    #expect(snapshot.totalMessageCount == 3)
    #expect(snapshot.valueTopicCount == 2)
    #expect(snapshot.roots.first { $0.fullTopic == "a" }?.messageCount == 2)
    #expect(snapshot.historyIsHealthy)
    #expect(snapshot.unpersistedMessageCount == 0)
  }

  @Test("Indexing derives capped searchable scalar and JSON summaries")
  func cappedIndexedPayloadSummaries() async throws {
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: RecordingHistoryWriter(),
      policy: .init(
        historyBatchSize: 8,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10,
        maximumPayloadSummaryCharacters: 12
      )
    )
    let epoch = ConnectionEpochID()

    await ingestion.ingest(
      .fixture(
        epoch: epoch,
        ordinal: 1,
        topic: "plain",
        payload: Data("Café Temperature".utf8)
      )
    )
    await ingestion.ingest(
      .fixture(
        epoch: epoch,
        ordinal: 2,
        topic: "json",
        payload: Data(#"{"enabled":true,"value":42}"#.utf8)
      )
    )
    await ingestion.ingest(
      .fixture(
        epoch: epoch,
        ordinal: 3,
        topic: "binary",
        payload: Data([0xFF, 0xFE])
      )
    )
    let snapshot = await ingestion.flush()

    let plain = try #require(
      snapshot.roots.first { $0.fullTopic == "plain" }
    )
    #expect(plain.payloadSummary?.kind == .scalar)
    #expect(plain.payloadSummary?.display == "Café Tempera")
    #expect(plain.payloadSummary?.isTruncated == true)
    #expect(plain.payloadSummary?.foldedSearchText == "cafe tempera")

    let json = try #require(
      snapshot.roots.first { $0.fullTopic == "json" }
    )
    #expect(json.payloadSummary?.kind == .json)
    #expect(json.payloadSummary?.display.count == 12)
    #expect(json.payloadSummary?.isTruncated == true)

    let binary = try #require(
      snapshot.roots.first { $0.fullTopic == "binary" }
    )
    #expect(binary.payloadSummary == nil)
  }

  @Test("Summary extraction retains bounded output for a very large payload")
  func veryLargePayloadSummaryIsBounded() async throws {
    let summaryLimit = 32
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: RecordingHistoryWriter(),
      policy: .init(
        historyBatchSize: 8,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10,
        maximumPayloadSummaryCharacters: summaryLimit
      )
    )
    var payload = Data(#"{"status":"running","padding":""#.utf8)
    payload.append(Data(repeating: Character("x").asciiValue!, count: 8_000_000))
    payload.append(Data(#""}"#.utf8))

    await ingestion.ingest(
      .fixture(
        epoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "large",
        payload: payload
      )
    )
    let snapshot = await ingestion.flush()
    let node = try #require(snapshot.roots.first)

    #expect(node.payloadSummary?.kind == .json)
    #expect(node.payloadSummary?.display.count == summaryLimit)
    #expect(
      node.payloadSummary?.foldedSearchText.count == summaryLimit
    )
    #expect(node.payloadSummary?.isTruncated == true)
  }

  @Test("A message burst emits one revision and slow consumers retain only newest")
  func coalescedNewestWinsSnapshots() async throws {
    let sleeper = IngestionManualSleeper()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: RecordingHistoryWriter(),
      policy: .init(
        historyBatchSize: 1_000,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      ),
      clock: BrokerFeedClock(now: Date.init, sleep: sleeper.sleep)
    )
    var snapshots = await ingestion.snapshots().makeAsyncIterator()
    _ = await snapshots.next()
    let epoch = ConnectionEpochID()

    for ordinal in 1...100 {
      await ingestion.ingest(
        .fixture(
          epoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "burst/\(ordinal % 4)"
        )
      )
    }

    await sleeper.waitForRequest(seconds: 0.1)
    #expect(await sleeper.requestCount(seconds: 0.1) == 1)
    await sleeper.resume(seconds: 0.1)
    let first = try #require(await snapshots.next())
    #expect(first.revision == 1)
    #expect(first.totalMessageCount == 100)

    for ordinal in 101...120 {
      await ingestion.ingest(
        .fixture(
          epoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "burst/0"
        )
      )
    }
    await sleeper.waitForRequest(seconds: 0.1)
    await sleeper.resume(seconds: 0.1)
    while await ingestion.metrics().snapshotRevision < 2 {
      await Task.yield()
    }
    for ordinal in 121...140 {
      await ingestion.ingest(
        .fixture(
          epoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "burst/0"
        )
      )
    }
    await sleeper.waitForRequest(seconds: 0.1)
    await sleeper.resume(seconds: 0.1)
    while await ingestion.metrics().snapshotRevision < 3 {
      await Task.yield()
    }

    let newest = try #require(await snapshots.next())
    #expect(newest.revision == 3)
    #expect(newest.totalMessageCount == 140)
  }

  @Test("Shutdown releases the writer, payload cache, and large topic tree")
  func shutdownReleasesOwnedResources() async {
    let recorder = LifetimeRecorder()
    var writer: LifetimeHistoryWriter? = LifetimeHistoryWriter(
      recorder: recorder
    )
    weak let weakWriter = writer
    var ingestion: BrokerFeedIngestion? = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer!,
      policy: .init(
        historyBatchSize: 4_096,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    weak let weakIngestion = ingestion
    writer = nil
    let epoch = ConnectionEpochID()

    for ordinal in 1...2_000 {
      await ingestion?.ingest(
        .fixture(
          epoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "large/tree/\(ordinal)",
          payload: Data(repeating: 0xA5, count: 4_096)
        )
      )
    }
    let before = await ingestion?.metrics()
    #expect((before?.topicNodeCount ?? 0) > 2_000)
    #expect(before?.retainedPayloadByteCount == 8_192_000)

    await ingestion?.shutdown()

    let after = await ingestion?.metrics()
    #expect(after?.isShutdown == true)
    #expect(after?.topicNodeCount == 0)
    #expect(after?.retainedPayloadByteCount == 0)
    #expect(after?.pendingHistoryMessageCount == 0)
    #expect(await recorder.shutdownCount == 1)
    #expect(weakWriter == nil)

    ingestion = nil
    for _ in 0..<4 {
      await Task.yield()
    }
    #expect(weakIngestion == nil)
  }

  @Test("History failure is visible without stopping live indexing")
  func historyFailureIsVisible() async {
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: FailingHistoryWriter(),
      policy: .init(
        historyBatchSize: 2,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    let epoch = ConnectionEpochID()
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "a")
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 2, topic: "b")
    )
    let degraded = await ingestion.flush()

    #expect(degraded.totalMessageCount == 2)
    #expect(degraded.valueTopicCount == 2)
    #expect(degraded.historyIsHealthy == false)
    #expect(degraded.unpersistedMessageCount == 2)

    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 3, topic: "c")
    )
    let stillLive = await ingestion.flush()
    #expect(stillLive.totalMessageCount == 3)
    #expect(stillLive.valueTopicCount == 3)
    #expect(stillLive.unpersistedMessageCount == 3)
  }

  @Test("A slow writer backpressures ingestion at one pending batch")
  func historyHandoffIsBounded() async {
    let writer = SlowFirstHistoryWriter()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 2,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    let epoch = ConnectionEpochID()
    let firstBatch = Task {
      await ingestion.ingest(
        .fixture(epoch: epoch, ordinal: 1, topic: "a")
      )
      await ingestion.ingest(
        .fixture(epoch: epoch, ordinal: 2, topic: "b")
      )
    }
    await writer.waitUntilFirstAppendStarts()
    let followingMessages = Task {
      for ordinal in 3...100 {
        await ingestion.ingest(
          .fixture(
            epoch: epoch,
            ordinal: UInt64(ordinal),
            topic: "topic/\(ordinal)"
          )
        )
      }
    }
    while await ingestion.metrics().pendingHistoryMessageCount < 2 {
      await Task.yield()
    }

    #expect(await ingestion.metrics().pendingHistoryMessageCount == 2)
    await writer.finishFirstAppend()
    await firstBatch.value
    await followingMessages.value
    let snapshot = await ingestion.flush()
    #expect(snapshot.totalMessageCount == 100)
  }

  @Test("Overlapping timer, force flushes, and shutdown serialize every history operation")
  func adversarialFlushShutdownSerialization() async {
    let sleeper = IngestionManualSleeper()
    let writer = AdversarialHistoryWriter()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 8,
        historyFlushIntervalSeconds: 0.25,
        maximumSnapshotRate: 10
      ),
      clock: BrokerFeedClock(now: Date.init, sleep: sleeper.sleep)
    )
    let epoch = ConnectionEpochID()
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "first")
    )
    await sleeper.waitForRequest(seconds: 0.25)
    await sleeper.resume(seconds: 0.25)
    await writer.waitForFirstAppend()

    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 2, topic: "second")
    )
    let flushes = (0..<32).map { _ in
      Task { await ingestion.flush() }
    }
    let shutdowns = (0..<4).map { _ in
      Task {
        await ingestion.shutdown()
      }
    }
    for _ in 0..<100 {
      await Task.yield()
    }

    await writer.releaseFirstAppend()
    for flush in flushes {
      _ = await flush.value
    }
    for shutdown in shutdowns {
      await shutdown.value
    }

    #expect(await writer.appendedOrdinals == [1, 2])
    #expect(await writer.shutdownCount == 1)
    #expect(await writer.shutdownOverlappedAppend == false)
    #expect(await writer.events.last == "shutdown")
  }
}

private actor RecordingHistoryWriter: BrokerHistoryWriting {
  private(set) var ordinals: [[UInt64]] = []

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    ordinals.append(messages.map(\.ordinal))
  }

  func shutdown() async throws {}
}

private actor LifetimeRecorder {
  private(set) var shutdownCount = 0

  func recordShutdown() {
    shutdownCount += 1
  }
}

private actor LifetimeHistoryWriter: BrokerHistoryWriting {
  let recorder: LifetimeRecorder

  init(recorder: LifetimeRecorder) {
    self.recorder = recorder
  }

  func append(_ messages: [BrokerHistoryMessage]) async throws {}

  func shutdown() async throws {
    await recorder.recordShutdown()
  }
}

private struct FailingHistoryError: Error {}

private actor FailingHistoryWriter: BrokerHistoryWriting {
  func append(_ messages: [BrokerHistoryMessage]) async throws {
    throw FailingHistoryError()
  }

  func shutdown() async throws {}
}

private actor SlowFirstHistoryWriter: BrokerHistoryWriting {
  private var appendCount = 0
  private var appendStarted = false
  private var canFinishFirstAppend = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    appendCount += 1
    guard appendCount == 1 else { return }
    appendStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    guard !canFinishFirstAppend else { return }
    await withCheckedContinuation { continuation in
      finishWaiters.append(continuation)
    }
  }

  func waitUntilFirstAppendStarts() async {
    guard !appendStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finishFirstAppend() {
    canFinishFirstAppend = true
    let waiters = finishWaiters
    finishWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func shutdown() async throws {}
}

private actor AdversarialHistoryWriter: BrokerHistoryWriting {
  private(set) var appendedOrdinals: [UInt64] = []
  private(set) var shutdownCount = 0
  private(set) var shutdownOverlappedAppend = false
  private(set) var events: [String] = []

  private var activeAppendCount = 0
  private var firstAppendStarted = false
  private var firstAppendReleased = false
  private var firstAppendStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstAppendReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    activeAppendCount += 1
    let ordinals = messages.map(\.ordinal)
    events.append("append-start:\(ordinals)")
    if !firstAppendStarted {
      firstAppendStarted = true
      let waiters = firstAppendStartWaiters
      firstAppendStartWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      if !firstAppendReleased {
        await withCheckedContinuation { continuation in
          firstAppendReleaseWaiters.append(continuation)
        }
      }
    } else {
      for _ in 0..<100 {
        await Task.yield()
      }
    }
    appendedOrdinals.append(contentsOf: ordinals)
    events.append("append-end:\(ordinals)")
    activeAppendCount -= 1
  }

  func shutdown() async throws {
    shutdownCount += 1
    shutdownOverlappedAppend = activeAppendCount > 0
    events.append("shutdown")
  }

  func waitForFirstAppend() async {
    guard !firstAppendStarted else { return }
    await withCheckedContinuation { continuation in
      firstAppendStartWaiters.append(continuation)
    }
  }

  func releaseFirstAppend() {
    firstAppendReleased = true
    let waiters = firstAppendReleaseWaiters
    firstAppendReleaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor IngestionManualSleeper {
  private struct Request {
    let seconds: Double
    let continuation: CheckedContinuation<Void, Error>
  }

  private var requests: [Request] = []

  func sleep(seconds: Double) async throws {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(
        Request(seconds: seconds, continuation: continuation)
      )
    }
  }

  func waitForRequest(seconds: Double) async {
    while !requests.contains(where: { $0.seconds == seconds }) {
      await Task.yield()
    }
  }

  func requestCount(seconds: Double) -> Int {
    requests.count { $0.seconds == seconds }
  }

  func resume(seconds: Double) {
    guard
      let index = requests.firstIndex(where: {
        $0.seconds == seconds
      })
    else {
      return
    }
    requests.remove(at: index).continuation.resume()
  }
}

extension BrokerInboundMessage {
  fileprivate static func fixture(
    epoch: ConnectionEpochID,
    ordinal: UInt64,
    topic: String,
    payload: Data = Data("value".utf8)
  ) -> Self {
    Self(
      connectionEpoch: epoch,
      ordinal: ordinal,
      topic: topic,
      payload: payload,
      qos: .atMostOnce,
      retained: false,
      duplicate: false,
      receivedAtMicroseconds: Int64(ordinal)
    )
  }
}
