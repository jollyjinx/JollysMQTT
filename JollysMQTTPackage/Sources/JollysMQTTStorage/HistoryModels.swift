import Foundation
import JollysMQTTCore

public struct HistoryTopicRetentionScope:
  Hashable,
  Sendable
{
  public let historySourceID: String
  public let topic: String

  public init(historySourceID: String, topic: String) {
    self.historySourceID = historySourceID
    self.topic = topic
  }
}

public struct HistoryMessageInput: Sendable, Equatable {
  public let historySourceID: String
  public let connectionEpoch: UUID?
  public let connectionOrdinal: UInt64?
  public let operationID: PublishOperationID?
  public let direction: PayloadDeliveryDirection
  public let topic: String
  public let qos: MQTTQualityOfService
  public let retained: Bool
  public let receivedAtMicroseconds: Int64
  public let payload: Data
  public let payloadStorage: HistoryPayloadStorage

  public init(
    historySourceID: String,
    connectionEpoch: UUID? = nil,
    connectionOrdinal: UInt64? = nil,
    operationID: PublishOperationID? = nil,
    direction: PayloadDeliveryDirection = .received,
    topic: String,
    qos: MQTTQualityOfService = .atMostOnce,
    retained: Bool = false,
    receivedAtMicroseconds: Int64,
    payload: Data,
    payloadStorage: HistoryPayloadStorage = .stored
  ) {
    self.historySourceID = historySourceID
    self.connectionEpoch = connectionEpoch
    self.connectionOrdinal = connectionOrdinal
    self.operationID = operationID
    self.direction = direction
    self.topic = topic
    self.qos = qos
    self.retained = retained
    self.receivedAtMicroseconds = receivedAtMicroseconds
    self.payload = payload
    self.payloadStorage = payloadStorage
  }
}

public enum HistoryPayloadStorage: Sendable, Equatable {
  case stored
  case omittedByRetentionLimit(originalByteCount: Int)

  public var originalByteCount: Int? {
    guard case .omittedByRetentionLimit(let byteCount) = self else {
      return nil
    }
    return byteCount
  }
}

public struct StoredHistoryMessage: Sendable, Equatable {
  public let durableOrder: Int64
  public let historySourceID: String
  public let connectionEpoch: UUID?
  public let connectionOrdinal: UInt64?
  public let operationID: PublishOperationID?
  public let direction: PayloadDeliveryDirection
  public let topic: String
  public let qos: MQTTQualityOfService
  public let retained: Bool
  public let receivedAtMicroseconds: Int64
  public let payload: Data
  public let payloadStorage: HistoryPayloadStorage

  public init(
    durableOrder: Int64,
    historySourceID: String,
    connectionEpoch: UUID?,
    connectionOrdinal: UInt64?,
    operationID: PublishOperationID?,
    direction: PayloadDeliveryDirection,
    topic: String,
    qos: MQTTQualityOfService,
    retained: Bool,
    receivedAtMicroseconds: Int64,
    payload: Data,
    payloadStorage: HistoryPayloadStorage = .stored
  ) {
    self.durableOrder = durableOrder
    self.historySourceID = historySourceID
    self.connectionEpoch = connectionEpoch
    self.connectionOrdinal = connectionOrdinal
    self.operationID = operationID
    self.direction = direction
    self.topic = topic
    self.qos = qos
    self.retained = retained
    self.receivedAtMicroseconds = receivedAtMicroseconds
    self.payload = payload
    self.payloadStorage = payloadStorage
  }

  public var originalPayloadByteCount: Int {
    payloadStorage.originalByteCount ?? payload.count
  }

  public var hasStoredPayload: Bool {
    payloadStorage == .stored
  }
}

public struct HistoryPageRequest: Sendable, Equatable {
  public let historySourceID: String
  public let topic: String
  public let beforeDurableOrder: Int64?
  public let limit: Int
  public let coverageGapLimit: Int

  public init(
    historySourceID: String,
    topic: String,
    beforeDurableOrder: Int64? = nil,
    limit: Int = 50,
    coverageGapLimit: Int = 100
  ) {
    self.historySourceID = historySourceID
    self.topic = topic
    self.beforeDurableOrder = beforeDurableOrder
    self.limit = limit
    self.coverageGapLimit = coverageGapLimit
  }
}

public struct HistoryPage: Sendable, Equatable {
  public let messages: [StoredHistoryMessage]
  public let coverageGaps: [StoredHistoryCoverageGap]
  public let nextCursor: Int64?

  public init(
    messages: [StoredHistoryMessage],
    coverageGaps: [StoredHistoryCoverageGap] = [],
    nextCursor: Int64?
  ) {
    self.messages = messages
    self.coverageGaps = coverageGaps
    self.nextCursor = nextCursor
  }
}

public protocol BrokerHistoryReading: Sendable {
  func page(_ request: HistoryPageRequest) async throws -> HistoryPage
  func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) async throws -> NumericChartHistoryResult
}

public struct NumericChartHistoryRequest: Sendable, Equatable {
  public let historySourceID: String
  public let topic: String
  public let maximumMessageCount: Int
  public let maximumPayloadBytesPerSample: Int
  public let maximumPayloadBytes: Int

  public init(
    historySourceID: String,
    topic: String,
    maximumMessageCount: Int,
    maximumPayloadBytesPerSample: Int,
    maximumPayloadBytes: Int
  ) {
    precondition(!historySourceID.isEmpty)
    precondition(!topic.isEmpty)
    precondition((1...4_096).contains(maximumMessageCount))
    precondition((1...65_536).contains(maximumPayloadBytesPerSample))
    precondition((1...(16 * 1_024 * 1_024)).contains(maximumPayloadBytes))
    precondition(maximumPayloadBytesPerSample <= maximumPayloadBytes)
    self.historySourceID = historySourceID
    self.topic = topic
    self.maximumMessageCount = maximumMessageCount
    self.maximumPayloadBytesPerSample = maximumPayloadBytesPerSample
    self.maximumPayloadBytes = maximumPayloadBytes
  }
}

public struct NumericChartHistoryResult: Sendable, Equatable {
  public let messages: [StoredHistoryMessage]
  public let payloadByteCount: Int

  public init(
    messages: [StoredHistoryMessage],
    payloadByteCount: Int
  ) {
    self.messages = messages
    self.payloadByteCount = payloadByteCount
  }
}

extension BrokerHistoryReading {
  public func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) async throws -> NumericChartHistoryResult {
    let page = try await page(
      HistoryPageRequest(
        historySourceID: request.historySourceID,
        topic: request.topic,
        limit: request.maximumMessageCount,
        coverageGapLimit: 0
      )
    )
    var payloadByteCount = 0
    var messages: [StoredHistoryMessage] = []
    messages.reserveCapacity(request.maximumMessageCount)
    for message in page.messages {
      guard message.direction == .received,
        message.connectionEpoch != nil,
        message.connectionOrdinal != nil,
        message.hasStoredPayload,
        message.payload.count <= request.maximumPayloadBytesPerSample,
        payloadByteCount <= request.maximumPayloadBytes - message.payload.count
      else {
        continue
      }
      payloadByteCount += message.payload.count
      messages.append(message)
    }
    messages.reverse()
    return NumericChartHistoryResult(
      messages: messages,
      payloadByteCount: payloadByteCount
    )
  }
}

public protocol BrokerHistoryMaintaining: Sendable {
  func retentionPolicy() async -> HistoryRetentionPolicy
  func maintenanceStatus() async -> HistoryMaintenanceStatus
  func applyRetention() async throws -> HistoryMaintenanceReport
  func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) async throws -> HistoryClearOutcome
  func clearBrokerHistory() async throws -> HistoryClearOutcome
  func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) async throws -> HistoryClearOutcome
  func retrySecureCleanup() async throws
}

public struct HistoryCoverageGapInput: Sendable, Equatable {
  public let historySourceID: String
  public let connectionEpoch: UUID?
  public let startedAtMicroseconds: Int64
  public let endedAtMicroseconds: Int64?
  public let minimumMissingMessageCount: Int
  public let reason: BrokerHistoryCoverageGapReason
  public let isOpenEnded: Bool

  public init(
    historySourceID: String,
    connectionEpoch: UUID?,
    startedAtMicroseconds: Int64,
    endedAtMicroseconds: Int64?,
    minimumMissingMessageCount: Int,
    reason: BrokerHistoryCoverageGapReason,
    isOpenEnded: Bool
  ) {
    self.historySourceID = historySourceID
    self.connectionEpoch = connectionEpoch
    self.startedAtMicroseconds = startedAtMicroseconds
    self.endedAtMicroseconds = endedAtMicroseconds
    self.minimumMissingMessageCount = minimumMissingMessageCount
    self.reason = reason
    self.isOpenEnded = isOpenEnded
  }
}

public struct StoredHistoryCoverageGap: Sendable, Equatable {
  public let durableOrder: Int64
  public let historySourceID: String
  public let connectionEpoch: UUID?
  public let startedAtMicroseconds: Int64
  public let endedAtMicroseconds: Int64?
  public let minimumMissingMessageCount: Int
  public let reason: BrokerHistoryCoverageGapReason
  public let isOpenEnded: Bool
}

public struct HistoryCoverageGapAppendResult: Sendable, Equatable {
  public let durableOrder: Int64
}

public struct HistoryAppendResult: Sendable, Equatable {
  public let insertedCount: Int
  public let firstDurableOrder: Int64?
  public let lastDurableOrder: Int64?
}

public struct HistoryPruneResult: Sendable, Equatable {
  public let deletedCount: Int
  public let remainingCount: Int

  public init(deletedCount: Int, remainingCount: Int) {
    self.deletedCount = deletedCount
    self.remainingCount = remainingCount
  }
}

public struct HistoryClearStepResult: Sendable, Equatable {
  public let deletedMessageCount: Int
  public let deletedTopicCount: Int
  public let remainingMessageCount: Int
  public let secureCleanupStatus: HistorySecureCleanupStatus

  public init(
    deletedMessageCount: Int,
    deletedTopicCount: Int,
    remainingMessageCount: Int,
    secureCleanupStatus: HistorySecureCleanupStatus = .notRequired
  ) {
    self.deletedMessageCount = deletedMessageCount
    self.deletedTopicCount = deletedTopicCount
    self.remainingMessageCount = remainingMessageCount
    self.secureCleanupStatus = secureCleanupStatus
  }

  public var requiresMoreWork: Bool {
    remainingMessageCount > 0
  }
}

public enum HistorySecureCleanupStatus: Sendable, Equatable {
  case notRequired
  case completed
  case pending
}

public struct HistoryTopicClearScope: Sendable, Equatable {
  public let historySourceID: String
  public let topic: String
  public let throughDurableOrder: Int64

  public init(
    historySourceID: String,
    topic: String,
    throughDurableOrder: Int64
  ) {
    self.historySourceID = historySourceID
    self.topic = topic
    self.throughDurableOrder = throughDurableOrder
  }
}

public struct HistoryBrokerClearScope: Sendable, Equatable {
  public let throughMessageOrder: Int64
  public let throughTopicOrder: Int64
  public let throughCoverageGapOrder: Int64

  public init(
    throughMessageOrder: Int64,
    throughTopicOrder: Int64,
    throughCoverageGapOrder: Int64
  ) {
    self.throughMessageOrder = throughMessageOrder
    self.throughTopicOrder = throughTopicOrder
    self.throughCoverageGapOrder = throughCoverageGapOrder
  }
}

public enum HistoryBrokerClearPhase: Sendable, Equatable {
  case messages
  case topics
  case coverageGaps
}

public struct HistoryBrokerClearStepResult: Sendable, Equatable {
  public let phase: HistoryBrokerClearPhase
  public let deletedMessageCount: Int
  public let deletedTopicCount: Int
  public let deletedCoverageGapCount: Int
  public let remainingMessageCount: Int
  public let remainingTopicCount: Int
  public let remainingCoverageGapCount: Int
  public let secureCleanupStatus: HistorySecureCleanupStatus

  public init(
    phase: HistoryBrokerClearPhase,
    deletedMessageCount: Int,
    deletedTopicCount: Int,
    deletedCoverageGapCount: Int,
    remainingMessageCount: Int,
    remainingTopicCount: Int,
    remainingCoverageGapCount: Int,
    secureCleanupStatus: HistorySecureCleanupStatus = .notRequired
  ) {
    self.phase = phase
    self.deletedMessageCount = deletedMessageCount
    self.deletedTopicCount = deletedTopicCount
    self.deletedCoverageGapCount = deletedCoverageGapCount
    self.remainingMessageCount = remainingMessageCount
    self.remainingTopicCount = remainingTopicCount
    self.remainingCoverageGapCount = remainingCoverageGapCount
    self.secureCleanupStatus = secureCleanupStatus
  }

  public var requiresMoreWork: Bool {
    remainingMessageCount > 0
      || remainingTopicCount > 0
      || remainingCoverageGapCount > 0
  }
}

public enum HistoryCheckpointMode: Sendable {
  case passive
  case truncate
}

public struct HistoryCheckpointResult: Sendable, Equatable {
  public let wasBusy: Bool
  public let writeAheadLogFrameCount: Int
  public let checkpointedFrameCount: Int
}

public enum HistoryAutoVacuumMode: Int32, Sendable {
  case none = 0
  case full = 1
  case incremental = 2
}

public struct HistoryFileSizes: Sendable, Equatable {
  public let databaseBytes: Int64
  public let writeAheadLogBytes: Int64
  public let sharedMemoryBytes: Int64

  public static func measure(databaseURL: URL) -> HistoryFileSizes {
    func size(of role: HistoryFileRole) -> Int64 {
      guard
        let size = try? FileManager.default.attributesOfItem(
          atPath: role.url(for: databaseURL).path
        )[.size] as? NSNumber
      else {
        return 0
      }
      return size.int64Value
    }

    return HistoryFileSizes(
      databaseBytes: size(of: .database),
      writeAheadLogBytes: size(of: .writeAheadLog),
      sharedMemoryBytes: size(of: .sharedMemory)
    )
  }

  public var totalSQLiteBytes: Int64 {
    databaseBytes + writeAheadLogBytes + sharedMemoryBytes
  }
}

public struct HistoryStoreDiagnostics: Sendable, Equatable {
  public let schemaVersion: Int
  public let journalMode: String
  public let secureDeleteEnabled: Bool
  public let messageCount: Int
  public let topicCount: Int
  public let orphanTopicCount: Int
  public let databaseBytes: Int64
  public let writeAheadLogBytes: Int64
  public let sharedMemoryBytes: Int64
  public let autoVacuumMode: HistoryAutoVacuumMode
  public let pageSizeBytes: Int
  public let pageCount: Int
  public let freePageCount: Int

  public var totalSQLiteBytes: Int64 {
    databaseBytes + writeAheadLogBytes + sharedMemoryBytes
  }
}

public struct HistorySizePruneResult: Sendable, Equatable {
  public let deletedCount: Int
  public let deletedTopicCount: Int
  public let remainingCount: Int
  public let remainingOrphanTopicCount: Int
  public let remainingFreePageCount: Int
  public let targetBytes: Int64
  public let bytesBefore: Int64
  public let bytesAfter: Int64

  public var targetReached: Bool {
    bytesAfter <= targetBytes
  }

  public var requiresMorePruning: Bool {
    targetReached == false
      && (remainingCount > 0 || remainingOrphanTopicCount > 0
        || remainingFreePageCount > 0)
  }
}

public struct HistoryMaintenanceReport: Sendable, Equatable {
  public let deletedForTopicLimit: Int
  public let deletedForBrokerLimit: Int
  public let deletedOrphanTopicCount: Int
  public let finalMessageCount: Int
  public let finalSQLiteBytes: Int64

  public init(
    deletedForTopicLimit: Int,
    deletedForBrokerLimit: Int,
    deletedOrphanTopicCount: Int,
    finalMessageCount: Int,
    finalSQLiteBytes: Int64
  ) {
    self.deletedForTopicLimit = deletedForTopicLimit
    self.deletedForBrokerLimit = deletedForBrokerLimit
    self.deletedOrphanTopicCount = deletedOrphanTopicCount
    self.finalMessageCount = finalMessageCount
    self.finalSQLiteBytes = finalSQLiteBytes
  }
}

public enum HistoryMaintenanceStatus: Sendable, Equatable {
  case notRun
  case succeeded(HistoryMaintenanceReport)
  case failed
  case cancelled
}

public struct HistoryClearSummary: Sendable, Equatable {
  public let deletedMessageCount: Int
  public let deletedTopicCount: Int
  public let deletedCoverageGapCount: Int
  public let secureCleanupStatus: HistorySecureCleanupStatus

  public init(
    deletedMessageCount: Int,
    deletedTopicCount: Int,
    deletedCoverageGapCount: Int,
    secureCleanupStatus: HistorySecureCleanupStatus
  ) {
    self.deletedMessageCount = deletedMessageCount
    self.deletedTopicCount = deletedTopicCount
    self.deletedCoverageGapCount = deletedCoverageGapCount
    self.secureCleanupStatus = secureCleanupStatus
  }
}

public enum HistoryClearContinuation: Sendable, Equatable {
  case topic(
    scope: HistoryTopicClearScope,
    accumulated: HistoryClearSummary
  )
  case broker(
    scope: HistoryBrokerClearScope,
    accumulated: HistoryClearSummary
  )
}

public enum HistoryClearInterruption: Sendable, Equatable {
  case cancelled
  case storageFailure
}

/// The durable result of a bounded clear operation.
///
/// An interrupted result always carries the original cutoff. Resuming that
/// continuation can only delete rows that existed when the user confirmed.
public struct HistoryClearOutcome: Sendable, Equatable {
  public let summary: HistoryClearSummary
  public let continuation: HistoryClearContinuation?
  public let interruption: HistoryClearInterruption?

  public init(
    summary: HistoryClearSummary,
    continuation: HistoryClearContinuation? = nil,
    interruption: HistoryClearInterruption? = nil
  ) {
    precondition(
      (continuation == nil && interruption == nil)
        || (continuation != nil && interruption != nil)
    )
    self.summary = summary
    self.continuation = continuation
    self.interruption = interruption
  }

  public var isComplete: Bool {
    continuation == nil
  }
}

public enum InvalidHistoryMessageReason: Sendable, Equatable {
  case emptyHistorySourceID
  case emptyTopic
  case containsNullCharacter
  case payloadTooLarge(byteCount: Int)
  case invalidIdentity
  case invalidPayloadStorage
}

public enum HistoryStorageError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidDatabaseURL
  case invalidLimit(Int)
  case invalidRetention(keepingNewest: Int, batchLimit: Int)
  case invalidSizeRetention(
    maximumBytes: Int64,
    batchLimit: Int,
    vacuumPageLimit: Int
  )
  case invalidMessage(index: Int, reason: InvalidHistoryMessageReason)
  case invalidCoverageGap
  case invalidAppendBatch(
    messageCount: Int,
    payloadBytes: Int64,
    maximumMessageCount: Int,
    maximumPayloadBytes: Int64
  )
  case maintenanceDidNotConverge(stepLimit: Int)
  case secureCleanupBusy
  case sqlite(code: Int32, operation: String, message: String)

  public var description: String {
    switch self {
    case .invalidDatabaseURL:
      "History database URL must be a file URL."
    case .invalidLimit(let limit):
      "History query limit \(limit) is outside the supported range."
    case .invalidRetention(let keepingNewest, let batchLimit):
      "History retention values are invalid: keepingNewest=\(keepingNewest), batchLimit=\(batchLimit)."
    case .invalidSizeRetention(
      let maximumBytes,
      let batchLimit,
      let vacuumPageLimit
    ):
      "History size retention values are invalid: maximumBytes=\(maximumBytes), batchLimit=\(batchLimit), vacuumPageLimit=\(vacuumPageLimit)."
    case .invalidMessage(let index, let reason):
      "History message at index \(index) is invalid: \(reason)."
    case .invalidCoverageGap:
      "The history coverage gap is invalid."
    case .invalidAppendBatch(
      let messageCount,
      let payloadBytes,
      let maximumMessageCount,
      let maximumPayloadBytes
    ):
      "History append batch has \(messageCount) messages and \(payloadBytes) payload bytes; limits are \(maximumMessageCount) and \(maximumPayloadBytes)."
    case .maintenanceDidNotConverge(let stepLimit):
      "History maintenance did not converge within \(stepLimit) bounded steps."
    case .secureCleanupBusy:
      "History secure cleanup is pending because the WAL checkpoint is busy."
    case .sqlite(let code, let operation, let message):
      "SQLite \(operation) failed with code \(code): \(message)"
    }
  }
}
