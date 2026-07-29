import Foundation
import JollysMQTT
import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import Testing

@Suite("Reproducible performance probe")
struct PerformanceProbeTests {
  @Test("A reduced fixture exercises and releases every measured pipeline")
  func reducedFixture() async throws {
    let fixture = PerformanceWorkloadFixture(
      topicCount: 100,
      messagesPerMinute: 6_000,
      durationSeconds: 1,
      payloadBytes: 256,
      topicDistribution: PerformanceTopicDistribution(
        hotTopicCount: 10,
        hotMessagePercent: 80,
        seed: 0x4A_4D_51_54_54
      ),
      payloadDistribution: PerformancePayloadDistribution(
        scalarPercent: 50,
        jsonPercent: 40,
        binaryPercent: 10
      )
    )
    let result = try await JollysMQTTPerformanceProbe().run(
      PerformanceProbeConfiguration(
        fixture: fixture,
        paceProducer: false,
        ingressCapacity: 256,
        publishQueueCapacity: 8,
        postStopSampleCount: 3,
        postStopSampleInterval: .milliseconds(5)
      )
    )

    #expect(result.ingestedMessageCount == 100)
    #expect(result.historyWrittenMessageCount == 100)
    #expect(result.historyMessagesPerSecond > 0)
    #expect(result.queueDepths.ingress.highWaterMark > 0)
    #expect(result.queueDepths.history.highWaterMark > 0)
    #expect(result.queueDepths.publish.highWaterMark == 8)
    #expect(result.queuesReturnedToBaseline)
    #expect(result.mainActorUpdateCount > 0)
    #expect(result.mainActorUpdatesPerSecond > 0)
    #expect(result.snapshotCost.sampleCount > 0)
    #expect(result.searchCost.sampleCount > 0)
    #expect(result.chartCost.sampleCount > 0)
    #expect(result.feedOwnedStateReleased)
    #expect(result.recordsEveryRequiredMetric)
  }

  @Test(
    "Retention maintenance does not stall the bounded feed handoff",
    .timeLimit(.minutes(1))
  )
  func retentionMaintenanceKeepsIngressLive() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "jollysmqtt-retention-repro-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "history.sqlite")
    let runsPhaseDiagnostic =
      ProcessInfo.processInfo.environment["JOLLYSMQTT_PHASE_DIAGNOSTIC"]
      == "1"
    let policy =
      if runsPhaseDiagnostic {
        HistoryRetentionPolicy.default
      } else {
        try HistoryRetentionPolicy(
          topicMessageLimit: 1_000_000,
          brokerByteLimit: 16 * 1_024 * 1_024,
          payloadByteLimit: 1_024,
          messagePruneBatchLimit: 5_000,
          vacuumPageLimit: 8_192
        )
      }
    var seedStore: SQLiteHistoryStore? = try await SQLiteHistoryStore.open(
      databaseURL: databaseURL
    )
    var ordinal = 0
    while try #require(await seedStore?.diagnostics()).totalSQLiteBytes
      <= policy.brokerPruneHighWaterBytes + 10 * 1_024 * 1_024
    {
      let batch = (0..<500).map { offset in
        HistoryMessageInput(
          historySourceID: "retention-repro",
          connectionEpoch: UUID(),
          connectionOrdinal: UInt64(ordinal + offset + 1),
          topic: "seed/\((ordinal + offset) % 10_000)",
          receivedAtMicroseconds: Int64(ordinal + offset),
          payload: Data(repeating: 0x5A, count: 256)
        )
      }
      _ = try await seedStore?.append(batch)
      ordinal += batch.count
    }
    let seededStore = try #require(seedStore)
    if runsPhaseDiagnostic {
      let clock = ContinuousClock()
      var started = clock.now
      _ = try await seededStore.prune(
        keepingNewestPerTopic: policy.topicMessageLimit,
        batchLimit: 500
      )
      let globalTopicMilliseconds =
        started.duration(to: clock.now).testMilliseconds
      started = clock.now
      _ = try await seededStore.prune(
        keepingNewestPerTopic: policy.topicMessageLimit,
        batchLimit: 500,
        topics: (0..<128).map {
          HistoryTopicRetentionScope(
            historySourceID: "retention-repro",
            topic: "seed/\($0)"
          )
        }
      )
      let scopedTopicMilliseconds =
        started.duration(to: clock.now).testMilliseconds
      started = clock.now
      _ = try await seededStore.diagnostics()
      let diagnosticsMilliseconds =
        started.duration(to: clock.now).testMilliseconds
      started = clock.now
      _ = try await seededStore.checkpoint(.truncate)
      let checkpointMilliseconds =
        started.duration(to: clock.now).testMilliseconds
      started = clock.now
      _ = try await seededStore.pruneToMaximumBytes(
        policy.brokerPruneTargetBytes,
        batchLimit: 500,
        vacuumPageLimit: 64
      )
      let brokerDeleteMilliseconds =
        started.duration(to: clock.now).testMilliseconds
      started = clock.now
      _ = try await seededStore.pruneToMaximumBytes(
        policy.brokerPruneTargetBytes,
        batchLimit: 500,
        vacuumPageLimit: 64
      )
      let incrementalVacuumMilliseconds =
        started.duration(to: clock.now).testMilliseconds
      print(
        """
        phase diagnostic global-topic=\(globalTopicMilliseconds)ms \
        scoped-topic=\(scopedTopicMilliseconds)ms \
        diagnostics=\(diagnosticsMilliseconds)ms \
        checkpoint=\(checkpointMilliseconds)ms \
        broker-delete=\(brokerDeleteMilliseconds)ms \
        incremental-vacuum=\(incrementalVacuumMilliseconds)ms
        """
      )
    }
    seedStore = nil

    let writer = TimedPerformanceHistoryWriter(
      base: SQLiteBrokerHistoryWriter(
        databaseURL: databaseURL,
        retentionPolicy: policy
      )
    )
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "retention-repro",
      historyWriter: writer,
      policy: BrokerFeedIngestionPolicy(
        historyBatchSize: 128,
        historyFlushIntervalSeconds: 0.25,
        maximumSnapshotRate: 10
      ),
      retentionPolicy: policy
    )
    let epoch = ConnectionEpochID()
    let (source, continuation) = AsyncStream.makeStream(
      of: MQTTReceivedMessage.self
    )
    let producer = Task {
      let clock = ContinuousClock()
      let started = clock.now
      for index in 0..<1_000 {
        if index > 0, index % 16 == 0 {
          let deadline = started.advanced(
            by: .nanoseconds(Int64(index) * 600_000)
          )
          if clock.now < deadline {
            try await clock.sleep(until: deadline)
          }
        }
        continuation.yield(
          MQTTReceivedMessage(
            connectionEpoch: epoch,
            ordinal: UInt64(index + 1),
            topic: "live/\(index % 1_000)",
            payload: Data(repeating: 0xA5, count: 256),
            qos: JollysMQTTTransport.MQTTQualityOfService.atMostOnce,
            retained: false,
            duplicate: false,
            receivedAtMicroseconds: Int64(index)
          )
        )
      }
      continuation.finish()
    }
    let report = try await MQTTBoundedIngressAdapter(
      policy: MQTTIngressPolicy(
        capacity: 64,
        drainTimeout: .seconds(2)
      )
    ).consume(
      source,
      closeUpstream: { continuation.finish() },
      process: { message in
        await ingestion.ingest(
          BrokerInboundMessage(
            connectionEpoch: message.connectionEpoch,
            ordinal: message.ordinal,
            topic: message.topic,
            payload: message.payload,
            qos: .atMostOnce,
            retained: false,
            duplicate: false,
            receivedAtMicroseconds: message.receivedAtMicroseconds
          )
        )
      }
    )
    try await producer.value
    _ = await ingestion.flush()
    let timings = await writer.metrics()
    let drainedMetrics = await ingestion.metrics()
    await ingestion.shutdown()
    let shutdownMetrics = await ingestion.metrics()

    #expect(report.termination == .sourceFinished)
    #expect(report.processedMessageCount == 1_000)
    #expect(report.highWaterMark < 64)
    #expect(timings.writtenMessageCount == 1_000)
    #expect(drainedMetrics.pendingHistoryMessageCount == 0)
    #expect(
      drainedMetrics.historyQueueHighWaterMark
        <= BrokerFeedIngestionPolicy(historyBatchSize: 128)
        .historyQueueCapacity
    )
    #expect(
      drainedMetrics.historyQueuePayloadHighWaterMark
        <= policy.maximumAppendPayloadBytes * 2
    )
    #expect(shutdownMetrics.isShutdown)
    #expect(shutdownMetrics.pendingHistoryMessageCount == 0)
    #expect(shutdownMetrics.pendingHistoryPayloadByteCount == 0)
    if runsPhaseDiagnostic {
      print(
        "phase diagnostic maximum-writer-append=\(timings.maximumAppendMilliseconds)ms"
      )
    }
  }
}

private struct TimedPerformanceHistoryMetrics: Sendable {
  let writtenMessageCount: Int
  let maximumAppendMilliseconds: Double
}

private actor TimedPerformanceHistoryWriter: BrokerHistoryWriting {
  private let base: SQLiteBrokerHistoryWriter
  private var writtenMessageCount = 0
  private var maximumAppendMilliseconds = 0.0

  init(base: SQLiteBrokerHistoryWriter) {
    self.base = base
  }

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    let clock = ContinuousClock()
    let started = clock.now
    try await base.append(messages)
    writtenMessageCount += messages.count
    maximumAppendMilliseconds = max(
      maximumAppendMilliseconds,
      started.duration(to: clock.now).testMilliseconds
    )
  }

  func recordCoverageGap(
    _ gap: BrokerHistoryCoverageGap
  ) async throws {
    try await base.recordCoverageGap(gap)
  }

  func shutdown() async throws {
    try await base.shutdown()
  }

  func metrics() -> TimedPerformanceHistoryMetrics {
    TimedPerformanceHistoryMetrics(
      writtenMessageCount: writtenMessageCount,
      maximumAppendMilliseconds: maximumAppendMilliseconds
    )
  }
}

extension Duration {
  fileprivate var testMilliseconds: Double {
    let components = self.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}
