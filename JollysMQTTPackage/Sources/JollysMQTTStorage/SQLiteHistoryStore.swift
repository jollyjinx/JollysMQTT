import CSQLite
import Foundation
import JollysMQTTCore

public actor SQLiteHistoryStore {
  public static let currentSchemaVersion = 5

  private let databaseURL: URL
  private let databaseHandle: UInt
  private let filePolicy: any HistoryFilePolicy
  private var database: OpaquePointer {
    OpaquePointer(bitPattern: databaseHandle)!
  }

  private init(
    databaseURL: URL,
    database: OpaquePointer,
    filePolicy: any HistoryFilePolicy
  ) {
    self.databaseURL = databaseURL
    databaseHandle = UInt(bitPattern: database)
    self.filePolicy = filePolicy
  }

  deinit {
    sqlite3_close_v2(OpaquePointer(bitPattern: databaseHandle))
  }

  public static func open(
    databaseURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy()
  ) async throws -> SQLiteHistoryStore {
    guard databaseURL.isFileURL else {
      throw HistoryStorageError.invalidDatabaseURL
    }

    var connection: OpaquePointer?
    let result = sqlite3_open_v2(
      databaseURL.path,
      &connection,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let connection else {
      let message =
        connection.map { String(cString: sqlite3_errmsg($0)) }
        ?? "SQLite did not return an error message."
      if let connection {
        sqlite3_close_v2(connection)
      }
      throw HistoryStorageError.sqlite(
        code: result,
        operation: "open",
        message: message
      )
    }

    let store = SQLiteHistoryStore(
      databaseURL: databaseURL,
      database: connection,
      filePolicy: filePolicy
    )
    try await store.configureAndMigrate()
    try await store.refreshFilePolicy()
    return store
  }

  public func refreshFilePolicy() async throws {
    for role in HistoryFileRole.allCases {
      try await filePolicy.apply(
        to: role.url(for: databaseURL),
        role: role
      )
    }
  }

  public func integrityCheck() throws -> String {
    try scalarText(
      "PRAGMA integrity_check",
      operation: "check database integrity"
    )
  }

  public func append(_ messages: [HistoryMessageInput]) throws -> HistoryAppendResult {
    guard messages.isEmpty == false else {
      return HistoryAppendResult(
        insertedCount: 0,
        firstDurableOrder: nil,
        lastDurableOrder: nil
      )
    }
    try validate(messages)

    try execute("BEGIN IMMEDIATE", operation: "begin append")
    do {
      let insertTopic = try prepare(
        """
        INSERT INTO topics(history_source_id, topic)
        VALUES (?, ?)
        ON CONFLICT(history_source_id, topic) DO NOTHING
        """,
        operation: "prepare topic insert"
      )
      defer { sqlite3_finalize(insertTopic) }

      let selectTopic = try prepare(
        """
        SELECT id
        FROM topics
        WHERE history_source_id = ? AND topic = ?
        """,
        operation: "prepare topic lookup"
      )
      defer { sqlite3_finalize(selectTopic) }

      let insertMessage = try prepare(
        """
        INSERT INTO messages(
            topic_id,
            connection_epoch,
            connection_ordinal,
            operation_id,
            direction,
            qos,
            retained,
            received_at_microseconds,
            payload,
            payload_original_byte_count,
            payload_omission_reason
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        operation: "prepare message insert"
      )
      defer { sqlite3_finalize(insertMessage) }

      var firstOrder: Int64?
      var lastOrder: Int64?
      var topicIDs: [TopicKey: Int64] = [:]
      topicIDs.reserveCapacity(min(messages.count, 4_096))
      for message in messages {
        let topicID = try resolveTopicID(
          for: message,
          insertStatement: insertTopic,
          selectStatement: selectTopic,
          topicIDs: &topicIDs
        )
        try insert(message, topicID: topicID, statement: insertMessage)
        let durableOrder = sqlite3_last_insert_rowid(database)
        firstOrder = firstOrder ?? durableOrder
        lastOrder = durableOrder
      }
      try execute("COMMIT", operation: "commit append")
      return HistoryAppendResult(
        insertedCount: messages.count,
        firstDurableOrder: firstOrder,
        lastDurableOrder: lastOrder
      )
    } catch {
      try? execute("ROLLBACK", operation: "rollback append")
      throw error
    }
  }

  public func newestMessages(
    historySourceID: String,
    topic: String,
    limit: Int
  ) throws -> [StoredHistoryMessage] {
    try historyMessages(
      historySourceID: historySourceID,
      topic: topic,
      beforeDurableOrder: nil,
      limit: limit
    )
  }

  public func page(_ request: HistoryPageRequest) throws -> HistoryPage {
    guard request.limit >= 0, request.limit < Int(Int32.max) else {
      throw HistoryStorageError.invalidLimit(request.limit)
    }
    guard request.coverageGapLimit >= 0,
      request.coverageGapLimit <= Int(Int32.max)
    else {
      throw HistoryStorageError.invalidLimit(request.coverageGapLimit)
    }
    guard request.limit > 0 else {
      return HistoryPage(messages: [], nextCursor: nil)
    }
    let fetched = try historyMessages(
      historySourceID: request.historySourceID,
      topic: request.topic,
      beforeDurableOrder: request.beforeDurableOrder,
      limit: request.limit + 1
    )
    let hasMore = fetched.count > request.limit
    let messages = Array(fetched.prefix(request.limit))
    var timeRange: ClosedRange<Int64>?
    for message in messages {
      if let range = timeRange {
        let lower = min(
          range.lowerBound,
          message.receivedAtMicroseconds
        )
        let upper = max(
          range.upperBound,
          message.receivedAtMicroseconds
        )
        timeRange = lower...upper
      } else {
        timeRange =
          message.receivedAtMicroseconds...message.receivedAtMicroseconds
      }
    }
    let gaps: [StoredHistoryCoverageGap] =
      if let timeRange {
        try coverageGaps(
          historySourceID: request.historySourceID,
          overlapping: timeRange,
          limit: request.coverageGapLimit
        )
      } else {
        []
      }
    return HistoryPage(
      messages: messages,
      coverageGaps: gaps,
      nextCursor: hasMore ? messages.last?.durableOrder : nil
    )
  }

  private func historyMessages(
    historySourceID: String,
    topic: String,
    beforeDurableOrder: Int64?,
    limit: Int
  ) throws -> [StoredHistoryMessage] {
    guard limit >= 0, limit <= Int(Int32.max) else {
      throw HistoryStorageError.invalidLimit(limit)
    }
    guard limit > 0 else { return [] }

    let cursorPredicate =
      beforeDurableOrder == nil ? "" : "AND messages.id < ?"
    let statement = try prepare(
      """
      SELECT
          messages.id,
          topics.history_source_id,
          topics.topic,
          messages.connection_epoch,
          messages.connection_ordinal,
          messages.operation_id,
          messages.direction,
          messages.qos,
          messages.retained,
          messages.received_at_microseconds,
          messages.payload,
          messages.payload_original_byte_count,
          messages.payload_omission_reason
      FROM messages
      JOIN topics ON topics.id = messages.topic_id
      WHERE topics.history_source_id = ? AND topics.topic = ?
        \(cursorPredicate)
      ORDER BY messages.id DESC
      LIMIT ?
      """,
      operation: "prepare newest history query"
    )
    defer { sqlite3_finalize(statement) }

    try bind(historySourceID, to: 1, in: statement, operation: "bind history source")
    try bind(topic, to: 2, in: statement, operation: "bind topic")
    let limitIndex: Int32
    if let beforeDurableOrder {
      try check(
        sqlite3_bind_int64(statement, 3, beforeDurableOrder),
        operation: "bind history cursor"
      )
      limitIndex = 4
    } else {
      limitIndex = 3
    }
    try check(
      sqlite3_bind_int(statement, limitIndex, Int32(limit)),
      operation: "bind history limit"
    )

    var messages: [StoredHistoryMessage] = []
    messages.reserveCapacity(min(limit, 4_096))
    while true {
      let result = sqlite3_step(statement)
      switch result {
      case SQLITE_ROW:
        messages.append(
          StoredHistoryMessage(
            durableOrder: sqlite3_column_int64(statement, 0),
            historySourceID: textColumn(statement, index: 1),
            connectionEpoch: optionalTextColumn(statement, index: 3)
              .flatMap(UUID.init(uuidString:)),
            connectionOrdinal:
              sqlite3_column_type(statement, 4) == SQLITE_NULL
              ? nil
              : UInt64(bitPattern: sqlite3_column_int64(statement, 4)),
            operationID: optionalTextColumn(statement, index: 5)
              .flatMap(UUID.init(uuidString:))
              .map(PublishOperationID.init(rawValue:)),
            direction:
              PayloadDeliveryDirection(
                rawValue: textColumn(statement, index: 6)
              ) ?? .received,
            topic: textColumn(statement, index: 2),
            qos:
              MQTTQualityOfService(
                rawValue: Int(sqlite3_column_int(statement, 7))
              ) ?? .atMostOnce,
            retained: sqlite3_column_int(statement, 8) != 0,
            receivedAtMicroseconds: sqlite3_column_int64(statement, 9),
            payload: dataColumn(statement, index: 10),
            payloadStorage: try payloadStorage(
              storedByteCount: Int(
                sqlite3_column_bytes(statement, 10)
              ),
              originalByteCount: Int(sqlite3_column_int64(statement, 11)),
              omissionReason: optionalTextColumn(statement, index: 12)
            )
          )
        )
      case SQLITE_DONE:
        return messages
      default:
        throw sqliteError(code: result, operation: "read newest history")
      }
    }
  }

  public func recordCoverageGap(
    _ gap: HistoryCoverageGapInput
  ) throws -> HistoryCoverageGapAppendResult {
    guard !gap.historySourceID.isEmpty,
      !gap.historySourceID.contains("\0"),
      gap.minimumMissingMessageCount > 0,
      gap.isOpenEnded
        ? gap.endedAtMicroseconds == nil
        : gap.endedAtMicroseconds != nil,
      gap.endedAtMicroseconds.map({
        $0 >= gap.startedAtMicroseconds
      }) ?? true
    else {
      throw HistoryStorageError.invalidCoverageGap
    }
    let statement = try prepare(
      """
      INSERT INTO history_coverage_gaps(
          history_source_id,
          connection_epoch,
          started_at_microseconds,
          ended_at_microseconds,
          minimum_missing_message_count,
          reason,
          is_open_ended
      )
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      operation: "prepare coverage-gap insert"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      gap.historySourceID,
      to: 1,
      in: statement,
      operation: "bind gap history source"
    )
    if let epoch = gap.connectionEpoch {
      try bind(
        epoch.uuidString.lowercased(),
        to: 2,
        in: statement,
        operation: "bind gap connection epoch"
      )
    } else {
      try check(
        sqlite3_bind_null(statement, 2),
        operation: "bind absent gap connection epoch"
      )
    }
    try check(
      sqlite3_bind_int64(statement, 3, gap.startedAtMicroseconds),
      operation: "bind gap start"
    )
    if let endedAtMicroseconds = gap.endedAtMicroseconds {
      try check(
        sqlite3_bind_int64(statement, 4, endedAtMicroseconds),
        operation: "bind gap end"
      )
    } else {
      try check(
        sqlite3_bind_null(statement, 4),
        operation: "bind absent gap end"
      )
    }
    try check(
      sqlite3_bind_int64(
        statement,
        5,
        Int64(gap.minimumMissingMessageCount)
      ),
      operation: "bind gap missing count"
    )
    try bind(
      gap.reason.rawValue,
      to: 6,
      in: statement,
      operation: "bind gap reason"
    )
    try check(
      sqlite3_bind_int(statement, 7, gap.isOpenEnded ? 1 : 0),
      operation: "bind gap open-ended state"
    )
    try expectDone(
      sqlite3_step(statement),
      operation: "insert coverage gap"
    )
    return HistoryCoverageGapAppendResult(
      durableOrder: sqlite3_last_insert_rowid(database)
    )
  }

  public func coverageGaps(
    historySourceID: String,
    overlapping interval: ClosedRange<Int64>? = nil,
    limit: Int = 1_000
  ) throws -> [StoredHistoryCoverageGap] {
    guard limit >= 0, limit <= Int(Int32.max) else {
      throw HistoryStorageError.invalidLimit(limit)
    }
    guard limit > 0 else { return [] }
    let statement = try prepare(
      """
      SELECT
          id,
          history_source_id,
          connection_epoch,
          started_at_microseconds,
          ended_at_microseconds,
          minimum_missing_message_count,
          reason,
          is_open_ended
      FROM history_coverage_gaps
      WHERE history_source_id = ?
        AND started_at_microseconds <= ?
        AND (
            ended_at_microseconds IS NULL
            OR ended_at_microseconds >= ?
        )
      ORDER BY id ASC
      LIMIT ?
      """,
      operation: "prepare coverage-gap query"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      historySourceID,
      to: 1,
      in: statement,
      operation: "bind gap query history source"
    )
    try check(
      sqlite3_bind_int64(
        statement,
        2,
        interval?.upperBound ?? Int64.max
      ),
      operation: "bind gap query end"
    )
    try check(
      sqlite3_bind_int64(
        statement,
        3,
        interval?.lowerBound ?? Int64.min
      ),
      operation: "bind gap query start"
    )
    try check(
      sqlite3_bind_int64(statement, 4, Int64(limit)),
      operation: "bind gap query limit"
    )

    var gaps: [StoredHistoryCoverageGap] = []
    while true {
      let result = sqlite3_step(statement)
      switch result {
      case SQLITE_ROW:
        let reasonText = textColumn(statement, index: 6)
        guard
          let reason = BrokerHistoryCoverageGapReason(
            rawValue: reasonText
          )
        else {
          throw HistoryStorageError.sqlite(
            code: SQLITE_CORRUPT,
            operation: "read coverage gap",
            message: "Coverage gap reason is invalid."
          )
        }
        gaps.append(
          StoredHistoryCoverageGap(
            durableOrder: sqlite3_column_int64(statement, 0),
            historySourceID: textColumn(statement, index: 1),
            connectionEpoch: optionalTextColumn(statement, index: 2)
              .flatMap(UUID.init(uuidString:)),
            startedAtMicroseconds: sqlite3_column_int64(
              statement,
              3
            ),
            endedAtMicroseconds:
              sqlite3_column_type(statement, 4) == SQLITE_NULL
              ? nil : sqlite3_column_int64(statement, 4),
            minimumMissingMessageCount: Int(
              sqlite3_column_int64(statement, 5)
            ),
            reason: reason,
            isOpenEnded: sqlite3_column_int(statement, 7) != 0
          )
        )
      case SQLITE_DONE:
        return gaps
      default:
        throw sqliteError(
          code: result,
          operation: "read coverage gaps"
        )
      }
    }
  }

  public func prune(
    keepingNewestPerTopic: Int,
    batchLimit: Int
  ) throws -> HistoryPruneResult {
    guard keepingNewestPerTopic >= 0,
      batchLimit > 0,
      keepingNewestPerTopic <= Int(Int32.max),
      batchLimit <= Int(Int32.max)
    else {
      throw HistoryStorageError.invalidRetention(
        keepingNewest: keepingNewestPerTopic,
        batchLimit: batchLimit
      )
    }

    let countBefore = try scalarInt64(
      "SELECT COUNT(*) FROM messages",
      operation: "count messages before pruning"
    )

    try execute("BEGIN IMMEDIATE", operation: "begin pruning")
    do {
      let statement = try prepare(
        """
        WITH ranked AS (
            SELECT
                id,
                ROW_NUMBER() OVER (
                    PARTITION BY topic_id
                    ORDER BY id DESC
                ) AS newest_rank
            FROM messages
        ),
        doomed AS (
            SELECT id
            FROM ranked
            WHERE newest_rank > ?
            ORDER BY id ASC
            LIMIT ?
        )
        DELETE FROM messages
        WHERE id IN (SELECT id FROM doomed)
        """,
        operation: "prepare incremental prune"
      )
      defer { sqlite3_finalize(statement) }
      try check(
        sqlite3_bind_int64(statement, 1, Int64(keepingNewestPerTopic)),
        operation: "bind per-topic retention limit"
      )
      try check(
        sqlite3_bind_int64(statement, 2, Int64(batchLimit)),
        operation: "bind prune batch limit"
      )
      try expectDone(sqlite3_step(statement), operation: "prune history")
      let deleted = Int(sqlite3_changes(database))
      try execute("COMMIT", operation: "commit pruning")
      if deleted > 0 {
        _ = try checkpoint(.truncate)
      }
      return HistoryPruneResult(
        deletedCount: deleted,
        remainingCount: Int(countBefore) - deleted
      )
    } catch {
      try? execute("ROLLBACK", operation: "rollback pruning")
      throw error
    }
  }

  public func prepareTopicHistoryClear(
    historySourceID: String,
    topic: String
  ) throws -> HistoryTopicClearScope {
    HistoryTopicClearScope(
      historySourceID: historySourceID,
      topic: topic,
      throughDurableOrder: try maximumMessageOrder(
        historySourceID: historySourceID,
        topic: topic
      )
    )
  }

  public func clearTopicHistory(
    _ scope: HistoryTopicClearScope,
    batchLimit: Int,
    vacuumPageLimit: Int
  ) throws -> HistoryClearStepResult {
    guard batchLimit > 0, batchLimit <= Int(Int32.max),
      vacuumPageLimit > 0, vacuumPageLimit <= Int(Int32.max)
    else {
      throw HistoryStorageError.invalidRetention(
        keepingNewest: 0,
        batchLimit: batchLimit
      )
    }
    try execute("BEGIN IMMEDIATE", operation: "begin topic-history clear")
    do {
      let deleteMessages = try prepare(
        """
        DELETE FROM messages
        WHERE id IN (
            SELECT messages.id
            FROM messages
            JOIN topics ON topics.id = messages.topic_id
            WHERE topics.history_source_id = ? AND topics.topic = ?
              AND messages.id <= ?
            ORDER BY messages.id ASC
            LIMIT ?
        )
        """,
        operation: "prepare topic-history clear"
      )
      defer { sqlite3_finalize(deleteMessages) }
      try bind(
        scope.historySourceID,
        to: 1,
        in: deleteMessages,
        operation: "bind clear history source"
      )
      try bind(
        scope.topic,
        to: 2,
        in: deleteMessages,
        operation: "bind clear topic"
      )
      try check(
        sqlite3_bind_int64(
          deleteMessages,
          3,
          scope.throughDurableOrder
        ),
        operation: "bind topic-history clear cutoff"
      )
      try check(
        sqlite3_bind_int64(deleteMessages, 4, Int64(batchLimit)),
        operation: "bind topic-history clear batch"
      )
      try expectDone(
        sqlite3_step(deleteMessages),
        operation: "clear topic messages"
      )
      let deletedMessages = Int(sqlite3_changes(database))

      let remaining = Int(
        try countMessages(
          historySourceID: scope.historySourceID,
          topic: scope.topic,
          throughDurableOrder: scope.throughDurableOrder
        )
      )
      var deletedTopics = 0
      if remaining == 0 {
        let deleteTopic = try prepare(
          """
          DELETE FROM topics
          WHERE history_source_id = ? AND topic = ?
            AND NOT EXISTS (
                SELECT 1 FROM messages
                WHERE messages.topic_id = topics.id
            )
          """,
          operation: "prepare cleared topic removal"
        )
        defer { sqlite3_finalize(deleteTopic) }
        try bind(
          scope.historySourceID,
          to: 1,
          in: deleteTopic,
          operation: "bind cleared topic history source"
        )
        try bind(
          scope.topic,
          to: 2,
          in: deleteTopic,
          operation: "bind cleared topic"
        )
        try expectDone(
          sqlite3_step(deleteTopic),
          operation: "remove cleared topic"
        )
        deletedTopics = Int(sqlite3_changes(database))
      }
      try execute("COMMIT", operation: "commit topic-history clear")
      var cleanupStatus: HistorySecureCleanupStatus = .notRequired
      if remaining == 0 {
        do {
          try finalizeHistoryClear(
            vacuumPageLimit: vacuumPageLimit
          )
          cleanupStatus = .completed
        } catch {
          cleanupStatus = .pending
        }
      }
      return HistoryClearStepResult(
        deletedMessageCount: deletedMessages,
        deletedTopicCount: deletedTopics,
        remainingMessageCount: remaining,
        secureCleanupStatus: cleanupStatus
      )
    } catch {
      try? execute("ROLLBACK", operation: "rollback topic-history clear")
      throw error
    }
  }

  private func countMessages(
    historySourceID: String,
    topic: String,
    throughDurableOrder: Int64
  ) throws -> Int64 {
    let statement = try prepare(
      """
      SELECT COUNT(*)
      FROM messages
      JOIN topics ON topics.id = messages.topic_id
      WHERE topics.history_source_id = ? AND topics.topic = ?
        AND messages.id <= ?
      """,
      operation: "prepare topic message count"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      historySourceID,
      to: 1,
      in: statement,
      operation: "bind counted history source"
    )
    try bind(
      topic,
      to: 2,
      in: statement,
      operation: "bind counted topic"
    )
    try check(
      sqlite3_bind_int64(statement, 3, throughDurableOrder),
      operation: "bind counted message cutoff"
    )
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(code: result, operation: "count topic messages")
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func maximumMessageOrder(
    historySourceID: String,
    topic: String
  ) throws -> Int64 {
    let statement = try prepare(
      """
      SELECT COALESCE(MAX(messages.id), 0)
      FROM messages
      JOIN topics ON topics.id = messages.topic_id
      WHERE topics.history_source_id = ? AND topics.topic = ?
      """,
      operation: "prepare topic clear cutoff"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      historySourceID,
      to: 1,
      in: statement,
      operation: "bind cutoff history source"
    )
    try bind(
      topic,
      to: 2,
      in: statement,
      operation: "bind cutoff topic"
    )
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(code: result, operation: "read topic clear cutoff")
    }
    return sqlite3_column_int64(statement, 0)
  }

  public func prepareBrokerHistoryClear() throws -> HistoryBrokerClearScope {
    HistoryBrokerClearScope(
      throughMessageOrder: try maximumOrder(in: "messages"),
      throughTopicOrder: try maximumOrder(in: "topics"),
      throughCoverageGapOrder: try maximumOrder(
        in: "history_coverage_gaps"
      )
    )
  }

  public func clearBrokerHistory(
    _ scope: HistoryBrokerClearScope,
    batchLimit: Int,
    vacuumPageLimit: Int
  ) throws -> HistoryBrokerClearStepResult {
    guard batchLimit > 0, batchLimit <= Int(Int32.max),
      vacuumPageLimit > 0, vacuumPageLimit <= Int(Int32.max)
    else {
      throw HistoryStorageError.invalidRetention(
        keepingNewest: 0,
        batchLimit: batchLimit
      )
    }
    try execute("BEGIN IMMEDIATE", operation: "begin broker-history clear")
    do {
      let messagesBefore = Int(
        try scalarInt64(
          "SELECT COUNT(*) FROM messages WHERE id <= \(scope.throughMessageOrder)",
          operation: "count broker messages before clear"
        )
      )
      let topicsBefore = Int(
        try scalarInt64(
          """
          SELECT COUNT(*) FROM topics
          WHERE id <= \(scope.throughTopicOrder)
            AND NOT EXISTS (
                SELECT 1 FROM messages
                WHERE messages.topic_id = topics.id
            )
          """,
          operation: "count broker topics before clear"
        )
      )
      let phase: HistoryBrokerClearPhase
      let deletedMessages: Int
      let deletedTopics: Int
      let deletedGaps: Int
      if messagesBefore > 0 {
        phase = .messages
        deletedMessages = try deleteOldestRows(
          table: "messages",
          throughOrder: scope.throughMessageOrder,
          requireOrphan: false,
          batchLimit: batchLimit,
          operation: "clear broker messages"
        )
        deletedTopics = 0
        deletedGaps = 0
      } else if topicsBefore > 0 {
        phase = .topics
        deletedMessages = 0
        deletedTopics = try deleteOldestRows(
          table: "topics",
          throughOrder: scope.throughTopicOrder,
          requireOrphan: true,
          batchLimit: batchLimit,
          operation: "clear broker topics"
        )
        deletedGaps = 0
      } else {
        phase = .coverageGaps
        deletedMessages = 0
        deletedTopics = 0
        deletedGaps = try deleteOldestRows(
          table: "history_coverage_gaps",
          throughOrder: scope.throughCoverageGapOrder,
          requireOrphan: false,
          batchLimit: batchLimit,
          operation: "clear broker coverage"
        )
      }
      // Recompute after the phase. Deleting the last message can create a new
      // orphan topic that was not present in `topicsBefore`.
      let messagesAfter = Int(
        try scalarInt64(
          "SELECT COUNT(*) FROM messages WHERE id <= \(scope.throughMessageOrder)",
          operation: "count broker messages after clear"
        )
      )
      let topicsAfter = Int(
        try scalarInt64(
          """
          SELECT COUNT(*) FROM topics
          WHERE id <= \(scope.throughTopicOrder)
            AND NOT EXISTS (
                SELECT 1 FROM messages
                WHERE messages.topic_id = topics.id
            )
          """,
          operation: "count broker topics after clear"
        )
      )
      let gapsAfter = Int(
        try scalarInt64(
          "SELECT COUNT(*) FROM history_coverage_gaps WHERE id <= \(scope.throughCoverageGapOrder)",
          operation: "count broker coverage after clear"
        )
      )
      try execute("COMMIT", operation: "commit broker-history clear")
      let hasRemaining =
        messagesAfter > 0 || topicsAfter > 0 || gapsAfter > 0
      var cleanupStatus: HistorySecureCleanupStatus = .notRequired
      if !hasRemaining {
        do {
          try finalizeHistoryClear(
            vacuumPageLimit: vacuumPageLimit
          )
          cleanupStatus = .completed
        } catch {
          cleanupStatus = .pending
        }
      }
      return HistoryBrokerClearStepResult(
        phase: phase,
        deletedMessageCount: deletedMessages,
        deletedTopicCount: deletedTopics,
        deletedCoverageGapCount: deletedGaps,
        remainingMessageCount: messagesAfter,
        remainingTopicCount: topicsAfter,
        remainingCoverageGapCount: gapsAfter,
        secureCleanupStatus: cleanupStatus
      )
    } catch {
      try? execute("ROLLBACK", operation: "rollback broker-history clear")
      throw error
    }
  }

  private func deleteOldestRows(
    table: String,
    throughOrder: Int64,
    requireOrphan: Bool,
    batchLimit: Int,
    operation: String
  ) throws -> Int {
    precondition(
      table == "messages"
        || table == "topics"
        || table == "history_coverage_gaps"
    )
    let orphanPredicate =
      requireOrphan
      ? """
       AND NOT EXISTS (
           SELECT 1 FROM messages
           WHERE messages.topic_id = topics.id
       )
      """
      : ""
    let statement = try prepare(
      """
      DELETE FROM \(table)
      WHERE id IN (
          SELECT id
          FROM \(table)
          WHERE id <= ?
          \(orphanPredicate)
          ORDER BY id ASC
          LIMIT ?
      )
      """,
      operation: "prepare \(operation)"
    )
    defer { sqlite3_finalize(statement) }
    try check(
      sqlite3_bind_int64(statement, 1, throughOrder),
      operation: "bind \(operation) cutoff"
    )
    try check(
      sqlite3_bind_int64(statement, 2, Int64(batchLimit)),
      operation: "bind \(operation) batch"
    )
    try expectDone(sqlite3_step(statement), operation: operation)
    return Int(sqlite3_changes(database))
  }

  private func maximumOrder(in table: String) throws -> Int64 {
    precondition(
      table == "messages"
        || table == "topics"
        || table == "history_coverage_gaps"
    )
    return try scalarInt64(
      "SELECT COALESCE(MAX(id), 0) FROM \(table)",
      operation: "read \(table) clear cutoff"
    )
  }

  public func finalizeHistoryClear(
    vacuumPageLimit: Int
  ) throws {
    guard vacuumPageLimit > 0,
      vacuumPageLimit <= Int(Int32.max)
    else {
      throw HistoryStorageError.invalidSizeRetention(
        maximumBytes: 0,
        batchLimit: 1,
        vacuumPageLimit: vacuumPageLimit
      )
    }
    let checkpointBeforeVacuum = try checkpoint(.truncate)
    guard !checkpointBeforeVacuum.wasBusy else {
      throw HistoryStorageError.secureCleanupBusy
    }
    try execute(
      "PRAGMA incremental_vacuum(\(vacuumPageLimit))",
      operation: "reclaim cleared history pages"
    )
    let checkpointAfterVacuum = try checkpoint(.truncate)
    guard !checkpointAfterVacuum.wasBusy else {
      throw HistoryStorageError.secureCleanupBusy
    }
  }

  public func diagnostics() throws -> HistoryStoreDiagnostics {
    let sizes = fileSizes()
    return HistoryStoreDiagnostics(
      schemaVersion: Int(
        try scalarInt64(
          "SELECT version FROM schema_version WHERE singleton = 1",
          operation: "read schema version diagnostics"
        )
      ),
      journalMode: try scalarText(
        "PRAGMA journal_mode",
        operation: "read journal mode"
      ).lowercased(),
      secureDeleteEnabled:
        try scalarInt64(
          "PRAGMA secure_delete",
          operation: "read secure-delete mode"
        ) != 0,
      messageCount: Int(
        try scalarInt64(
          "SELECT COUNT(*) FROM messages",
          operation: "count messages"
        )
      ),
      topicCount: Int(
        try scalarInt64(
          "SELECT COUNT(*) FROM topics",
          operation: "count topics"
        )
      ),
      orphanTopicCount: Int(
        try scalarInt64(
          """
          SELECT COUNT(*)
          FROM topics
          WHERE NOT EXISTS (
              SELECT 1
              FROM messages
              WHERE messages.topic_id = topics.id
          )
          """,
          operation: "count orphan topics"
        )
      ),
      databaseBytes: sizes.databaseBytes,
      writeAheadLogBytes: sizes.writeAheadLogBytes,
      sharedMemoryBytes: sizes.sharedMemoryBytes,
      autoVacuumMode: HistoryAutoVacuumMode(
        rawValue: Int32(
          try scalarInt64(
            "PRAGMA auto_vacuum",
            operation: "read auto-vacuum mode"
          )
        )
      ) ?? .none,
      pageSizeBytes: Int(
        try scalarInt64(
          "PRAGMA page_size",
          operation: "read page size"
        )
      ),
      pageCount: Int(
        try scalarInt64(
          "PRAGMA page_count",
          operation: "read page count"
        )
      ),
      freePageCount: Int(
        try scalarInt64(
          "PRAGMA freelist_count",
          operation: "read free-page count"
        )
      )
    )
  }

  public func fileSizes() -> HistoryFileSizes {
    HistoryFileSizes.measure(databaseURL: databaseURL)
  }

  public func checkpoint(
    _ mode: HistoryCheckpointMode
  ) throws -> HistoryCheckpointResult {
    var walFrames: Int32 = 0
    var checkpointedFrames: Int32 = 0
    let sqliteMode =
      switch mode {
      case .passive:
        SQLITE_CHECKPOINT_PASSIVE
      case .truncate:
        SQLITE_CHECKPOINT_TRUNCATE
      }
    let result = sqlite3_wal_checkpoint_v2(
      database,
      nil,
      sqliteMode,
      &walFrames,
      &checkpointedFrames
    )
    guard result == SQLITE_OK || result == SQLITE_BUSY else {
      throw sqliteError(code: result, operation: "checkpoint WAL")
    }
    return HistoryCheckpointResult(
      wasBusy: result == SQLITE_BUSY,
      writeAheadLogFrameCount: Int(walFrames),
      checkpointedFrameCount: Int(checkpointedFrames)
    )
  }

  public func pruneToMaximumBytes(
    _ maximumBytes: Int64,
    batchLimit: Int,
    vacuumPageLimit: Int
  ) throws -> HistorySizePruneResult {
    guard maximumBytes >= 0,
      batchLimit > 0,
      vacuumPageLimit > 0,
      batchLimit <= Int(Int32.max),
      vacuumPageLimit <= Int(Int32.max)
    else {
      throw HistoryStorageError.invalidSizeRetention(
        maximumBytes: maximumBytes,
        batchLimit: batchLimit,
        vacuumPageLimit: vacuumPageLimit
      )
    }

    _ = try checkpoint(.truncate)
    let initial = try diagnostics()
    guard initial.totalSQLiteBytes > maximumBytes else {
      return HistorySizePruneResult(
        deletedCount: 0,
        deletedTopicCount: 0,
        remainingCount: initial.messageCount,
        remainingOrphanTopicCount: initial.orphanTopicCount,
        remainingFreePageCount: initial.freePageCount,
        targetBytes: maximumBytes,
        bytesBefore: initial.totalSQLiteBytes,
        bytesAfter: initial.totalSQLiteBytes
      )
    }

    let spentVacuumBudget = initial.freePageCount > 0
    if spentVacuumBudget {
      try execute(
        "PRAGMA incremental_vacuum(\(vacuumPageLimit))",
        operation: "reclaim existing free pages"
      )
      _ = try checkpoint(.truncate)
      let reclaimed = try diagnostics()
      if reclaimed.totalSQLiteBytes <= maximumBytes
        || reclaimed.freePageCount > 0
      {
        return HistorySizePruneResult(
          deletedCount: 0,
          deletedTopicCount: 0,
          remainingCount: reclaimed.messageCount,
          remainingOrphanTopicCount: reclaimed.orphanTopicCount,
          remainingFreePageCount: reclaimed.freePageCount,
          targetBytes: maximumBytes,
          bytesBefore: initial.totalSQLiteBytes,
          bytesAfter: reclaimed.totalSQLiteBytes
        )
      }
    }

    try execute("BEGIN IMMEDIATE", operation: "begin size pruning")
    let deleted: Int
    let deletedTopics: Int
    do {
      let messageStatement = try prepare(
        """
        DELETE FROM messages
        WHERE id IN (
            SELECT id
            FROM messages
            ORDER BY id ASC
            LIMIT ?
        )
        """,
        operation: "prepare size prune"
      )
      defer { sqlite3_finalize(messageStatement) }
      try check(
        sqlite3_bind_int64(messageStatement, 1, Int64(batchLimit)),
        operation: "bind size-prune batch limit"
      )
      try expectDone(
        sqlite3_step(messageStatement),
        operation: "prune history by size"
      )
      deleted = Int(sqlite3_changes(database))

      let topicStatement = try prepare(
        """
        DELETE FROM topics
        WHERE id IN (
            SELECT topics.id
            FROM topics
            WHERE NOT EXISTS (
                SELECT 1
                FROM messages
                WHERE messages.topic_id = topics.id
            )
            ORDER BY topics.id ASC
            LIMIT ?
        )
        """,
        operation: "prepare orphan-topic prune"
      )
      defer { sqlite3_finalize(topicStatement) }
      try check(
        sqlite3_bind_int64(topicStatement, 1, Int64(batchLimit)),
        operation: "bind orphan-topic prune batch limit"
      )
      try expectDone(
        sqlite3_step(topicStatement),
        operation: "prune orphan topics"
      )
      deletedTopics = Int(sqlite3_changes(database))
      try execute("COMMIT", operation: "commit size pruning")
    } catch {
      try? execute("ROLLBACK", operation: "rollback size pruning")
      throw error
    }

    _ = try checkpoint(.truncate)
    if spentVacuumBudget == false {
      try execute(
        "PRAGMA incremental_vacuum(\(vacuumPageLimit))",
        operation: "incrementally reclaim pages"
      )
      _ = try checkpoint(.truncate)
    }
    let after = try diagnostics()
    return HistorySizePruneResult(
      deletedCount: deleted,
      deletedTopicCount: deletedTopics,
      remainingCount: after.messageCount,
      remainingOrphanTopicCount: after.orphanTopicCount,
      remainingFreePageCount: after.freePageCount,
      targetBytes: maximumBytes,
      bytesBefore: initial.totalSQLiteBytes,
      bytesAfter: after.totalSQLiteBytes
    )
  }

  private func configureAndMigrate() throws {
    try execute("PRAGMA foreign_keys = ON", operation: "enable foreign keys")
    try execute(
      "PRAGMA secure_delete = ON",
      operation: "enable secure history deletion"
    )
    guard
      try scalarInt64(
        "PRAGMA secure_delete",
        operation: "verify secure history deletion"
      ) == 1
    else {
      throw HistoryStorageError.sqlite(
        code: SQLITE_ERROR,
        operation: "verify secure history deletion",
        message: "SQLite did not enable secure deletion."
      )
    }
    try execute(
      "PRAGMA auto_vacuum = INCREMENTAL",
      operation: "request incremental auto-vacuum"
    )

    let journal = try scalarText(
      "PRAGMA journal_mode = WAL",
      operation: "enable WAL"
    )
    guard journal.lowercased() == "wal" else {
      throw HistoryStorageError.sqlite(
        code: SQLITE_ERROR,
        operation: "enable WAL",
        message: "SQLite selected journal mode \(journal)."
      )
    }
    try execute("PRAGMA synchronous = NORMAL", operation: "set synchronous mode")

    let hasVersionTable = try scalarInt64(
      """
      SELECT COUNT(*)
      FROM sqlite_master
      WHERE type = 'table' AND name = 'schema_version'
      """,
      operation: "find schema version table"
    )
    if hasVersionTable == 0 {
      try execute("BEGIN IMMEDIATE", operation: "begin initial migration")
      do {
        try createCurrentSchema()
        try execute("COMMIT", operation: "commit initial migration")
      } catch {
        try? execute("ROLLBACK", operation: "rollback initial migration")
        throw error
      }
    } else {
      let version = try scalarInt64(
        "SELECT version FROM schema_version WHERE singleton = 1",
        operation: "read schema version"
      )
      if version == 1 {
        try migrateSchemaVersionOneToTwo()
        try migrateSchemaVersionTwoToThree()
        try migrateSchemaVersionThreeToFour()
        try migrateSchemaVersionFourToFive()
      } else if version == 2 {
        try migrateSchemaVersionTwoToThree()
        try migrateSchemaVersionThreeToFour()
        try migrateSchemaVersionFourToFive()
      } else if version == 3 {
        try migrateSchemaVersionThreeToFour()
        try migrateSchemaVersionFourToFive()
      } else if version == 4 {
        try migrateSchemaVersionFourToFive()
      } else if version != Self.currentSchemaVersion {
        throw HistoryStorageError.sqlite(
          code: SQLITE_ERROR,
          operation: "migrate schema",
          message: "Unsupported schema version \(version)."
        )
      }
    }

    let autoVacuum = try scalarInt64(
      "PRAGMA auto_vacuum",
      operation: "verify incremental auto-vacuum"
    )
    guard autoVacuum == Int64(HistoryAutoVacuumMode.incremental.rawValue) else {
      throw HistoryStorageError.sqlite(
        code: SQLITE_ERROR,
        operation: "verify incremental auto-vacuum",
        message: "Database auto-vacuum mode is \(autoVacuum), expected incremental."
      )
    }
  }

  private func createCurrentSchema() throws {
    try execute(
      """
      CREATE TABLE schema_version (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          version INTEGER NOT NULL
      )
      """,
      operation: "create schema version table"
    )
    try execute(
      """
      CREATE TABLE topics (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          history_source_id TEXT NOT NULL,
          topic TEXT NOT NULL,
          UNIQUE(history_source_id, topic)
      )
      """,
      operation: "create topics table"
    )
    try execute(
      """
      CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
          connection_epoch TEXT,
          connection_ordinal INTEGER,
          operation_id TEXT,
          direction TEXT NOT NULL CHECK (direction IN ('received', 'published')),
          qos INTEGER NOT NULL CHECK (qos BETWEEN 0 AND 2),
          retained INTEGER NOT NULL CHECK (retained IN (0, 1)),
          received_at_microseconds INTEGER NOT NULL,
          payload BLOB NOT NULL,
          payload_original_byte_count INTEGER NOT NULL
              CHECK (payload_original_byte_count >= length(payload)),
          payload_omission_reason TEXT
              CHECK (
                  payload_omission_reason IS NULL
                  OR payload_omission_reason = 'retention-limit'
              ),
          CHECK (
              (
                  payload_omission_reason IS NULL
                  AND payload_original_byte_count = length(payload)
              )
              OR (
                  payload_omission_reason = 'retention-limit'
                  AND length(payload) = 0
                  AND payload_original_byte_count > 0
              )
          ),
          CHECK (
              (
                  direction = 'received'
                  AND operation_id IS NULL
                  AND (
                      (
                          connection_epoch IS NULL
                          AND connection_ordinal IS NULL
                      )
                      OR (
                          connection_epoch IS NOT NULL
                          AND connection_ordinal IS NOT NULL
                      )
                  )
              )
              OR (
                  direction = 'published'
                  AND connection_epoch IS NULL
                  AND connection_ordinal IS NULL
                  AND operation_id IS NOT NULL
              )
          )
      )
      """,
      operation: "create messages table"
    )
    try execute(
      """
      CREATE INDEX messages_topic_order
      ON messages(topic_id, id DESC)
      """,
      operation: "create history index"
    )
    try createCoverageGapSchema()
    try execute(
      "INSERT INTO schema_version(singleton, version) VALUES (1, \(Self.currentSchemaVersion))",
      operation: "record schema version"
    )
  }

  private func migrateSchemaVersionThreeToFour() throws {
    try execute(
      "BEGIN IMMEDIATE",
      operation: "begin schema version four migration"
    )
    do {
      try execute(
        "ALTER TABLE messages ADD COLUMN operation_id TEXT",
        operation: "add publish operation identity"
      )
      try execute(
        "ALTER TABLE messages ADD COLUMN direction TEXT NOT NULL DEFAULT 'received'",
        operation: "add message direction"
      )
      try execute(
        "ALTER TABLE messages ADD COLUMN qos INTEGER NOT NULL DEFAULT 0",
        operation: "add message quality of service"
      )
      try execute(
        "ALTER TABLE messages ADD COLUMN retained INTEGER NOT NULL DEFAULT 0",
        operation: "add retained-delivery metadata"
      )
      try execute(
        "UPDATE schema_version SET version = 4 WHERE singleton = 1",
        operation: "record schema version four"
      )
      try execute(
        "COMMIT",
        operation: "commit schema version four migration"
      )
    } catch {
      try? execute(
        "ROLLBACK",
        operation: "rollback schema version four migration"
      )
      throw error
    }
  }

  private func migrateSchemaVersionFourToFive() throws {
    try execute(
      "BEGIN IMMEDIATE",
      operation: "begin schema version five migration"
    )
    do {
      try execute(
        "ALTER TABLE messages ADD COLUMN payload_original_byte_count INTEGER",
        operation: "add original payload byte count"
      )
      try execute(
        "ALTER TABLE messages ADD COLUMN payload_omission_reason TEXT",
        operation: "add payload omission reason"
      )
      try execute(
        "UPDATE messages SET payload_original_byte_count = length(payload)",
        operation: "backfill original payload byte count"
      )
      try execute(
        "UPDATE schema_version SET version = 5 WHERE singleton = 1",
        operation: "record schema version five"
      )
      try execute(
        "COMMIT",
        operation: "commit schema version five migration"
      )
    } catch {
      try? execute(
        "ROLLBACK",
        operation: "rollback schema version five migration"
      )
      throw error
    }
  }

  private func migrateSchemaVersionOneToTwo() throws {
    try execute("BEGIN IMMEDIATE", operation: "begin schema version two migration")
    do {
      try execute(
        "ALTER TABLE messages ADD COLUMN connection_epoch TEXT",
        operation: "add connection epoch"
      )
      try execute(
        "ALTER TABLE messages ADD COLUMN connection_ordinal INTEGER",
        operation: "add connection ordinal"
      )
      try execute(
        "UPDATE schema_version SET version = 2 WHERE singleton = 1",
        operation: "record schema version two"
      )
      try execute("COMMIT", operation: "commit schema version two migration")
    } catch {
      try? execute("ROLLBACK", operation: "rollback schema version two migration")
      throw error
    }
  }

  private func migrateSchemaVersionTwoToThree() throws {
    try execute(
      "BEGIN IMMEDIATE",
      operation: "begin schema version three migration"
    )
    do {
      try createCoverageGapSchema()
      try execute(
        "UPDATE schema_version SET version = 3 WHERE singleton = 1",
        operation: "record schema version three"
      )
      try execute(
        "COMMIT",
        operation: "commit schema version three migration"
      )
    } catch {
      try? execute(
        "ROLLBACK",
        operation: "rollback schema version three migration"
      )
      throw error
    }
  }

  private func createCoverageGapSchema() throws {
    try execute(
      """
      CREATE TABLE history_coverage_gaps (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          history_source_id TEXT NOT NULL,
          connection_epoch TEXT,
          started_at_microseconds INTEGER NOT NULL,
          ended_at_microseconds INTEGER,
          minimum_missing_message_count INTEGER NOT NULL
              CHECK (minimum_missing_message_count > 0),
          reason TEXT NOT NULL,
          is_open_ended INTEGER NOT NULL CHECK (is_open_ended IN (0, 1)),
          CHECK (
              ended_at_microseconds IS NULL
              OR ended_at_microseconds >= started_at_microseconds
          )
      )
      """,
      operation: "create coverage gaps table"
    )
    try execute(
      """
      CREATE INDEX history_coverage_gaps_source_time
      ON history_coverage_gaps(
          history_source_id,
          started_at_microseconds,
          id
      )
      """,
      operation: "create coverage gaps index"
    )
  }

  private func resolveTopicID(
    for message: HistoryMessageInput,
    insertStatement: OpaquePointer,
    selectStatement: OpaquePointer,
    topicIDs: inout [TopicKey: Int64]
  ) throws -> Int64 {
    let key = TopicKey(
      historySourceID: message.historySourceID,
      topic: message.topic
    )
    if let cached = topicIDs[key] {
      return cached
    }

    try reset(insertStatement, operation: "reset topic insert")
    try bind(
      message.historySourceID,
      to: 1,
      in: insertStatement,
      operation: "bind topic history source"
    )
    try bind(
      message.topic,
      to: 2,
      in: insertStatement,
      operation: "bind topic"
    )
    try expectDone(
      sqlite3_step(insertStatement),
      operation: "insert topic"
    )

    try reset(selectStatement, operation: "reset topic lookup")
    try bind(
      message.historySourceID,
      to: 1,
      in: selectStatement,
      operation: "bind lookup history source"
    )
    try bind(
      message.topic,
      to: 2,
      in: selectStatement,
      operation: "bind lookup topic"
    )
    let result = sqlite3_step(selectStatement)
    guard result == SQLITE_ROW else {
      throw sqliteError(code: result, operation: "look up topic")
    }
    let topicID = sqlite3_column_int64(selectStatement, 0)
    topicIDs[key] = topicID
    return topicID
  }

  private func insert(
    _ message: HistoryMessageInput,
    topicID: Int64,
    statement: OpaquePointer
  ) throws {
    try reset(statement, operation: "reset message insert")
    try check(
      sqlite3_bind_int64(statement, 1, topicID),
      operation: "bind message topic"
    )
    if let connectionEpoch = message.connectionEpoch {
      try bind(
        connectionEpoch.uuidString.lowercased(),
        to: 2,
        in: statement,
        operation: "bind connection epoch"
      )
    } else {
      try check(
        sqlite3_bind_null(statement, 2),
        operation: "bind absent connection epoch"
      )
    }
    if let connectionOrdinal = message.connectionOrdinal {
      try check(
        sqlite3_bind_int64(
          statement,
          3,
          Int64(bitPattern: connectionOrdinal)
        ),
        operation: "bind connection ordinal"
      )
    } else {
      try check(
        sqlite3_bind_null(statement, 3),
        operation: "bind absent connection ordinal"
      )
    }
    if let operationID = message.operationID {
      try bind(
        operationID.rawValue.uuidString.lowercased(),
        to: 4,
        in: statement,
        operation: "bind publish operation identity"
      )
    } else {
      try check(
        sqlite3_bind_null(statement, 4),
        operation: "bind absent publish operation identity"
      )
    }
    try bind(
      message.direction.rawValue,
      to: 5,
      in: statement,
      operation: "bind message direction"
    )
    try check(
      sqlite3_bind_int(statement, 6, Int32(message.qos.rawValue)),
      operation: "bind message quality of service"
    )
    try check(
      sqlite3_bind_int(statement, 7, message.retained ? 1 : 0),
      operation: "bind retained-delivery metadata"
    )
    try check(
      sqlite3_bind_int64(statement, 8, message.receivedAtMicroseconds),
      operation: "bind receive timestamp"
    )
    let blobResult: Int32
    if message.payload.isEmpty {
      blobResult = sqlite3_bind_zeroblob(statement, 9, 0)
    } else {
      blobResult = message.payload.withUnsafeBytes { bytes in
        sqlite3_bind_blob(
          statement,
          9,
          bytes.baseAddress,
          Int32(bytes.count),
          sqliteTransient
        )
      }
    }
    try check(blobResult, operation: "bind payload")
    let originalByteCount =
      message.payloadStorage.originalByteCount ?? message.payload.count
    try check(
      sqlite3_bind_int64(statement, 10, Int64(originalByteCount)),
      operation: "bind original payload byte count"
    )
    switch message.payloadStorage {
    case .stored:
      try check(
        sqlite3_bind_null(statement, 11),
        operation: "bind stored payload status"
      )
    case .omittedByRetentionLimit:
      try bind(
        "retention-limit",
        to: 11,
        in: statement,
        operation: "bind payload omission reason"
      )
    }
    try expectDone(sqlite3_step(statement), operation: "insert message")
  }

  private func validate(_ messages: [HistoryMessageInput]) throws {
    for (index, message) in messages.enumerated() {
      if message.historySourceID.isEmpty {
        throw HistoryStorageError.invalidMessage(
          index: index,
          reason: .emptyHistorySourceID
        )
      }
      if message.topic.isEmpty {
        throw HistoryStorageError.invalidMessage(
          index: index,
          reason: .emptyTopic
        )
      }
      if message.historySourceID.contains("\0") || message.topic.contains("\0") {
        throw HistoryStorageError.invalidMessage(
          index: index,
          reason: .containsNullCharacter
        )
      }
      if message.payload.count > Int(Int32.max) {
        throw HistoryStorageError.invalidMessage(
          index: index,
          reason: .payloadTooLarge(byteCount: message.payload.count)
        )
      }
      let payloadStorageIsValid =
        switch message.payloadStorage {
        case .stored:
          true
        case .omittedByRetentionLimit(let originalByteCount):
          message.payload.isEmpty && originalByteCount > 0
        }
      if !payloadStorageIsValid {
        throw HistoryStorageError.invalidMessage(
          index: index,
          reason: .invalidPayloadStorage
        )
      }
      let hasReceivedIdentity =
        message.connectionEpoch != nil
        && message.connectionOrdinal != nil
      let hasNoReceivedIdentity =
        message.connectionEpoch == nil
        && message.connectionOrdinal == nil
      let identityIsValid =
        switch message.direction {
        case .received:
          message.operationID == nil
            && (hasReceivedIdentity || hasNoReceivedIdentity)
        case .published:
          message.operationID != nil && hasNoReceivedIdentity
        }
      if !identityIsValid {
        throw HistoryStorageError.invalidMessage(
          index: index,
          reason: .invalidIdentity
        )
      }
    }
  }

  private func execute(_ sql: String, operation: String) throws {
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    try check(result, operation: operation)
  }

  private func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw sqliteError(code: result, operation: operation)
    }
    return statement
  }

  private func scalarText(_ sql: String, operation: String) throws -> String {
    let statement = try prepare(sql, operation: operation)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(code: result, operation: operation)
    }
    return textColumn(statement, index: 0)
  }

  private func scalarInt64(_ sql: String, operation: String) throws -> Int64 {
    let statement = try prepare(sql, operation: operation)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(code: result, operation: operation)
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func reset(_ statement: OpaquePointer, operation: String) throws {
    try check(sqlite3_reset(statement), operation: operation)
    try check(sqlite3_clear_bindings(statement), operation: operation)
  }

  private func bind(
    _ value: String,
    to index: Int32,
    in statement: OpaquePointer,
    operation: String
  ) throws {
    try check(
      sqlite3_bind_text(statement, index, value, -1, sqliteTransient),
      operation: operation
    )
  }

  private func expectDone(_ code: Int32, operation: String) throws {
    guard code == SQLITE_DONE else {
      throw sqliteError(code: code, operation: operation)
    }
  }

  private func check(_ code: Int32, operation: String) throws {
    guard code == SQLITE_OK else {
      throw sqliteError(code: code, operation: operation)
    }
  }

  private func sqliteError(code: Int32, operation: String) -> HistoryStorageError {
    HistoryStorageError.sqlite(
      code: code,
      operation: operation,
      message: String(cString: sqlite3_errmsg(database))
    )
  }

}

private struct TopicKey: Hashable {
  let historySourceID: String
  let topic: String
}

private let sqliteTransient = unsafeBitCast(
  -1,
  to: sqlite3_destructor_type.self
)

private func textColumn(_ statement: OpaquePointer, index: Int32) -> String {
  guard let bytes = sqlite3_column_text(statement, index) else { return "" }
  return String(cString: bytes)
}

private func optionalTextColumn(
  _ statement: OpaquePointer,
  index: Int32
) -> String? {
  guard sqlite3_column_type(statement, index) != SQLITE_NULL,
    let bytes = sqlite3_column_text(statement, index)
  else { return nil }
  return String(cString: bytes)
}

private func dataColumn(_ statement: OpaquePointer, index: Int32) -> Data {
  let count = Int(sqlite3_column_bytes(statement, index))
  guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
    return Data()
  }
  return Data(bytes: bytes, count: count)
}

private func payloadStorage(
  storedByteCount: Int,
  originalByteCount: Int,
  omissionReason: String?
) throws -> HistoryPayloadStorage {
  guard let omissionReason else {
    guard originalByteCount == storedByteCount else {
      throw HistoryStorageError.sqlite(
        code: SQLITE_CORRUPT,
        operation: "read payload storage status",
        message: "Stored payload byte metadata is inconsistent."
      )
    }
    return .stored
  }
  guard omissionReason == "retention-limit", storedByteCount == 0,
    originalByteCount > 0
  else {
    throw HistoryStorageError.sqlite(
      code: SQLITE_CORRUPT,
      operation: "read payload storage status",
      message: "Payload omission metadata is invalid."
    )
  }
  return .omittedByRetentionLimit(
    originalByteCount: originalByteCount
  )
}
