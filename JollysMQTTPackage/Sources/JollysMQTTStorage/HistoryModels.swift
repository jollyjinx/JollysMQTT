import Foundation
import JollysMQTTCore

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
    payload: Data
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
    payload: Data
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

public enum InvalidHistoryMessageReason: Sendable, Equatable {
  case emptyHistorySourceID
  case emptyTopic
  case containsNullCharacter
  case payloadTooLarge(byteCount: Int)
  case invalidIdentity
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
    case .sqlite(let code, let operation, let message):
      "SQLite \(operation) failed with code \(code): \(message)"
    }
  }
}
