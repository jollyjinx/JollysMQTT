#if os(macOS)
  import Darwin
  import Foundation
  import JollysMQTTStorage

  @main
  struct JollysMQTTStorageProbe {
    static func main() async throws {
      let configuration = try ProbeConfiguration.environment()
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "JollysMQTTStorageProbe-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: directory) }

      let report = try await run(configuration: configuration, in: directory)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let encoded = try encoder.encode(report)
      FileHandle.standardOutput.write(encoded)
      FileHandle.standardOutput.write(Data([0x0A]))

      guard report.targetRatePassed,
        report.insertedMessages == configuration.messageCount,
        report.queueHighWaterMark == configuration.queueCapacity,
        report.queueHighWaterMessageCount > 0,
        report.queueHighWaterMessageCount
          <= configuration.queueCapacity * configuration.batchSize,
        report.queueProducerSuspensionCount > 0,
        report.peakBrokerSizePassed,
        report.independentPeakBrokerSizePassed,
        report.periodicMaintenanceConverged,
        report.perTopicRetentionConverged,
        report.brokerSizeRetentionConverged,
        report.settledOrphanTopicCount == 0,
        report.recoveryPassed
      else {
        throw ProbeFailure.acceptanceGateFailed
      }
    }

    private static func run(
      configuration: ProbeConfiguration,
      in directory: URL
    ) async throws -> ProbeReport {
      let databaseURL = directory.appending(path: "history.sqlite")
      let footprintSampler = IndependentSQLiteFootprintSampler(
        databaseURL: databaseURL
      )
      let footprintSamplingTask = Task {
        await footprintSampler.run()
      }
      defer { footprintSamplingTask.cancel() }
      let queue = BoundedBatchQueue(capacity: configuration.queueCapacity)
      let payload = Data((0..<configuration.payloadBytes).map { UInt8($0 & 0xFF) })
      let store = try await SQLiteHistoryStore.open(databaseURL: databaseURL)
      let before = try await store.diagnostics()
      let clock = ContinuousClock()

      let producer = Task {
        var batchStart = 0
        while batchStart < configuration.messageCount {
          let batchEnd = min(
            configuration.messageCount,
            batchStart + configuration.batchSize
          )
          var batch: [HistoryMessageInput] = []
          batch.reserveCapacity(batchEnd - batchStart)
          for messageIndex in batchStart..<batchEnd {
            let topicIndex: Int
            if messageIndex < configuration.messageCount / 2 {
              topicIndex = messageIndex % configuration.topicCount
            } else {
              topicIndex = messageIndex % configuration.hotTopicCount
            }
            batch.append(
              HistoryMessageInput(
                historySourceID: "deterministic-source",
                topic: "fixture/topic/\(topicIndex)",
                receivedAtMicroseconds: Int64(messageIndex),
                payload: payload
              )
            )
          }
          guard await queue.enqueue(batch) else {
            await queue.finish()
            return
          }
          batchStart = batchEnd
        }
        await queue.finish()
      }

      let insertionStart = clock.now
      var insertedMessages = 0
      var batchCount = 0
      var peakSQLiteBytes = before.totalSQLiteBytes
      var peakDatabaseBytes = before.databaseBytes
      var peakWriteAheadLogBytes = before.writeAheadLogBytes
      var peakSharedMemoryBytes = before.sharedMemoryBytes
      var maintenanceCycles = 0
      var maintenanceIterations = 0
      var maintenanceDeletedMessages = 0
      var maintenanceDeletedTopics = 0
      var maintenanceConverged = true
      do {
        while let batch = await queue.next() {
          let result = try await store.append(batch)
          insertedMessages += result.insertedCount
          batchCount += 1
          let sample = await store.fileSizes()
          peakSQLiteBytes = max(peakSQLiteBytes, sample.totalSQLiteBytes)
          peakDatabaseBytes = max(peakDatabaseBytes, sample.databaseBytes)
          peakWriteAheadLogBytes = max(
            peakWriteAheadLogBytes,
            sample.writeAheadLogBytes
          )
          peakSharedMemoryBytes = max(
            peakSharedMemoryBytes,
            sample.sharedMemoryBytes
          )
          if sample.totalSQLiteBytes >= configuration.maintenanceTriggerBytes {
            maintenanceCycles += 1
            maintenanceConverged = false
            for _ in 0..<configuration.maximumPruneIterations {
              let maintenance = try await store.pruneToMaximumBytes(
                configuration.maintenanceTargetBytes,
                batchLimit: configuration.pruneBatchSize,
                vacuumPageLimit: configuration.vacuumPageLimit
              )
              maintenanceIterations += 1
              maintenanceDeletedMessages += maintenance.deletedCount
              maintenanceDeletedTopics += maintenance.deletedTopicCount
              if maintenance.targetReached {
                maintenanceConverged = true
                break
              }
              if maintenance.requiresMorePruning == false {
                break
              }
            }
            guard maintenanceConverged else {
              throw ProbeFailure.periodicMaintenanceDidNotConverge
            }
          }
        }
      } catch {
        producer.cancel()
        await queue.finish()
        await producer.value
        throw error
      }
      await producer.value
      let insertionDuration = insertionStart.duration(to: clock.now)
      let inserted = try await store.diagnostics()
      peakSQLiteBytes = max(peakSQLiteBytes, inserted.totalSQLiteBytes)
      peakDatabaseBytes = max(peakDatabaseBytes, inserted.databaseBytes)
      peakWriteAheadLogBytes = max(
        peakWriteAheadLogBytes,
        inserted.writeAheadLogBytes
      )
      peakSharedMemoryBytes = max(
        peakSharedMemoryBytes,
        inserted.sharedMemoryBytes
      )

      let beforePassive = try await store.diagnostics()
      let passive = try await store.checkpoint(.passive)
      let afterPassive = try await store.diagnostics()
      let truncate = try await store.checkpoint(.truncate)
      let afterTruncate = try await store.diagnostics()

      let pruneStart = clock.now
      var perTopicDeleted = 0
      var perTopicIterations = 0
      var perTopicConverged = false
      while perTopicIterations < configuration.maximumPruneIterations {
        let result = try await store.prune(
          keepingNewestPerTopic: configuration.entriesPerTopic,
          batchLimit: configuration.pruneBatchSize
        )
        perTopicDeleted += result.deletedCount
        perTopicIterations += 1
        if result.deletedCount == 0 {
          perTopicConverged = true
          break
        }
      }

      var sizeIterations = 0
      var sizeDeleted = 0
      var sizeDeletedTopics = 0
      var lastSizePrune: HistorySizePruneResult?
      while sizeIterations < configuration.maximumPruneIterations {
        let result = try await store.pruneToMaximumBytes(
          configuration.maximumBrokerBytes,
          batchLimit: configuration.pruneBatchSize,
          vacuumPageLimit: configuration.vacuumPageLimit
        )
        lastSizePrune = result
        sizeDeleted += result.deletedCount
        sizeDeletedTopics += result.deletedTopicCount
        sizeIterations += 1
        if result.targetReached || result.requiresMorePruning == false {
          break
        }
      }
      let pruneDuration = pruneStart.duration(to: clock.now)
      _ = try await store.checkpoint(.truncate)
      let settled = try await store.diagnostics()

      let queueMetrics = await queue.metrics()
      let recoveryPassed = try await runRecoveryFixture(
        at: directory.appending(path: "recovery.sqlite")
      )
      footprintSamplingTask.cancel()
      await footprintSamplingTask.value
      let independentFootprint = await footprintSampler.metrics()
      let insertionSeconds = insertionDuration.seconds
      let messagesPerSecond =
        insertionSeconds > 0
        ? Double(insertedMessages) / insertionSeconds
        : 0
      let sizeConverged =
        lastSizePrune?.targetReached
        ?? (settled.totalSQLiteBytes <= configuration.maximumBrokerBytes)

      return ProbeReport(
        generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
        hardwareModel: hardwareModel(),
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: commandOutput(
          executable: "/usr/bin/uname",
          arguments: ["-m"]
        ),
        xcodeVersion: commandOutput(
          executable: "/usr/bin/xcodebuild",
          arguments: ["-version"]
        ).replacingOccurrences(of: "\n", with: "; "),
        buildConfiguration: buildConfiguration,
        sqliteVersion: StorageModule.sqliteVersion,
        schemaVersion: inserted.schemaVersion,
        journalMode: inserted.journalMode,
        autoVacuumMode: inserted.autoVacuumMode.rawValue,
        targetMessagesPerMinute: configuration.targetMessagesPerMinute,
        targetDurationMinutes: configuration.targetDurationMinutes,
        configuredMessages: configuration.messageCount,
        insertedMessages: insertedMessages,
        payloadBytes: configuration.payloadBytes,
        topicCount: configuration.topicCount,
        hotTopicCount: configuration.hotTopicCount,
        batchSize: configuration.batchSize,
        transactionCount: batchCount,
        queueCapacity: configuration.queueCapacity,
        queueHighWaterMark: queueMetrics.highWaterMark,
        queueHighWaterMessageCount: queueMetrics.highWaterMessageCount,
        queueProducerSuspensionCount: queueMetrics.producerSuspensionCount,
        insertionSeconds: insertionSeconds,
        messagesPerSecond: messagesPerSecond,
        targetRatePassed:
          messagesPerSecond >= Double(configuration.targetMessagesPerMinute) / 60,
        peakSQLiteBytes: peakSQLiteBytes,
        peakDatabaseBytes: peakDatabaseBytes,
        peakWriteAheadLogBytes: peakWriteAheadLogBytes,
        peakSharedMemoryBytes: peakSharedMemoryBytes,
        walBytesBeforePassive: beforePassive.writeAheadLogBytes,
        passiveCheckpointWasBusy: passive.wasBusy,
        passiveWalFrames: passive.writeAheadLogFrameCount,
        passiveCheckpointedFrames: passive.checkpointedFrameCount,
        walBytesAfterPassive: afterPassive.writeAheadLogBytes,
        truncateCheckpointWasBusy: truncate.wasBusy,
        walBytesAfterTruncate: afterTruncate.writeAheadLogBytes,
        entriesPerTopic: configuration.entriesPerTopic,
        perTopicPruneBatchSize: configuration.pruneBatchSize,
        perTopicPruneIterations: perTopicIterations,
        perTopicDeletedMessages: perTopicDeleted,
        perTopicRetentionConverged: perTopicConverged,
        maximumBrokerBytes: configuration.maximumBrokerBytes,
        maintenanceTriggerBytes: configuration.maintenanceTriggerBytes,
        maintenanceTargetBytes: configuration.maintenanceTargetBytes,
        periodicMaintenanceCycles: maintenanceCycles,
        periodicMaintenanceIterations: maintenanceIterations,
        periodicMaintenanceDeletedMessages: maintenanceDeletedMessages,
        periodicMaintenanceDeletedTopics: maintenanceDeletedTopics,
        periodicMaintenanceConverged: maintenanceConverged,
        peakBrokerSizePassed:
          peakSQLiteBytes <= configuration.maximumBrokerBytes,
        independentSamplerIntervalMilliseconds: 1,
        independentSampleCount: independentFootprint.sampleCount,
        independentPeakSQLiteBytes: independentFootprint.peakSQLiteBytes,
        independentPeakBrokerSizePassed:
          independentFootprint.peakSQLiteBytes
          <= configuration.maximumBrokerBytes,
        sizePruneIterations: sizeIterations,
        sizeDeletedMessages: sizeDeleted,
        sizeDeletedTopics: sizeDeletedTopics,
        brokerSizeRetentionConverged: sizeConverged,
        pruneSeconds: pruneDuration.seconds,
        settledMessageCount: settled.messageCount,
        settledTopicCount: settled.topicCount,
        settledOrphanTopicCount: settled.orphanTopicCount,
        settledDatabaseBytes: settled.databaseBytes,
        settledWriteAheadLogBytes: settled.writeAheadLogBytes,
        settledSharedMemoryBytes: settled.sharedMemoryBytes,
        settledSQLiteBytes: settled.totalSQLiteBytes,
        settledFreePageCount: settled.freePageCount,
        recoveryPassed: recoveryPassed
      )
    }

    private static func runRecoveryFixture(at databaseURL: URL) async throws -> Bool {
      var initialStore: SQLiteHistoryStore? = try await SQLiteHistoryStore.open(
        databaseURL: databaseURL
      )
      _ = try await initialStore?.append([
        HistoryMessageInput(
          historySourceID: "recovery-source",
          topic: "recovery",
          receivedAtMicroseconds: 1,
          payload: Data([1])
        )
      ])
      initialStore = nil

      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/sqlite3")
      process.arguments = [
        databaseURL.path,
        """
        BEGIN IMMEDIATE;
        INSERT INTO messages(topic_id, received_at_microseconds, payload)
          SELECT id, 2, X'02' FROM topics
          WHERE history_source_id = 'recovery-source' AND topic = 'recovery';
        WITH RECURSIVE delay(value) AS (
          VALUES(0)
          UNION ALL
          SELECT value + 1 FROM delay WHERE value < 1000000000
        )
        SELECT sum(value) FROM delay;
        COMMIT;
        """,
      ]
      try process.run()
      try await Task.sleep(for: .milliseconds(100))
      guard process.isRunning else {
        throw ProbeFailure.recoveryChildExitedBeforeInterruption
      }
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      guard process.terminationReason == .uncaughtSignal,
        process.terminationStatus == SIGKILL
      else {
        throw ProbeFailure.recoveryChildWasNotKilled
      }

      let recovered = try await SQLiteHistoryStore.open(databaseURL: databaseURL)
      guard try await recovered.integrityCheck() == "ok",
        try await recovered.diagnostics().messageCount == 1
      else {
        return false
      }
      _ = try await recovered.append([
        HistoryMessageInput(
          historySourceID: "recovery-source",
          topic: "recovery",
          receivedAtMicroseconds: 3,
          payload: Data([3])
        )
      ])
      let messages = try await recovered.newestMessages(
        historySourceID: "recovery-source",
        topic: "recovery",
        limit: 10
      )
      return messages.map(\.payload) == [Data([3]), Data([1])]
    }
  }

  private struct ProbeConfiguration: Sendable {
    let targetMessagesPerMinute = 100_000
    let targetDurationMinutes = 10
    let messageCount: Int
    let payloadBytes: Int
    let topicCount: Int
    let hotTopicCount: Int
    let batchSize: Int
    let queueCapacity: Int
    let entriesPerTopic: Int
    let pruneBatchSize: Int
    let maximumBrokerBytes: Int64
    let maintenanceTriggerBytes: Int64
    let maintenanceTargetBytes: Int64
    let vacuumPageLimit: Int
    let maximumPruneIterations: Int

    static func environment() throws -> Self {
      let values = ProcessInfo.processInfo.environment
      let messageCount = try positiveInt(
        values["JOLLYSMQTT_STORAGE_PROBE_MESSAGES"],
        default: 1_000_000
      )
      let topicCount = try positiveInt(
        values["JOLLYSMQTT_STORAGE_PROBE_TOPICS"],
        default: 10_000
      )
      let hotTopicCount = try positiveInt(
        values["JOLLYSMQTT_STORAGE_PROBE_HOT_TOPICS"],
        default: 100
      )
      guard hotTopicCount <= topicCount else {
        throw ProbeFailure.invalidConfiguration
      }
      let maximumBrokerBytes =
        Int64(
          try positiveInt(
            values["JOLLYSMQTT_STORAGE_PROBE_MAXIMUM_MIB"],
            default: 250
          )
        ) * 1_024 * 1_024
      return Self(
        messageCount: messageCount,
        payloadBytes: try positiveInt(
          values["JOLLYSMQTT_STORAGE_PROBE_PAYLOAD_BYTES"],
          default: 256
        ),
        topicCount: topicCount,
        hotTopicCount: hotTopicCount,
        batchSize: try positiveInt(
          values["JOLLYSMQTT_STORAGE_PROBE_BATCH_SIZE"],
          default: 500
        ),
        queueCapacity: try positiveInt(
          values["JOLLYSMQTT_STORAGE_PROBE_QUEUE_CAPACITY"],
          default: 8
        ),
        entriesPerTopic: try positiveInt(
          values["JOLLYSMQTT_STORAGE_PROBE_ENTRIES_PER_TOPIC"],
          default: 1_000
        ),
        pruneBatchSize: try positiveInt(
          values["JOLLYSMQTT_STORAGE_PROBE_PRUNE_BATCH_SIZE"],
          default: 5_000
        ),
        maximumBrokerBytes: maximumBrokerBytes,
        maintenanceTriggerBytes: maximumBrokerBytes * 3 / 5,
        maintenanceTargetBytes: maximumBrokerBytes / 2,
        vacuumPageLimit: try positiveInt(
          values["JOLLYSMQTT_STORAGE_PROBE_VACUUM_PAGES"],
          default: 8_192
        ),
        maximumPruneIterations: try positiveInt(
          values["JOLLYSMQTT_STORAGE_PROBE_MAXIMUM_PRUNE_ITERATIONS"],
          default: 128
        )
      )
    }

    private static func positiveInt(_ value: String?, default fallback: Int) throws -> Int {
      guard let value else { return fallback }
      guard let parsed = Int(value), parsed > 0 else {
        throw ProbeFailure.invalidConfiguration
      }
      return parsed
    }
  }

  private actor BoundedBatchQueue {
    struct Metrics: Sendable {
      let highWaterMark: Int
      let highWaterMessageCount: Int
      let producerSuspensionCount: Int
    }

    private let capacity: Int
    private var batches: [[HistoryMessageInput]] = []
    private var finished = false
    private var consumerWaiter:
      (
        id: UUID,
        continuation: CheckedContinuation<Void, Never>
      )?
    private var producerWaiter:
      (
        id: UUID,
        continuation: CheckedContinuation<Void, Never>
      )?
    private var highWaterMark = 0
    private var queuedMessageCount = 0
    private var highWaterMessageCount = 0
    private var producerSuspensionCount = 0

    init(capacity: Int) {
      self.capacity = capacity
      batches.reserveCapacity(capacity)
    }

    func enqueue(_ batch: [HistoryMessageInput]) async -> Bool {
      while batches.count >= capacity {
        guard finished == false, Task.isCancelled == false else {
          return false
        }
        producerSuspensionCount += 1
        await waitForProducerSpace()
      }
      guard finished == false, Task.isCancelled == false else { return false }
      batches.append(batch)
      queuedMessageCount += batch.count
      highWaterMark = max(highWaterMark, batches.count)
      highWaterMessageCount = max(
        highWaterMessageCount,
        queuedMessageCount
      )
      resumeConsumerWaiter()
      return true
    }

    func next() async -> [HistoryMessageInput]? {
      while batches.isEmpty {
        if finished { return nil }
        await waitForConsumerData()
        if Task.isCancelled { return nil }
      }
      let batch = batches.removeFirst()
      queuedMessageCount -= batch.count
      resumeProducerWaiter()
      return batch
    }

    func finish() {
      finished = true
      resumeConsumerWaiter()
      resumeProducerWaiter()
    }

    func metrics() -> Metrics {
      Metrics(
        highWaterMark: highWaterMark,
        highWaterMessageCount: highWaterMessageCount,
        producerSuspensionCount: producerSuspensionCount
      )
    }

    private func waitForConsumerData() async {
      let id = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled || batches.isEmpty == false || finished {
            continuation.resume()
          } else {
            consumerWaiter = (id, continuation)
          }
        }
      } onCancel: {
        Task { await self.cancelConsumerWaiter(id: id) }
      }
    }

    private func waitForProducerSpace() async {
      let id = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled || batches.count < capacity || finished {
            continuation.resume()
          } else {
            producerWaiter = (id, continuation)
          }
        }
      } onCancel: {
        Task { await self.cancelProducerWaiter(id: id) }
      }
    }

    private func cancelConsumerWaiter(id: UUID) {
      guard consumerWaiter?.id == id else { return }
      resumeConsumerWaiter()
    }

    private func cancelProducerWaiter(id: UUID) {
      guard producerWaiter?.id == id else { return }
      resumeProducerWaiter()
    }

    private func resumeConsumerWaiter() {
      let continuation = consumerWaiter?.continuation
      consumerWaiter = nil
      continuation?.resume()
    }

    private func resumeProducerWaiter() {
      let continuation = producerWaiter?.continuation
      producerWaiter = nil
      continuation?.resume()
    }
  }

  private struct ProbeReport: Encodable {
    let generatedAtUTC: String
    let hardwareModel: String
    let operatingSystem: String
    let architecture: String
    let xcodeVersion: String
    let buildConfiguration: String
    let sqliteVersion: String
    let schemaVersion: Int
    let journalMode: String
    let autoVacuumMode: Int32
    let targetMessagesPerMinute: Int
    let targetDurationMinutes: Int
    let configuredMessages: Int
    let insertedMessages: Int
    let payloadBytes: Int
    let topicCount: Int
    let hotTopicCount: Int
    let batchSize: Int
    let transactionCount: Int
    let queueCapacity: Int
    let queueHighWaterMark: Int
    let queueHighWaterMessageCount: Int
    let queueProducerSuspensionCount: Int
    let insertionSeconds: Double
    let messagesPerSecond: Double
    let targetRatePassed: Bool
    let peakSQLiteBytes: Int64
    let peakDatabaseBytes: Int64
    let peakWriteAheadLogBytes: Int64
    let peakSharedMemoryBytes: Int64
    let walBytesBeforePassive: Int64
    let passiveCheckpointWasBusy: Bool
    let passiveWalFrames: Int
    let passiveCheckpointedFrames: Int
    let walBytesAfterPassive: Int64
    let truncateCheckpointWasBusy: Bool
    let walBytesAfterTruncate: Int64
    let entriesPerTopic: Int
    let perTopicPruneBatchSize: Int
    let perTopicPruneIterations: Int
    let perTopicDeletedMessages: Int
    let perTopicRetentionConverged: Bool
    let maximumBrokerBytes: Int64
    let maintenanceTriggerBytes: Int64
    let maintenanceTargetBytes: Int64
    let periodicMaintenanceCycles: Int
    let periodicMaintenanceIterations: Int
    let periodicMaintenanceDeletedMessages: Int
    let periodicMaintenanceDeletedTopics: Int
    let periodicMaintenanceConverged: Bool
    let peakBrokerSizePassed: Bool
    let independentSamplerIntervalMilliseconds: Int
    let independentSampleCount: Int
    let independentPeakSQLiteBytes: Int64
    let independentPeakBrokerSizePassed: Bool
    let sizePruneIterations: Int
    let sizeDeletedMessages: Int
    let sizeDeletedTopics: Int
    let brokerSizeRetentionConverged: Bool
    let pruneSeconds: Double
    let settledMessageCount: Int
    let settledTopicCount: Int
    let settledOrphanTopicCount: Int
    let settledDatabaseBytes: Int64
    let settledWriteAheadLogBytes: Int64
    let settledSharedMemoryBytes: Int64
    let settledSQLiteBytes: Int64
    let settledFreePageCount: Int
    let recoveryPassed: Bool
  }

  private actor IndependentSQLiteFootprintSampler {
    struct Metrics: Sendable {
      let sampleCount: Int
      let peakSQLiteBytes: Int64
    }

    private let databaseURL: URL
    private var sampleCount = 0
    private var peakSQLiteBytes: Int64 = 0

    init(databaseURL: URL) {
      self.databaseURL = databaseURL
    }

    func run() async {
      while Task.isCancelled == false {
        sample()
        try? await Task.sleep(for: .milliseconds(1))
      }
      sample()
    }

    func metrics() -> Metrics {
      Metrics(
        sampleCount: sampleCount,
        peakSQLiteBytes: peakSQLiteBytes
      )
    }

    private func sample() {
      let sizes = HistoryFileSizes.measure(databaseURL: databaseURL)
      sampleCount += 1
      peakSQLiteBytes = max(peakSQLiteBytes, sizes.totalSQLiteBytes)
    }
  }

  private enum ProbeFailure: Error {
    case invalidConfiguration
    case acceptanceGateFailed
    case recoveryChildExitedBeforeInterruption
    case recoveryChildWasNotKilled
    case periodicMaintenanceDidNotConverge
  }

  private var buildConfiguration: String {
    #if DEBUG
      "debug"
    #else
      "release"
    #endif
  }

  private func commandOutput(executable: String, arguments: [String]) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return "unavailable" }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      return String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return "unavailable"
    }
  }

  private func hardwareModel() -> String {
    var byteCount = 0
    guard sysctlbyname("hw.model", nil, &byteCount, nil, 0) == 0,
      byteCount > 0
    else {
      return "unavailable"
    }
    var bytes = [CChar](repeating: 0, count: byteCount)
    guard sysctlbyname("hw.model", &bytes, &byteCount, nil, 0) == 0 else {
      return "unavailable"
    }
    let contentEnd = bytes.firstIndex(of: 0) ?? bytes.endIndex
    return bytes[..<contentEnd].withUnsafeBytes {
      String(decoding: $0, as: UTF8.self)
    }
  }

  extension Duration {
    fileprivate var seconds: Double {
      let components = self.components
      return Double(components.seconds)
        + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
  }
#else
  import Foundation

  @main
  struct JollysMQTTStorageProbe {
    static func main() throws {
      throw UnsupportedPlatform()
    }
  }

  private struct UnsupportedPlatform: Error {}
#endif
