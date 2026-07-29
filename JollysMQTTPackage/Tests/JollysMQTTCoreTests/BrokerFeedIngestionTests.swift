import Foundation
import Synchronization
import Testing

@testable import JollysMQTTCore

@Suite("Broker feed ingestion")
struct BrokerFeedIngestionTests {
  @Test("Topic snapshots carry the active opaque history source")
  func snapshotHistorySource() async {
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "opaque-source-id",
      historyWriter: RecordingHistoryWriter()
    )

    let snapshot = await ingestion.flush()

    #expect(snapshot.historySourceID == "opaque-source-id")
    #expect(BrokerTopicTreeSnapshot.empty.historySourceID == nil)
  }

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

  @Test("Every new connection epoch makes previously known topics stale")
  func reconnectMarksKnownTopicsStaleUntilObservedAgain() async throws {
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
    let firstEpoch = ConnectionEpochID()
    let secondEpoch = ConnectionEpochID()

    await ingestion.beginConnectionEpoch(firstEpoch)
    await ingestion.ingest(
      .fixture(epoch: firstEpoch, ordinal: 1, topic: "live")
    )
    await ingestion.ingest(
      .fixture(epoch: firstEpoch, ordinal: 2, topic: "stale")
    )
    await ingestion.ingest(
      .fixture(epoch: firstEpoch, ordinal: 3, topic: "parent")
    )
    _ = await ingestion.flush()

    await ingestion.beginConnectionEpoch(secondEpoch)
    let allStale = await ingestion.flush()
    #expect(allStale.connectionEpoch == secondEpoch)
    #expect(allStale.roots.allSatisfy { $0.isStale })

    await ingestion.ingest(
      .fixture(epoch: secondEpoch, ordinal: 1, topic: "live")
    )
    await ingestion.ingest(
      .fixture(epoch: secondEpoch, ordinal: 2, topic: "parent/child")
    )
    let partiallyFresh = await ingestion.flush()
    let live = try #require(
      partiallyFresh.roots.first { $0.fullTopic == "live" }
    )
    let stale = try #require(
      partiallyFresh.roots.first { $0.fullTopic == "stale" }
    )
    #expect(live.isStale == false)
    #expect(stale.isStale)
    let parent = try #require(
      partiallyFresh.roots.first { $0.fullTopic == "parent" }
    )
    #expect(parent.isStale)
    #expect(parent.children.first?.isStale == false)
  }

  @Test("A slow writer backpressures only at the bounded history capacity")
  func historyHandoffIsBounded() async {
    let writer = SlowFirstHistoryWriter()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 2,
        historyQueueCapacity: 4,
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
    while await ingestion.metrics().pendingHistoryMessageCount < 4 {
      await Task.yield()
    }

    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(await ingestion.metrics().pendingHistoryMessageCount == 4)
    #expect(await ingestion.metrics().historyQueueHighWaterMark == 4)
    #expect(
      await ingestion.metrics().historyQueuePayloadHighWaterMark == 20
    )
    await writer.finishFirstAppend()
    await firstBatch.value
    await followingMessages.value
    let snapshot = await ingestion.flush()
    #expect(snapshot.totalMessageCount == 100)
  }

  @Test("A snapshot counts an in-flight history batch as not yet durable")
  func snapshotReportsInFlightHistory() async throws {
    let writer = SlowFirstHistoryWriter()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 1,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 1_000_000
      )
    )
    let firstEpoch = ConnectionEpochID()
    let markerEpoch = ConnectionEpochID()
    let snapshots = await ingestion.snapshots()
    let observedMarker = Task {
      for await snapshot in snapshots
      where snapshot.connectionEpoch == markerEpoch {
        return snapshot
      }
      return BrokerTopicTreeSnapshot.empty
    }
    let ingest = Task {
      await ingestion.ingest(
        .fixture(epoch: firstEpoch, ordinal: 1, topic: "in-flight")
      )
    }
    await writer.waitUntilFirstAppendStarts()

    await ingestion.beginConnectionEpoch(markerEpoch)
    let snapshot = await observedMarker.value

    #expect(snapshot.unpersistedMessageCount == 1)
    #expect(snapshot.historyIsHealthy)
    await writer.finishFirstAppend()
    await ingest.value
    await ingestion.shutdown()
  }

  @Test("The default history handoff holds exactly two batches")
  func defaultHistoryHandoffCapacity() {
    let policy = BrokerFeedIngestionPolicy(historyBatchSize: 37)

    #expect(policy.historyQueueCapacity == 74)
  }

  @Test("History recovery durably closes the exact coverage gap before resuming")
  func historyRecoveryRecordsCoverageGap() async throws {
    let writer = RecoveringHistoryWriter()
    let epoch = ConnectionEpochID()
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

    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "a", receivedAt: 10)
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 2, topic: "b", receivedAt: 20)
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 3, topic: "c", receivedAt: 30)
    )
    let degraded = await ingestion.flush()
    let openGap = try #require(degraded.activeHistoryGap)
    #expect(degraded.historyDiagnostic == .storageFailure)
    #expect(openGap.startedAtMicroseconds == 10)
    #expect(openGap.endedAtMicroseconds == nil)
    #expect(openGap.minimumMissingMessageCount == 3)
    #expect(openGap.reason == .storageFailure)

    #expect(
      await ingestion.retryHistoryPersistence(
        recoveredAtMicroseconds: 40
      )
    )
    let recorded = try #require(await writer.coverageGaps.first)
    #expect(recorded.startedAtMicroseconds == 10)
    #expect(recorded.endedAtMicroseconds == 40)
    #expect(recorded.minimumMissingMessageCount == 3)
    #expect(recorded.connectionEpoch == epoch)

    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 4, topic: "d", receivedAt: 50)
    )
    let recovered = await ingestion.flush()
    #expect(recovered.historyIsHealthy)
    #expect(recovered.activeHistoryGap == nil)
    #expect(recovered.historyDiagnostic == nil)
    #expect(recovered.unpersistedMessageCount == 3)
    #expect(await writer.appendedOrdinals == [4])
  }

  @Test("Failed gap recording leaves history degraded and append stays stopped")
  func failedHistoryRecoveryDoesNotResumePersistence() async {
    let writer = RecoveringHistoryWriter(gapRecordingFails: true)
    let epoch = ConnectionEpochID()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 1,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "a", receivedAt: 10)
    )

    #expect(
      await ingestion.retryHistoryPersistence(
        recoveredAtMicroseconds: 20
      ) == false
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 2, topic: "b", receivedAt: 30)
    )
    let snapshot = await ingestion.flush()

    #expect(snapshot.historyIsHealthy == false)
    #expect(snapshot.activeHistoryGap?.endedAtMicroseconds == nil)
    #expect(snapshot.activeHistoryGap?.minimumMissingMessageCount == 2)
    #expect(snapshot.unpersistedMessageCount == 2)
    #expect(await writer.appendedOrdinals.isEmpty)
  }

  @Test("Concurrent ingest waits for durable gap recovery before appending")
  func recoveryIsAtomicAgainstActorReentrancy() async {
    let writer = RecoveringHistoryWriter(gateGapRecording: true)
    let epoch = ConnectionEpochID()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 1,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "a", receivedAt: 10)
    )
    let recovery = Task {
      await ingestion.retryHistoryPersistence(
        recoveredAtMicroseconds: 20
      )
    }
    await writer.waitUntilGapRecordingStarts()

    let concurrentIngest = Task {
      await ingestion.ingest(
        .fixture(epoch: epoch, ordinal: 2, topic: "b", receivedAt: 30)
      )
    }
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(await writer.appendedOrdinals.isEmpty)

    await writer.finishGapRecording()
    #expect(await recovery.value)
    await concurrentIngest.value
    _ = await ingestion.flush()
    #expect(await writer.appendedOrdinals == [2])
  }

  @Test("Local overload records the measured conservative open-ended gap")
  func localOverloadCoverageGapIsDurable() async throws {
    let writer = RecordingHistoryWriter()
    let epoch = ConnectionEpochID()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer
    )

    #expect(
      await ingestion.recordLocalOverloadCoverageGap(
        connectionEpoch: epoch,
        detectedAtMicroseconds: 100,
        minimumMissingMessageCount: 7
      )
    )

    let gap = try #require(await writer.coverageGaps.first)
    #expect(gap.historySourceID == "source")
    #expect(gap.connectionEpoch == epoch)
    #expect(gap.startedAtMicroseconds == 100)
    #expect(gap.endedAtMicroseconds == nil)
    #expect(gap.minimumMissingMessageCount == 7)
    #expect(gap.reason == .localOverload)
    #expect(gap.isOpenEnded)
    #expect(await ingestion.flush().unpersistedMessageCount == 7)
  }

  @Test("A successful publish is durable with its operation identity")
  func successfulPublishHistoryIdentity() async throws {
    let writer = RecordingHistoryWriter()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 1,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    let operationID = PublishOperationID()
    let request = BrokerPublishRequest(
      operationID: operationID,
      topic: "factory/command",
      payload: Data("start".utf8),
      qos: .exactlyOnce,
      retain: true
    )

    await ingestion.recordSuccessfulPublish(
      request,
      completedAtMicroseconds: 123
    )

    let message = try #require(await writer.messages.first)
    #expect(message.identity == .published(operationID: operationID))
    #expect(message.connectionEpoch == nil)
    #expect(message.ordinal == nil)
    #expect(message.topic == request.topic)
    #expect(message.payload == request.payload)
    #expect(message.qos == request.qos)
    #expect(message.retained == request.retain)
    #expect(message.receivedAtMicroseconds == 123)
  }

  @Test("Failed overload recording preserves an existing storage gap")
  func overloadFailurePreservesStorageCoverageUntilAtomicRecovery() async throws {
    let writer = MultipleGapRecoveryWriter()
    let epoch = ConnectionEpochID()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer,
      policy: .init(
        historyBatchSize: 1,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )

    await ingestion.ingest(
      .fixture(epoch: epoch, ordinal: 1, topic: "stored", receivedAt: 10)
    )
    #expect(
      await ingestion.recordLocalOverloadCoverageGap(
        connectionEpoch: epoch,
        detectedAtMicroseconds: 20,
        minimumMissingMessageCount: 3
      ) == false
    )
    let degraded = await ingestion.flush()
    #expect(degraded.historyIsHealthy == false)
    #expect(degraded.activeHistoryGap?.reason == .storageFailure)
    #expect(degraded.activeHistoryGap?.startedAtMicroseconds == 10)
    #expect(degraded.activeHistoryGap?.minimumMissingMessageCount == 1)
    #expect(degraded.unpersistedMessageCount == 4)

    let recovery = Task {
      await ingestion.retryHistoryPersistence(
        recoveredAtMicroseconds: 30
      )
    }
    await writer.waitUntilOverloadRecoveryStarts()
    let storageGap = try #require(await writer.coverageGaps.first)
    #expect(storageGap.reason == .storageFailure)
    #expect(storageGap.startedAtMicroseconds == 10)
    #expect(storageGap.endedAtMicroseconds == 30)
    #expect(storageGap.minimumMissingMessageCount == 1)

    let concurrentIngest = Task {
      await ingestion.ingest(
        .fixture(epoch: epoch, ordinal: 2, topic: "live", receivedAt: 40)
      )
    }
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(await writer.appendedOrdinals.isEmpty)

    await writer.finishOverloadRecovery()
    #expect(await recovery.value)
    await concurrentIngest.value
    let recovered = await ingestion.flush()

    let gaps = await writer.coverageGaps
    #expect(gaps.count == 2)
    let overloadGap = try #require(
      gaps.first { $0.reason == .localOverload }
    )
    #expect(overloadGap.startedAtMicroseconds == 20)
    #expect(overloadGap.endedAtMicroseconds == nil)
    #expect(overloadGap.minimumMissingMessageCount == 3)
    #expect(overloadGap.isOpenEnded)
    #expect(gaps.map(\.minimumMissingMessageCount).reduce(0, +) == 4)
    #expect(await writer.appendedOrdinals == [2])
    #expect(recovered.historyIsHealthy)
    #expect(recovered.activeHistoryGap == nil)
    #expect(recovered.unpersistedMessageCount == 4)
  }

  @Test("Repeated failed gaps merge by reason into bounded coverage")
  func repeatedOverloadGapsMergeWithoutDoubleCounting() async throws {
    let writer = FailingThenRecordingGapWriter(failureCount: 2)
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer
    )

    #expect(
      await ingestion.recordLocalOverloadCoverageGap(
        connectionEpoch: ConnectionEpochID(),
        detectedAtMicroseconds: 100,
        minimumMissingMessageCount: 2
      ) == false
    )
    #expect(
      await ingestion.recordLocalOverloadCoverageGap(
        connectionEpoch: ConnectionEpochID(),
        detectedAtMicroseconds: 200,
        minimumMissingMessageCount: 3
      ) == false
    )
    let degraded = await ingestion.flush()
    let merged = try #require(degraded.activeHistoryGap)
    #expect(merged.reason == .localOverload)
    #expect(merged.connectionEpoch == nil)
    #expect(merged.startedAtMicroseconds == 100)
    #expect(merged.minimumMissingMessageCount == 5)
    #expect(degraded.unpersistedMessageCount == 5)

    #expect(
      await ingestion.retryHistoryPersistence(
        recoveredAtMicroseconds: 300
      )
    )
    let recorded = await writer.coverageGaps
    #expect(recorded.count == 1)
    #expect(recorded.first?.minimumMissingMessageCount == 5)
    #expect(recorded.first?.startedAtMicroseconds == 100)
    #expect(recorded.first?.connectionEpoch == nil)
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

  @Test("History append call boundaries are bounded by payload bytes as well as count")
  func historyBatchPayloadBytesAreBounded() async throws {
    let writer = RecordingHistoryWriter()
    let retention = try HistoryRetentionPolicy(
      topicMessageLimit: 1_000,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1_024 * 1_024,
      messagePruneBatchLimit: 5_000,
      vacuumPageLimit: 8_192
    )
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source-a",
      historyWriter: writer,
      policy: BrokerFeedIngestionPolicy(
        historyBatchSize: 128,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      ),
      retentionPolicy: retention
    )
    let epoch = ConnectionEpochID()
    let payload = Data(repeating: 0xA5, count: 1_024 * 1_024)

    for ordinal in 1...3 {
      await ingestion.ingest(
        .fixture(
          epoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "large",
          payload: payload
        )
      )
    }
    _ = await ingestion.flush()

    #expect(await writer.ordinals == [[1], [2], [3]])
    #expect(
      await writer.messages.allSatisfy {
        $0.payload.count <= retention.maximumAppendPayloadBytes
      }
    )
  }

  @Test("A boundary flush failure covers the message that triggered it")
  func boundaryFlushFailureCoversTriggeringMessage() async throws {
    let writer = RecoveringHistoryWriter()
    let retention = try HistoryRetentionPolicy(
      topicMessageLimit: 1_000,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1_024 * 1_024,
      messagePruneBatchLimit: 5_000,
      vacuumPageLimit: 8_192
    )
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source-a",
      historyWriter: writer,
      policy: BrokerFeedIngestionPolicy(
        historyBatchSize: 128,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      ),
      retentionPolicy: retention
    )
    let epoch = ConnectionEpochID()
    let payload = Data(repeating: 0xA5, count: 1_024 * 1_024)

    await ingestion.ingest(
      .fixture(
        epoch: epoch,
        ordinal: 1,
        topic: "large",
        payload: payload,
        receivedAt: 10
      )
    )
    await ingestion.ingest(
      .fixture(
        epoch: epoch,
        ordinal: 2,
        topic: "large",
        payload: payload,
        receivedAt: 20
      )
    )

    let degraded = await ingestion.flush()
    #expect(degraded.unpersistedMessageCount == 2)
    #expect(degraded.activeHistoryGap?.minimumMissingMessageCount == 2)
    #expect(await writer.appendedOrdinals.isEmpty)

    #expect(
      await ingestion.retryHistoryPersistence(
        recoveredAtMicroseconds: 30
      )
    )
    let gap = try #require(await writer.coverageGaps.first)
    #expect(gap.startedAtMicroseconds == 10)
    #expect(gap.endedAtMicroseconds == 30)
    #expect(gap.minimumMissingMessageCount == 2)
  }

  @Test("Live retention changes re-split pending messages before handoff")
  func liveRetentionChangeResplitsPendingMessages() async throws {
    let writer = RecordingHistoryWriter()
    let larger = try HistoryRetentionPolicy(
      topicMessageLimit: 1_000,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024 * 1_024,
      messagePruneBatchLimit: 5_000,
      vacuumPageLimit: 8_192
    )
    let smaller = try HistoryRetentionPolicy(
      topicMessageLimit: 1_000,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1_024 * 1_024,
      messagePruneBatchLimit: 5_000,
      vacuumPageLimit: 8_192
    )
    let policies = Mutex(larger)
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source-a",
      historyWriter: writer,
      policy: BrokerFeedIngestionPolicy(
        historyBatchSize: 4_096,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      ),
      retentionPolicyProvider: {
        policies.withLock { $0 }
      }
    )
    let epoch = ConnectionEpochID()
    let payload = Data(repeating: 0xA5, count: 1_024 * 1_024)
    for ordinal in 1...4 {
      await ingestion.ingest(
        .fixture(
          epoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "large",
          payload: payload
        )
      )
    }
    policies.withLock { $0 = smaller }

    _ = await ingestion.flush()

    #expect(await writer.ordinals == [[1], [2], [3], [4]])
  }

  @Test("History handoff never exceeds the writer message count contract")
  func historyBatchCountMatchesWriterContract() async {
    let writer = RecordingHistoryWriter()
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source-a",
      historyWriter: writer,
      policy: BrokerFeedIngestionPolicy(
        historyBatchSize: 4_096,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10
      )
    )
    let epoch = ConnectionEpochID()
    for ordinal in 1...1_001 {
      await ingestion.ingest(
        .fixture(
          epoch: epoch,
          ordinal: UInt64(ordinal),
          topic: "events"
        )
      )
    }
    _ = await ingestion.flush()

    #expect(await writer.ordinals.map(\.count) == [500, 500, 1])
  }
}

private actor RecordingHistoryWriter: BrokerHistoryWriting {
  private(set) var ordinals: [[UInt64]] = []
  private(set) var messages: [BrokerHistoryMessage] = []
  private(set) var coverageGaps: [BrokerHistoryCoverageGap] = []

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    self.messages.append(contentsOf: messages)
    ordinals.append(messages.compactMap(\.ordinal))
  }

  func recordCoverageGap(
    _ gap: BrokerHistoryCoverageGap
  ) async throws {
    coverageGaps.append(gap)
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
  func recordCoverageGap(_ gap: BrokerHistoryCoverageGap) async throws {}

  func shutdown() async throws {
    await recorder.recordShutdown()
  }
}

private struct FailingHistoryError: Error {}

private actor FailingHistoryWriter: BrokerHistoryWriting {
  func append(_ messages: [BrokerHistoryMessage]) async throws {
    throw FailingHistoryError()
  }

  func recordCoverageGap(_ gap: BrokerHistoryCoverageGap) async throws {
    throw FailingHistoryError()
  }

  func shutdown() async throws {}
}

private actor RecoveringHistoryWriter: BrokerHistoryWriting {
  private let gapRecordingFails: Bool
  private let gateGapRecording: Bool
  private var appendFails = true
  private var gapRecordingStarted = false
  private var gapRecordingCanFinish = false
  private var gapStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var gapFinishWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var coverageGaps: [BrokerHistoryCoverageGap] = []
  private(set) var appendedOrdinals: [UInt64] = []

  init(
    gapRecordingFails: Bool = false,
    gateGapRecording: Bool = false
  ) {
    self.gapRecordingFails = gapRecordingFails
    self.gateGapRecording = gateGapRecording
  }

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    if appendFails {
      appendFails = false
      throw FailingHistoryError()
    }
    appendedOrdinals.append(contentsOf: messages.compactMap(\.ordinal))
  }

  func recordCoverageGap(
    _ gap: BrokerHistoryCoverageGap
  ) async throws {
    gapRecordingStarted = true
    let startWaiters = gapStartWaiters
    gapStartWaiters.removeAll()
    for waiter in startWaiters {
      waiter.resume()
    }
    if gateGapRecording, !gapRecordingCanFinish {
      await withCheckedContinuation { continuation in
        gapFinishWaiters.append(continuation)
      }
    }
    if gapRecordingFails {
      throw FailingHistoryError()
    }
    coverageGaps.append(gap)
  }

  func shutdown() async throws {}

  func waitUntilGapRecordingStarts() async {
    guard !gapRecordingStarted else { return }
    await withCheckedContinuation { continuation in
      gapStartWaiters.append(continuation)
    }
  }

  func finishGapRecording() {
    gapRecordingCanFinish = true
    let waiters = gapFinishWaiters
    gapFinishWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor MultipleGapRecoveryWriter: BrokerHistoryWriting {
  private var appendFails = true
  private var coverageAttemptCount = 0
  private var overloadRecoveryStarted = false
  private var overloadRecoveryCanFinish = false
  private var overloadStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var overloadFinishWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var coverageGaps: [BrokerHistoryCoverageGap] = []
  private(set) var appendedOrdinals: [UInt64] = []

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    if appendFails {
      appendFails = false
      throw FailingHistoryError()
    }
    appendedOrdinals.append(contentsOf: messages.compactMap(\.ordinal))
  }

  func recordCoverageGap(
    _ gap: BrokerHistoryCoverageGap
  ) async throws {
    coverageAttemptCount += 1
    if coverageAttemptCount == 1 {
      throw FailingHistoryError()
    }
    if gap.reason == .localOverload {
      overloadRecoveryStarted = true
      let waiters = overloadStartWaiters
      overloadStartWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      if !overloadRecoveryCanFinish {
        await withCheckedContinuation { continuation in
          overloadFinishWaiters.append(continuation)
        }
      }
    }
    coverageGaps.append(gap)
  }

  func shutdown() async throws {}

  func waitUntilOverloadRecoveryStarts() async {
    guard !overloadRecoveryStarted else { return }
    await withCheckedContinuation { continuation in
      overloadStartWaiters.append(continuation)
    }
  }

  func finishOverloadRecovery() {
    overloadRecoveryCanFinish = true
    let waiters = overloadFinishWaiters
    overloadFinishWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor FailingThenRecordingGapWriter: BrokerHistoryWriting {
  private var remainingFailures: Int
  private(set) var coverageGaps: [BrokerHistoryCoverageGap] = []

  init(failureCount: Int) {
    remainingFailures = failureCount
  }

  func append(_ messages: [BrokerHistoryMessage]) async throws {}

  func recordCoverageGap(
    _ gap: BrokerHistoryCoverageGap
  ) async throws {
    if remainingFailures > 0 {
      remainingFailures -= 1
      throw FailingHistoryError()
    }
    coverageGaps.append(gap)
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

  func recordCoverageGap(_ gap: BrokerHistoryCoverageGap) async throws {}
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
    let ordinals = messages.compactMap(\.ordinal)
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

  func recordCoverageGap(_ gap: BrokerHistoryCoverageGap) async throws {}

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
    payload: Data = Data("value".utf8),
    receivedAt: Int64? = nil
  ) -> Self {
    Self(
      connectionEpoch: epoch,
      ordinal: ordinal,
      topic: topic,
      payload: payload,
      qos: .atMostOnce,
      retained: false,
      duplicate: false,
      receivedAtMicroseconds: receivedAt ?? Int64(ordinal)
    )
  }
}
