import Foundation
import JollysMQTTStorage
import Testing

#if os(macOS)
  import Darwin
#endif

@Suite("SQLite history store")
struct SQLiteHistoryStoreTests {
  @Test("Connection epoch and ordinal survive durable history round trip")
  func connectionIdentityRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    let epoch = UUID()
    _ = try await store.append([
      HistoryMessageInput(
        historySourceID: "source-a",
        connectionEpoch: epoch,
        connectionOrdinal: 42,
        topic: "identity",
        receivedAtMicroseconds: 7,
        payload: Data([0x2A])
      )
    ])

    let message = try #require(
      try await store.newestMessages(
        historySourceID: "source-a",
        topic: "identity",
        limit: 1
      ).first
    )
    #expect(message.connectionEpoch == epoch)
    #expect(message.connectionOrdinal == 42)
  }

  @Test("Equal receive timestamps use durable insertion order newest first")
  func equalTimestampOrdering() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    let timestamp: Int64 = 1_721_234_567_890_123
    let inputs = (1...3).map {
      HistoryMessageInput(
        historySourceID: "source-a",
        topic: "sensors/temperature",
        receivedAtMicroseconds: timestamp,
        payload: Data("value-\($0)".utf8)
      )
    }

    let append = try await store.append(inputs)
    let newest = try await store.newestMessages(
      historySourceID: "source-a",
      topic: "sensors/temperature",
      limit: 10
    )

    #expect(append.insertedCount == 3)
    #expect(newest.map(\.payload) == inputs.reversed().map(\.payload))
    #expect(newest.map(\.durableOrder) == newest.map(\.durableOrder).sorted(by: >))
    #expect(Set(newest.map(\.receivedAtMicroseconds)) == [timestamp])
  }

  @Test("Incremental pruning preserves the newest rows and never reuses durable order")
  func incrementalPruningAndDurableOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    let firstBatch = (1...5).map {
      HistoryMessageInput(
        historySourceID: "source-a",
        topic: "events",
        receivedAtMicroseconds: Int64($0),
        payload: Data([$0])
      )
    }
    let append = try await store.append(firstBatch)

    let firstPrune = try await store.prune(
      keepingNewestPerTopic: 2,
      batchLimit: 2
    )
    let secondPrune = try await store.prune(
      keepingNewestPerTopic: 2,
      batchLimit: 2
    )
    let retained = try await store.newestMessages(
      historySourceID: "source-a",
      topic: "events",
      limit: 10
    )
    let afterPruning = try await store.diagnostics()
    let later = try await store.append([
      HistoryMessageInput(
        historySourceID: "source-a",
        topic: "events",
        receivedAtMicroseconds: 6,
        payload: Data([6])
      )
    ])

    #expect(firstPrune == HistoryPruneResult(deletedCount: 2, remainingCount: 3))
    #expect(secondPrune == HistoryPruneResult(deletedCount: 1, remainingCount: 2))
    #expect(retained.map(\.payload) == [Data([5]), Data([4])])
    #expect(afterPruning.writeAheadLogBytes == 0)
    #expect(later.firstDurableOrder == (append.lastDurableOrder ?? 0) + 1)
  }

  @Test("WAL and schema state are observable and a truncate checkpoint drains the WAL")
  func walSchemaAndCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    let payload = Data(repeating: 0xA5, count: 256)
    _ = try await store.append(
      (0..<100).map {
        HistoryMessageInput(
          historySourceID: "source-a",
          topic: "topic/\($0 % 10)",
          receivedAtMicroseconds: Int64($0),
          payload: payload
        )
      }
    )

    let before = try await store.diagnostics()
    let checkpoint = try await store.checkpoint(.truncate)
    let after = try await store.diagnostics()

    #expect(before.schemaVersion == SQLiteHistoryStore.currentSchemaVersion)
    #expect(before.journalMode == "wal")
    #expect(before.messageCount == 100)
    #expect(before.writeAheadLogBytes > 0)
    #expect(checkpoint.wasBusy == false)
    #expect(checkpoint.checkpointedFrameCount >= 0)
    #expect(after.writeAheadLogBytes == 0)
  }

  @Test("File policy covers the database and both WAL sidecars and can be reapplied")
  func filePolicyCoversEverySQLiteFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "history.sqlite")
    let policy = RecordingHistoryFilePolicy()

    let store = try await SQLiteHistoryStore.open(
      databaseURL: databaseURL,
      filePolicy: policy
    )
    try await store.refreshFilePolicy()
    let applications = await policy.applications

    for role in HistoryFileRole.allCases {
      #expect(
        FileManager.default.fileExists(
          atPath: role.url(for: databaseURL).path
        )
      )
      let roleApplications = applications.filter { $0.role == role }
      #expect(roleApplications.count == 2)
      #expect(roleApplications.allSatisfy { $0.url == role.url(for: databaseURL) })
    }
  }

  @Test("Per-topic retention does not evict sparse topics")
  func perTopicRetention() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    let busyTopic = (1...5).map {
      HistoryMessageInput(
        historySourceID: "source-a",
        topic: "busy",
        receivedAtMicroseconds: Int64($0),
        payload: Data([$0])
      )
    }
    _ = try await store.append(
      busyTopic + [
        HistoryMessageInput(
          historySourceID: "source-a",
          topic: "sparse",
          receivedAtMicroseconds: 1,
          payload: Data([0xFF])
        )
      ]
    )

    let prune = try await store.prune(
      keepingNewestPerTopic: 2,
      batchLimit: 10
    )
    let busy = try await store.newestMessages(
      historySourceID: "source-a",
      topic: "busy",
      limit: 10
    )
    let sparse = try await store.newestMessages(
      historySourceID: "source-a",
      topic: "sparse",
      limit: 10
    )

    #expect(prune == HistoryPruneResult(deletedCount: 3, remainingCount: 3))
    #expect(busy.map(\.payload) == [Data([5]), Data([4])])
    #expect(sparse.map(\.payload) == [Data([0xFF])])
  }

  @Test("System file policy excludes every SQLite file from backup")
  func systemFilePolicyExcludesBackup() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "history.sqlite")
    let policy = SystemHistoryFilePolicy()

    for role in HistoryFileRole.allCases {
      let url = role.url(for: databaseURL)
      #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
      try await policy.apply(to: url, role: role)
      let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
      #expect(values.isExcludedFromBackup == true)
    }
  }

  @Test("Filesystem footprint measurement includes all SQLite files")
  func filesystemFootprintMeasurement() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "history.sqlite")
    let byteCounts: [HistoryFileRole: Int] = [
      .database: 11,
      .writeAheadLog: 13,
      .sharedMemory: 17,
    ]
    for (role, byteCount) in byteCounts {
      #expect(
        FileManager.default.createFile(
          atPath: role.url(for: databaseURL).path,
          contents: Data(repeating: 0xAB, count: byteCount)
        )
      )
    }

    let sizes = HistoryFileSizes.measure(databaseURL: databaseURL)

    #expect(sizes.databaseBytes == 11)
    #expect(sizes.writeAheadLogBytes == 13)
    #expect(sizes.sharedMemoryBytes == 17)
    #expect(sizes.totalSQLiteBytes == 41)
  }

  @Test("Bounded broker-size pruning reclaims pages incrementally")
  func brokerSizePruning() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    let payload = Data(repeating: 0x5A, count: 1_024)
    _ = try await store.append(
      (0..<2_000).map {
        HistoryMessageInput(
          historySourceID: "source-a",
          topic: "large",
          receivedAtMicroseconds: Int64($0),
          payload: payload
        )
      }
    )
    _ = try await store.checkpoint(.truncate)
    let before = try await store.diagnostics()
    var last: HistorySizePruneResult?
    var targetReached = before.totalSQLiteBytes <= 512 * 1_024

    for _ in 0..<8 where targetReached == false {
      last = try await store.pruneToMaximumBytes(
        512 * 1_024,
        batchLimit: 400,
        vacuumPageLimit: 512
      )
      targetReached = last?.targetReached == true
    }
    let after = try await store.diagnostics()

    #expect(before.autoVacuumMode == .incremental)
    #expect(targetReached)
    #expect(after.totalSQLiteBytes <= 512 * 1_024)
    #expect(after.totalSQLiteBytes < before.totalSQLiteBytes)
    #expect(after.messageCount < before.messageCount)
  }

  @Test("Bounded size maintenance removes normalized topics after their messages")
  func brokerSizePruningRemovesOrphanTopics() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    _ = try await store.append(
      (0..<300).map {
        HistoryMessageInput(
          historySourceID: "churn-source",
          topic: "ephemeral/\($0)",
          receivedAtMicroseconds: Int64($0),
          payload: Data(repeating: 0xA5, count: 64)
        )
      }
    )

    var sawTopicDeletion = false
    for _ in 0..<20 {
      let result = try await store.pruneToMaximumBytes(
        0,
        batchLimit: 50,
        vacuumPageLimit: 128
      )
      sawTopicDeletion = sawTopicDeletion || result.deletedTopicCount > 0
      if result.requiresMorePruning == false {
        break
      }
    }
    let after = try await store.diagnostics()

    #expect(sawTopicDeletion)
    #expect(after.messageCount == 0)
    #expect(after.topicCount == 0)
  }

  @Test("Size maintenance reclaims existing freelist pages before deleting more history")
  func brokerSizePruningUsesExistingFreelistFirst() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    _ = try await store.append(
      (0..<2_000).map {
        HistoryMessageInput(
          historySourceID: "source-a",
          topic: "freelist",
          receivedAtMicroseconds: Int64($0),
          payload: Data(repeating: 0xC3, count: 1_024)
        )
      }
    )
    _ = try await store.checkpoint(.truncate)
    _ = try await store.pruneToMaximumBytes(
      0,
      batchLimit: 1_000,
      vacuumPageLimit: 1
    )
    let withFreelist = try await store.diagnostics()
    try #require(withFreelist.freePageCount > 0)

    let vacuumOnly = try await store.pruneToMaximumBytes(
      0,
      batchLimit: 1,
      vacuumPageLimit: 1
    )
    #expect(vacuumOnly.deletedCount == 0)
    #expect(vacuumOnly.deletedTopicCount == 0)
    #expect(vacuumOnly.remainingFreePageCount > 0)
    #expect(vacuumOnly.requiresMorePruning)
    let afterVacuumStep = try await store.diagnostics()

    let result = try await store.pruneToMaximumBytes(
      afterVacuumStep.totalSQLiteBytes - Int64(afterVacuumStep.pageSizeBytes),
      batchLimit: 1,
      vacuumPageLimit: 128
    )

    #expect(result.deletedCount == 0)
    #expect(result.deletedTopicCount == 0)
    #expect(result.targetReached)
    #expect(result.bytesAfter < result.bytesBefore)
  }

  #if os(macOS)
    @Test("A version-one database migrates without losing existing history")
    func versionOneMigration() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let databaseURL = directory.appending(path: "history.sqlite")
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/sqlite3")
      process.arguments = [
        databaseURL.path,
        """
        PRAGMA auto_vacuum = INCREMENTAL;
        CREATE TABLE schema_version (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          version INTEGER NOT NULL
        );
        CREATE TABLE topics (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          history_source_id TEXT NOT NULL,
          topic TEXT NOT NULL,
          UNIQUE(history_source_id, topic)
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
          received_at_microseconds INTEGER NOT NULL,
          payload BLOB NOT NULL
        );
        CREATE INDEX messages_topic_order ON messages(topic_id, id DESC);
        INSERT INTO schema_version(singleton, version) VALUES (1, 1);
        INSERT INTO topics(history_source_id, topic) VALUES ('source-a', 'legacy');
        INSERT INTO messages(topic_id, received_at_microseconds, payload)
          SELECT id, 1, X'01' FROM topics;
        """,
      ]
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)

      let store = try await SQLiteHistoryStore.open(databaseURL: databaseURL)
      #expect(
        try await store.diagnostics().schemaVersion
          == SQLiteHistoryStore.currentSchemaVersion
      )
      let legacy = try await store.newestMessages(
        historySourceID: "source-a",
        topic: "legacy",
        limit: 1
      )
      #expect(legacy.first?.payload == Data([1]))
      #expect(legacy.first?.connectionEpoch == nil)
      #expect(legacy.first?.connectionOrdinal == nil)
    }

    @Test("An interrupted uncommitted write recovers without partial history")
    func interruptedWriteRecovery() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let databaseURL = directory.appending(path: "history.sqlite")
      var initialStore: SQLiteHistoryStore? = try await SQLiteHistoryStore.open(
        databaseURL: databaseURL
      )
      _ = try await initialStore?.append([
        HistoryMessageInput(
          historySourceID: "source-a",
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
          WHERE history_source_id = 'source-a' AND topic = 'recovery';
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
      try #require(process.isRunning)
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      #expect(process.terminationReason == .uncaughtSignal)
      #expect(process.terminationStatus == SIGKILL)

      let recovered = try await SQLiteHistoryStore.open(databaseURL: databaseURL)
      #expect(try await recovered.integrityCheck() == "ok")
      #expect(try await recovered.diagnostics().messageCount == 1)
      _ = try await recovered.append([
        HistoryMessageInput(
          historySourceID: "source-a",
          topic: "recovery",
          receivedAtMicroseconds: 3,
          payload: Data([3])
        )
      ])
      let messages = try await recovered.newestMessages(
        historySourceID: "source-a",
        topic: "recovery",
        limit: 10
      )
      #expect(messages.map(\.payload) == [Data([3]), Data([1])])
    }
  #endif

  @Test("Zero-byte payloads round trip and invalid batches write nothing")
  func payloadBindingAndAtomicValidation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "JollysMQTTStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHistoryStore.open(
      databaseURL: directory.appending(path: "history.sqlite")
    )
    _ = try await store.append([
      HistoryMessageInput(
        historySourceID: "source-a",
        topic: "empty-payload",
        receivedAtMicroseconds: 1,
        payload: Data()
      )
    ])

    do {
      _ = try await store.append([
        HistoryMessageInput(
          historySourceID: "source-a",
          topic: "valid",
          receivedAtMicroseconds: 2,
          payload: Data([2])
        ),
        HistoryMessageInput(
          historySourceID: "source-a",
          topic: "",
          receivedAtMicroseconds: 3,
          payload: Data([3])
        ),
      ])
      Issue.record("Invalid topic unexpectedly committed.")
    } catch let error as HistoryStorageError {
      #expect(error == .invalidMessage(index: 1, reason: .emptyTopic))
    }

    let empty = try await store.newestMessages(
      historySourceID: "source-a",
      topic: "empty-payload",
      limit: 1
    )
    #expect(empty.map(\.payload) == [Data()])
    #expect(try await store.diagnostics().messageCount == 1)
  }
}

private actor RecordingHistoryFilePolicy: HistoryFilePolicy {
  struct Application: Sendable {
    let url: URL
    let role: HistoryFileRole
  }

  private(set) var applications: [Application] = []

  func apply(to url: URL, role: HistoryFileRole) {
    applications.append(Application(url: url, role: role))
  }
}
