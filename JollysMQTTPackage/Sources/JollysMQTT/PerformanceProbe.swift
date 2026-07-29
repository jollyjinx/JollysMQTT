import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport

#if canImport(Darwin)
  import Darwin
#endif

public struct PerformanceProbeConfiguration: Sendable {
  public let fixture: PerformanceWorkloadFixture
  public let paceProducer: Bool
  public let ingressCapacity: Int
  public let publishQueueCapacity: Int
  public let postStopSampleCount: Int
  public let postStopSampleInterval: Duration

  public init(
    fixture: PerformanceWorkloadFixture = .standard,
    paceProducer: Bool = true,
    ingressCapacity: Int = 4_096,
    publishQueueCapacity: Int = 32,
    postStopSampleCount: Int = 10,
    postStopSampleInterval: Duration = .milliseconds(250)
  ) {
    precondition(ingressCapacity > 0)
    precondition(publishQueueCapacity > 0)
    precondition(postStopSampleCount >= 3)
    precondition(postStopSampleInterval >= .zero)
    self.fixture = fixture
    self.paceProducer = paceProducer
    self.ingressCapacity = ingressCapacity
    self.publishQueueCapacity = publishQueueCapacity
    self.postStopSampleCount = postStopSampleCount
    self.postStopSampleInterval = postStopSampleInterval
  }
}

public enum PerformanceProbeError: Error, Equatable, Sendable {
  case ingressOverloaded
  case incompleteIngestion(expected: Int, actual: Int)
  case incompleteHistory(expected: Int, actual: Int)
  case feedReleaseTimedOut
  case memoryMeasurementFailed
}

public struct JollysMQTTPerformanceProbe: Sendable {
  public init() {}

  public func run(
    _ configuration: PerformanceProbeConfiguration = .init()
  ) async throws -> PerformanceRunResult {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "jollysmqtt-performance-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let baselineResidentBytes = try residentBytes()
    let memoryRecorder = PerformanceMemoryRecorder(
      initialBytes: baselineResidentBytes
    )
    let memorySampler = Task {
      do {
        while !Task.isCancelled {
          await memoryRecorder.record(try residentBytes())
          try await Task.sleep(for: .milliseconds(10))
        }
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }

    do {
      let result = try await run(
        configuration,
        directory: directory,
        baselineResidentBytes: baselineResidentBytes,
        memoryRecorder: memoryRecorder
      )
      memorySampler.cancel()
      await memorySampler.value
      return result
    } catch {
      memorySampler.cancel()
      await memorySampler.value
      throw error
    }
  }

  private func run(
    _ configuration: PerformanceProbeConfiguration,
    directory: URL,
    baselineResidentBytes: UInt64,
    memoryRecorder: PerformanceMemoryRecorder
  ) async throws -> PerformanceRunResult {
    let fixture = configuration.fixture
    let databaseURL = directory.appending(path: "history.sqlite")
    let sqliteWriter = SQLiteBrokerHistoryWriter(databaseURL: databaseURL)
    let writer = PerformanceHistoryWriter(base: sqliteWriter)
    let brokerID = UUID()
    let historySourceID = "performance-\(brokerID.uuidString)"
    let ingestion = BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: historySourceID,
      historyWriter: writer,
      policy: BrokerFeedIngestionPolicy(
        historyBatchSize: 128,
        historyFlushIntervalSeconds: 0.25,
        maximumSnapshotRate: 10,
        maximumPayloadSummaryCharacters: 256
      )
    )
    let outlineObserver = await PerformanceOutlineObserver(
      expectedBrokerID: brokerID
    )
    let snapshotStream = await ingestion.snapshots()
    let snapshotObserver = Task {
      for await snapshot in snapshotStream {
        if Task.isCancelled { return }
        await outlineObserver.consume(snapshot)
      }
    }

    let epoch = ConnectionEpochID()
    await ingestion.beginConnectionEpoch(epoch)
    let (source, continuation) = AsyncStream.makeStream(
      of: MQTTReceivedMessage.self
    )
    let producer = Task {
      let clock = ContinuousClock()
      let started = clock.now
      let batchSize = 100
      for index in 0..<fixture.totalMessageCount {
        if configuration.paceProducer, index > 0,
          index % batchSize == 0
        {
          let expectedSeconds =
            Double(index) * 60 / Double(fixture.messagesPerMinute)
          let deadline = started.advanced(
            by: .nanoseconds(
              Int64(expectedSeconds * 1_000_000_000)
            )
          )
          if clock.now < deadline {
            try await clock.sleep(until: deadline)
          }
        }
        let fixtureMessage = fixture.message(at: index)
        let yieldResult = continuation.yield(
          MQTTReceivedMessage(
            connectionEpoch: epoch,
            ordinal: UInt64(index + 1),
            topic: fixtureMessage.topic,
            payload: fixtureMessage.payload,
            qos: JollysMQTTTransport.MQTTQualityOfService.atMostOnce,
            retained: false,
            duplicate: false,
            receivedAtMicroseconds: Int64(index)
          )
        )
        if case .terminated = yieldResult {
          return
        }
      }
      continuation.finish()
    }
    defer {
      producer.cancel()
      continuation.finish()
      snapshotObserver.cancel()
    }

    let clock = ContinuousClock()
    let ingestionStart = clock.now
    let ingressReport = try await MQTTBoundedIngressAdapter(
      policy: MQTTIngressPolicy(
        capacity: configuration.ingressCapacity,
        drainTimeout: .seconds(2)
      )
    ).consume(
      source,
      closeUpstream: {
        continuation.finish()
      },
      process: { message in
        await ingestion.ingest(
          BrokerInboundMessage(
            connectionEpoch: message.connectionEpoch,
            ordinal: message.ordinal,
            topic: message.topic,
            payload: message.payload,
            qos: .atMostOnce,
            retained: message.retained,
            duplicate: message.duplicate,
            receivedAtMicroseconds: message.receivedAtMicroseconds
          )
        )
      }
    )
    try await producer.value
    guard ingressReport.termination == .sourceFinished else {
      throw PerformanceProbeError.ingressOverloaded
    }
    let ingestionDuration = ingestionStart.duration(to: clock.now).seconds
    let finalSnapshot = await ingestion.flush()
    guard
      ingressReport.processedMessageCount == fixture.totalMessageCount
    else {
      throw PerformanceProbeError.incompleteIngestion(
        expected: fixture.totalMessageCount,
        actual: ingressReport.processedMessageCount
      )
    }
    await outlineObserver.wait(untilRevision: finalSnapshot.revision)
    let observedUpdateCount = await outlineObserver.updateCount
    let outlineUpdateCost = await outlineObserver.updateCost

    var snapshotDurations: [Double] = []
    for _ in 0..<10 {
      let started = clock.now
      _ = await ingestion.flush()
      snapshotDurations.append(
        started.duration(to: clock.now).milliseconds
      )
    }
    let interactionCosts = await outlineObserver.measureInteractions(
      finalSnapshot
    )
    let chartCost = measureChartCost(clock: clock)
    let publishQueueDepth = await measurePublishQueue(
      capacity: configuration.publishQueueCapacity
    )
    let preReleaseMetrics = await ingestion.metrics()
    let retentionReport = try await sqliteWriter.applyRetention()
    let historyWriteMetrics = await writer.metrics()
    guard
      historyWriteMetrics.writtenMessageCount
        == ingressReport.processedMessageCount
    else {
      throw PerformanceProbeError.incompleteHistory(
        expected: ingressReport.processedMessageCount,
        actual: historyWriteMetrics.writtenMessageCount
      )
    }

    let attempt = PerformanceFeedAttempt(ingestion: ingestion)
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 0,
      makeFeed: { _ in BrokerFeed(attempt: attempt) }
    )
    let lease = registry.makeLease(workspaceID: WorkspaceID())
    await lease.connect(
      BrokerFeedConfiguration(
        profile: BrokerProfile.new(
          id: brokerID,
          name: "Performance fixture",
          host: "localhost"
        ),
        credentialRevision: 0
      )
    )
    await lease.release()
    let feedOwnedStateReleased = try await waitForFeedRelease(
      ingestion: ingestion
    )
    snapshotObserver.cancel()
    await snapshotObserver.value

    let postStopSamples = try await postStopMemorySamples(
      configuration: configuration,
      recorder: memoryRecorder
    )
    let settledResidentBytes =
      postStopSamples.last ?? baselineResidentBytes
    let peakResidentBytes = await memoryRecorder.peakBytes
    let stabilizationRange =
      (postStopSamples.max() ?? settledResidentBytes)
      - (postStopSamples.min() ?? settledResidentBytes)
    let stabilizationAllowance = max(
      UInt64(8 * 1_024 * 1_024),
      peakResidentBytes / 50
    )

    return PerformanceRunResult(
      generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
      fixture: fixture,
      environment: performanceEnvironment(),
      elapsedSeconds: ingestionDuration,
      ingestedMessageCount: ingressReport.processedMessageCount,
      ingestMessagesPerSecond:
        Double(ingressReport.processedMessageCount)
        / max(ingestionDuration, .leastNonzeroMagnitude),
      historyWrittenMessageCount:
        historyWriteMetrics.writtenMessageCount,
      historyMessagesPerSecond:
        Double(historyWriteMetrics.writtenMessageCount)
        / max(
          historyWriteMetrics.appendSeconds,
          .leastNonzeroMagnitude
        ),
      historyDatabaseByteLimit:
        HistoryRetentionPolicy.default.brokerByteLimit,
      peakObservedHistoryDatabaseBytes: max(
        historyWriteMetrics.peakObservedDatabaseBytes,
        retentionReport.finalSQLiteBytes
      ),
      settledHistoryDatabaseBytes: retentionReport.finalSQLiteBytes,
      queueDepths: PerformanceQueueDepths(
        ingress: PerformanceQueueDepthSample(
          baseline: 0,
          highWaterMark: ingressReport.highWaterMark,
          settled: 0
        ),
        history: PerformanceQueueDepthSample(
          baseline: 0,
          highWaterMark: preReleaseMetrics.historyQueueHighWaterMark,
          settled: preReleaseMetrics.pendingHistoryMessageCount
        ),
        publish: publishQueueDepth
      ),
      mainActorUpdateCount: observedUpdateCount,
      mainActorUpdatesPerSecond:
        Double(observedUpdateCount)
        / max(ingestionDuration, .leastNonzeroMagnitude),
      snapshotCost: latencySummary(snapshotDurations),
      outlineUpdateCost: outlineUpdateCost,
      searchCost: interactionCosts.search,
      selectionCost: interactionCosts.selection,
      freezeViewCost: interactionCosts.freezeView,
      scrollPreparationCost: interactionCosts.scrollPreparation,
      chartCost: chartCost,
      baselineResidentBytes: baselineResidentBytes,
      peakResidentBytes: max(peakResidentBytes, baselineResidentBytes),
      settledResidentBytes: settledResidentBytes,
      postStopResidentByteSamples: postStopSamples,
      memoryStabilized: stabilizationRange <= stabilizationAllowance,
      feedOwnedStateReleased: feedOwnedStateReleased
    )
  }

  private func measurePublishQueue(
    capacity: Int
  ) async -> PerformanceQueueDepthSample {
    let queue = BrokerFeedPublishCommandQueue(capacity: capacity)
    let tasks = (0..<capacity).map { index in
      Task {
        await queue.submit(
          BrokerPublishRequest(
            operationID: PublishOperationID(),
            topic: "performance/publish/\(index)",
            payload: Data("value".utf8),
            qos: .atMostOnce,
            retain: false
          )
        )
      }
    }
    while await queue.pendingOperationCount() < capacity {
      await Task.yield()
    }
    var commands = await queue.commands().makeAsyncIterator()
    for _ in 0..<capacity {
      guard let command = await commands.next() else { break }
      await queue.complete(
        BrokerPublishSuccess(
          operationID: command.request.operationID,
          completion: .transportAccepted,
          completedAtMicroseconds: 0
        )
      )
    }
    for task in tasks {
      _ = await task.value
    }
    await queue.close()
    let metrics = await queue.performanceMetrics()
    return PerformanceQueueDepthSample(
      baseline: 0,
      highWaterMark: metrics.highWaterMark,
      settled: metrics.pendingOperationCount
    )
  }

  private func measureChartCost(
    clock: ContinuousClock
  ) -> PerformanceLatencySummary {
    let epoch = UUID()
    let samples = (0..<10_000).map { index in
      NumericChartSample(
        id: NumericChartSampleID(
          connectionEpoch: epoch,
          ordinal: UInt64(index),
          direction: .received
        ),
        receivedAtMicroseconds: Int64(index),
        value: sin(Double(index) / 100)
      )
    }
    var durations: [Double] = []
    for _ in 0..<10 {
      let started = clock.now
      _ = NumericChartDownsampler.downsample(
        samples,
        maximumSampleCount: 1_024
      )
      durations.append(started.duration(to: clock.now).milliseconds)
    }
    return latencySummary(durations)
  }

  private func waitForFeedRelease(
    ingestion: BrokerFeedIngestion
  ) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      let metrics = await ingestion.metrics()
      if metrics.isShutdown {
        return metrics.topicNodeCount == 0
          && metrics.retainedPayloadByteCount == 0
          && metrics.pendingHistoryMessageCount == 0
      }
      try await clock.sleep(for: .milliseconds(5))
    }
    throw PerformanceProbeError.feedReleaseTimedOut
  }

  private func postStopMemorySamples(
    configuration: PerformanceProbeConfiguration,
    recorder: PerformanceMemoryRecorder
  ) async throws -> [UInt64] {
    var samples: [UInt64] = []
    samples.reserveCapacity(configuration.postStopSampleCount)
    for index in 0..<configuration.postStopSampleCount {
      if index > 0 {
        try await Task.sleep(
          for: configuration.postStopSampleInterval
        )
      }
      let sample = try residentBytes()
      samples.append(sample)
      await recorder.record(sample)
    }
    return samples
  }
}

private actor PerformanceMemoryRecorder {
  private(set) var peakBytes: UInt64

  init(initialBytes: UInt64) {
    peakBytes = initialBytes
  }

  func record(_ bytes: UInt64) {
    peakBytes = max(peakBytes, bytes)
  }
}

private struct PerformanceHistoryWriteMetrics: Sendable {
  let writtenMessageCount: Int
  let appendSeconds: Double
  let peakObservedDatabaseBytes: Int64
}

private actor PerformanceHistoryWriter: BrokerHistoryWriting {
  private let base: SQLiteBrokerHistoryWriter
  private var writtenMessageCount = 0
  private var appendSeconds = 0.0
  private var peakObservedDatabaseBytes: Int64 = 0

  init(base: SQLiteBrokerHistoryWriter) {
    self.base = base
  }

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    let clock = ContinuousClock()
    let started = clock.now
    try await base.append(messages)
    appendSeconds += started.duration(to: clock.now).seconds
    writtenMessageCount += messages.count
    if case .succeeded(let report) = await base.maintenanceStatus() {
      peakObservedDatabaseBytes = max(
        peakObservedDatabaseBytes,
        report.finalSQLiteBytes
      )
    }
  }

  func recordCoverageGap(
    _ gap: BrokerHistoryCoverageGap
  ) async throws {
    try await base.recordCoverageGap(gap)
  }

  func shutdown() async throws {
    try await base.shutdown()
  }

  func metrics() -> PerformanceHistoryWriteMetrics {
    PerformanceHistoryWriteMetrics(
      writtenMessageCount: writtenMessageCount,
      appendSeconds: appendSeconds,
      peakObservedDatabaseBytes: peakObservedDatabaseBytes
    )
  }
}

@MainActor
private final class PerformanceOutlineObserver {
  private var state: TopicOutlineFeature.State
  private var updateDurations: [Double] = []
  private var latestRevision: UInt64 = 0
  private(set) var updateCount = 0
  private var scrollChecksum = 0

  init(expectedBrokerID: UUID) {
    state = TopicOutlineFeature.State(
      expectedBrokerID: expectedBrokerID
    )
  }

  func consume(_ snapshot: BrokerTopicTreeSnapshot) {
    guard snapshot.revision > 0 else { return }
    let clock = ContinuousClock()
    let started = clock.now
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )
    updateDurations.append(
      started.duration(to: clock.now).milliseconds
    )
    latestRevision = max(latestRevision, snapshot.revision)
    updateCount += 1
  }

  var updateCost: PerformanceLatencySummary {
    latencySummary(
      updateDurations.isEmpty ? [0] : updateDurations
    )
  }

  func wait(untilRevision revision: UInt64) async {
    while latestRevision < revision {
      await Task.yield()
    }
  }

  func measureInteractions(
    _ snapshot: BrokerTopicTreeSnapshot
  ) -> PerformanceInteractionCosts {
    if latestRevision < snapshot.revision {
      consume(snapshot)
    }
    let clock = ContinuousClock()
    var search: [Double] = []
    var selection: [Double] = []
    var freezeView: [Double] = []
    var scrollPreparation: [Double] = []
    for _ in 0..<10 {
      var started = clock.now
      TopicOutlineFeature.reduce(
        state: &state,
        intent: .setSearchText("telemetry")
      )
      search.append(started.duration(to: clock.now).milliseconds)

      if let row = state.rows.last {
        started = clock.now
        TopicOutlineFeature.reduce(
          state: &state,
          intent: .selectTopic(row.id)
        )
        selection.append(started.duration(to: clock.now).milliseconds)
      } else {
        selection.append(0)
      }

      started = clock.now
      TopicOutlineFeature.reduce(state: &state, intent: .freezeView)
      TopicOutlineFeature.reduce(
        state: &state,
        action: .snapshotReceived(snapshot)
      )
      TopicOutlineFeature.reduce(state: &state, intent: .jumpToLive)
      freezeView.append(started.duration(to: clock.now).milliseconds)

      started = clock.now
      for row in state.rows {
        scrollChecksum &+= row.depth
        scrollChecksum &+= row.fullTopic.utf8.count
      }
      scrollPreparation.append(
        started.duration(to: clock.now).milliseconds
      )
      TopicOutlineFeature.reduce(
        state: &state,
        intent: .setSearchText("")
      )
    }
    precondition(scrollChecksum >= 0)
    return PerformanceInteractionCosts(
      search: latencySummary(search),
      selection: latencySummary(selection),
      freezeView: latencySummary(freezeView),
      scrollPreparation: latencySummary(scrollPreparation)
    )
  }
}

private struct PerformanceInteractionCosts: Sendable {
  let search: PerformanceLatencySummary
  let selection: PerformanceLatencySummary
  let freezeView: PerformanceLatencySummary
  let scrollPreparation: PerformanceLatencySummary
}

private actor PerformanceFeedAttempt: BrokerFeedAttempting {
  private let ingestion: BrokerFeedIngestion

  init(ingestion: BrokerFeedIngestion) {
    self.ingestion = ingestion
  }

  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws {
    await events.connecting()
    await events.subscribing()
    await events.connected()
    try await Task.sleep(for: .seconds(3_600))
  }

  func closeActiveConnection() {}

  func shutdownOwnedWork() async {
    await ingestion.shutdown()
  }
}

private func latencySummary(
  _ milliseconds: [Double]
) -> PerformanceLatencySummary {
  precondition(!milliseconds.isEmpty)
  let sorted = milliseconds.sorted()
  let median = sorted[(sorted.count - 1) / 2]
  let p95Index = min(
    sorted.count - 1,
    max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
  )
  return PerformanceLatencySummary(
    sampleCount: sorted.count,
    medianMilliseconds: median,
    p95Milliseconds: sorted[p95Index],
    maximumMilliseconds: sorted.last ?? 0
  )
}

private func residentBytes() throws -> UInt64 {
  #if canImport(Darwin)
    var information = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size
        / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &information) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          $0,
          &count
        )
      }
    }
    guard result == KERN_SUCCESS else {
      throw PerformanceProbeError.memoryMeasurementFailed
    }
    return UInt64(information.resident_size)
  #else
    throw PerformanceProbeError.memoryMeasurementFailed
  #endif
}

private func performanceEnvironment() -> PerformanceEnvironment {
  PerformanceEnvironment(
    hardwareModel: performanceHardwareModel(),
    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
    architecture: performanceArchitecture,
    buildConfiguration: performanceBuildConfiguration,
    xcodeVersion: performanceXcodeVersion()
  )
}

private func performanceHardwareModel() -> String {
  #if canImport(Darwin)
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else {
      return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
      return "unknown"
    }
    return String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
  #else
    return "unknown"
  #endif
}

private var performanceArchitecture: String {
  #if arch(arm64)
    "arm64"
  #elseif arch(x86_64)
    "x86_64"
  #else
    "unknown"
  #endif
}

private var performanceBuildConfiguration: String {
  #if DEBUG
    "debug"
  #else
    "release"
  #endif
}

private func performanceXcodeVersion() -> String {
  #if os(macOS)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/xcodebuild")
    process.arguments = ["-version"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      let data = try output.fileHandleForReading.readToEnd() ?? Data()
      return String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: "; ")
    } catch {
      return "unknown"
    }
  #else
    return "unavailable on device"
  #endif
}

extension Duration {
  fileprivate var milliseconds: Double {
    let components = self.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  fileprivate var seconds: Double {
    let components = self.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }
}
