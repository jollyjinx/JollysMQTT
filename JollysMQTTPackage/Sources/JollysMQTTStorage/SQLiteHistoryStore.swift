import CSQLite
import Foundation

public actor SQLiteHistoryStore {
  public static let currentSchemaVersion = 1

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
        INSERT INTO messages(topic_id, received_at_microseconds, payload)
        VALUES (?, ?, ?)
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
    guard limit >= 0, limit <= Int(Int32.max) else {
      throw HistoryStorageError.invalidLimit(limit)
    }
    guard limit > 0 else { return [] }

    let statement = try prepare(
      """
      SELECT
          messages.id,
          topics.history_source_id,
          topics.topic,
          messages.received_at_microseconds,
          messages.payload
      FROM messages
      JOIN topics ON topics.id = messages.topic_id
      WHERE topics.history_source_id = ? AND topics.topic = ?
      ORDER BY messages.id DESC
      LIMIT ?
      """,
      operation: "prepare newest history query"
    )
    defer { sqlite3_finalize(statement) }

    try bind(historySourceID, to: 1, in: statement, operation: "bind history source")
    try bind(topic, to: 2, in: statement, operation: "bind topic")
    try check(
      sqlite3_bind_int(statement, 3, Int32(limit)),
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
            topic: textColumn(statement, index: 2),
            receivedAtMicroseconds: sqlite3_column_int64(statement, 3),
            payload: dataColumn(statement, index: 4)
          )
        )
      case SQLITE_DONE:
        return messages
      default:
        throw sqliteError(code: result, operation: "read newest history")
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
      _ = try checkpoint(.truncate)
      return HistoryPruneResult(
        deletedCount: deleted,
        remainingCount: Int(countBefore) - deleted
      )
    } catch {
      try? execute("ROLLBACK", operation: "rollback pruning")
      throw error
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
        try createSchemaVersionOne()
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
      guard version == Self.currentSchemaVersion else {
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

  private func createSchemaVersionOne() throws {
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
          received_at_microseconds INTEGER NOT NULL,
          payload BLOB NOT NULL
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
    try execute(
      "INSERT INTO schema_version(singleton, version) VALUES (1, \(Self.currentSchemaVersion))",
      operation: "record schema version"
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
    try check(
      sqlite3_bind_int64(statement, 2, message.receivedAtMicroseconds),
      operation: "bind receive timestamp"
    )
    let blobResult: Int32
    if message.payload.isEmpty {
      blobResult = sqlite3_bind_zeroblob(statement, 3, 0)
    } else {
      blobResult = message.payload.withUnsafeBytes { bytes in
        sqlite3_bind_blob(
          statement,
          3,
          bytes.baseAddress,
          Int32(bytes.count),
          sqliteTransient
        )
      }
    }
    try check(blobResult, operation: "bind payload")
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

private func dataColumn(_ statement: OpaquePointer, index: Int32) -> Data {
  let count = Int(sqlite3_column_bytes(statement, index))
  guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
    return Data()
  }
  return Data(bytes: bytes, count: count)
}
