import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTTStorage

#if canImport(CloudKit)
  import CloudKit
#endif

@Suite("Local-first profile synchronization")
struct ProfileSyncTests {
  @Test("Local-only sync is the safe no-remote default")
  func localOnlyIsSafeDefault() async throws {
    let localOnly = LocalOnlyProfileSync()
    let profile = rankedProfile(name: "Local")

    #expect(await localOnly.status() == .localOnly)
    #expect(
      await localOnly.stageLocalProfiles(
        ProfileSyncSnapshot(generation: 9, profiles: [profile])
      ) == .localOnly
    )
    #expect(await localOnly.synchronize() == .noChanges)
  }

  @Test("An existing local profile is staged on the first load after upgrade")
  func firstLoadStagesExistingProfile() async throws {
    let local = MemoryProfileRepository(
      profiles: [rankedProfile(name: "Existing")]
    )
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )

    let loaded = try await repository.load()

    #expect(loaded.map(\.profile.name) == ["Existing"])
    #expect(
      await sync.stagedSnapshots()
        == [
          ProfileSyncSnapshot(
            generation: 0,
            profiles: loaded
          )
        ]
    )
  }

  @Test("Sync failure never changes a successful atomic local write")
  func syncFailureDoesNotFailLocalWrite() async throws {
    let local = MemoryProfileRepository()
    let failure = ProfileSyncFailure(
      kind: .offline,
      isRetryable: true
    )
    let sync = ScriptedProfileSync(stageStatus: .retryScheduled(failure))
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )
    let expected = rankedProfile(name: "Offline edit")

    try await repository.replaceAll([expected])

    #expect(try await repository.load() == [expected])
    #expect(await repository.syncStatus() == .retryScheduled(failure))
  }

  @Test("Concurrent local writes commit and stage in call-intent order")
  func localWritesUseFIFO() async throws {
    let local = GatedProfileRepository(blockedWriteNumbers: [1])
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )
    let first = rankedProfile(name: "First")
    let second = rankedProfile(name: "Second")

    let firstTask = Task {
      try await repository.replaceAll([first])
    }
    await local.waitForWriteCount(1)
    let secondTask = Task {
      try await repository.replaceAll([second])
    }
    await Task.yield()
    await local.releaseWrite(1)
    try await firstTask.value
    try await secondTask.value

    #expect(await local.committedWrites() == [[first], [second]])
    #expect(await local.load() == [second])
    #expect(
      await sync.stagedSnapshots().map(\.generation) == [1, 2]
    )
    #expect(
      await sync.stagedSnapshots().last?.profiles == [second]
    )
  }

  @Test("A canceled queued writer preserves FIFO for the writer behind it")
  func canceledQueuedWriterPreservesTail() async throws {
    let local = GatedProfileRepository(blockedWriteNumbers: [1])
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )
    let first = rankedProfile(name: "First")
    let canceled = rankedProfile(name: "Canceled")
    let third = rankedProfile(name: "Third")

    let firstTask = Task {
      try await repository.replaceAll([first])
    }
    await local.waitForWriteCount(1)
    let canceledTask = Task {
      try await repository.replaceAll([canceled])
    }
    canceledTask.cancel()
    let thirdTask = Task {
      try await repository.replaceAll([third])
    }
    await local.releaseWrite(1)

    try await firstTask.value
    await #expect(throws: CancellationError.self) {
      try await canceledTask.value
    }
    try await thirdTask.value
    #expect(await local.committedWrites() == [[first], [third]])
    #expect(
      await sync.stagedSnapshots().map(\.generation) == [1, 3]
    )
  }

  @Test("A newer sync completion cannot be overwritten by an older completion")
  func staleConcurrentSyncCompletionIsIgnored() async throws {
    let initial = rankedProfile(name: "Initial")
    let olderRemote = rankedProfile(
      id: initial.id,
      name: "Older remote"
    )
    let newerRemote = rankedProfile(
      id: initial.id,
      name: "Newer remote"
    )
    let local = MemoryProfileRepository(profiles: [initial])
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )
    _ = try await repository.load()

    let olderTask = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    let newerTask = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(2)

    await sync.completeSynchronize(
      2,
      with: .success(
        ProfileSyncExchange(remoteProfiles: [newerRemote])
      )
    )
    _ = try await newerTask.value
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteProfiles: [olderRemote])
      )
    )
    _ = try await olderTask.value

    #expect(await local.load() == [newerRemote])
    #expect(await repository.syncStatus() == .available)
  }

  @Test("A failed latest local write does not block a later remote apply")
  func failedLocalWriteRestoresCommittedGeneration() async throws {
    let initial = rankedProfile(name: "Initial")
    let rejected = rankedProfile(
      id: initial.id,
      name: "Rejected local"
    )
    let remote = rankedProfile(
      id: initial.id,
      name: "Remote after failure"
    )
    let local = GatedProfileRepository(
      profiles: [initial],
      blockedWriteNumbers: [],
      failedWriteNumbers: [1]
    )
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )
    _ = try await repository.load()

    await #expect(throws: ProfileSyncTestError.rejected) {
      try await repository.replaceAll([rejected])
    }

    let task = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteProfiles: [remote])
      )
    )
    _ = try await task.value

    #expect(await local.load() == [remote])
  }

  @Test("A local edit queued during remote apply commits last")
  func localEditWinsDuringRemoteApply() async throws {
    let initial = rankedProfile(name: "Initial")
    let remote = rankedProfile(id: initial.id, name: "Remote")
    let localEdit = rankedProfile(id: initial.id, name: "Local edit")
    let local = GatedProfileRepository(
      profiles: [initial],
      blockedWriteNumbers: [1]
    )
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )
    _ = try await repository.load()

    let syncTask = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteProfiles: [remote])
      )
    )
    await local.waitForWriteCount(1)

    let editTask = Task {
      try await repository.replaceAll([localEdit])
    }
    await local.releaseWrite(1)
    _ = try await syncTask.value
    try await editTask.value

    #expect(await local.committedWrites() == [[remote], [localEdit]])
    #expect(await local.load() == [localEdit])
  }

  @Test("Retryable failure retains the staged upload for retry")
  func retryRetainsPendingUpload() async throws {
    let profile = rankedProfile(name: "Pending")
    let retryFailure = ProfileSyncFailure(
      kind: .rateLimited,
      isRetryable: true,
      retryAfterSeconds: 17
    )
    let local = MemoryProfileRepository(profiles: [profile])
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )
    _ = try await repository.load()

    let first = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    await sync.completeSynchronize(
      1,
      with: .failure(retryFailure)
    )
    #expect(
      try await first.value == .retryScheduled(retryFailure)
    )

    let second = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(2)
    await sync.completeSynchronize(
      2,
      with: .success(.noChanges)
    )
    #expect(try await second.value == .available)
    #expect(await sync.latestStagedProfiles() == [profile])
  }

  @Test("Invalid remote profile keeps the last-known-good local profile")
  func invalidRemoteKeepsLocal() async throws {
    let localProfile = rankedProfile(name: "Known good")
    let invalid = RankedBrokerProfile(
      profile: .new(id: localProfile.id, name: "", host: ""),
      reorderRank: 10
    )
    let local = MemoryProfileRepository(profiles: [localProfile])
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )

    let task = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteProfiles: [invalid])
      )
    )

    #expect(
      try await task.value
        == .failed(
          ProfileSyncFailure(
            kind: .invalidRemoteProfile,
            isRetryable: false
          )
        )
    )
    #expect(await local.load() == [localProfile])
  }

  @Test("Corrupt primary local data restores through the atomic backup before sync")
  func localBackupRemainsLastKnownGood() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let original = rankedProfile(name: "Backup")
    let newer = rankedProfile(name: "Primary")
    let atomic = LocalProfileRepository(fileURL: fileURL)
    try await atomic.replaceAll([original])
    try await atomic.replaceAll([newer])
    try Data("{corrupt".utf8).write(to: fileURL)

    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: LocalProfileRepository(fileURL: fileURL),
      sync: sync
    )

    #expect(try await repository.load() == [original])
    #expect(await sync.latestStagedProfiles() == [original])
  }

  @Test("Empty remote change set is not an authoritative delete-all")
  func noRemoteChangesPreservesLocalProfiles() async throws {
    let profile = rankedProfile(name: "Keep")
    let local = MemoryProfileRepository(profiles: [profile])
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )

    let task = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteProfiles: [])
      )
    )
    _ = try await task.value

    #expect(await local.load() == [profile])
  }
}

@Suite("Profile sync state persistence")
struct ProfileSyncStateStoreTests {
  @Test("Atomic state save retains a usable backup candidate")
  func corruptPrimaryHasBackupCandidate() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "sync-state")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalProfileSyncStateStore(fileURL: fileURL)
    let original = Data("opaque-state-1".utf8)
    let newer = Data("opaque-state-2".utf8)

    try await store.save(original)
    try await store.save(newer)
    try Data("corrupt".utf8).write(to: fileURL)

    let candidates = try await store.loadCandidates()
    #expect(candidates.primary == Data("corrupt".utf8))
    #expect(candidates.backup == original)

    try await store.restoreBackup()
    let repaired = try await store.loadCandidates()
    #expect(repaired.primary == original)
    #expect(repaired.backup == original)

    let afterRecovery = Data("opaque-state-3".utf8)
    try await store.save(afterRecovery)
    let saved = try await store.loadCandidates()
    #expect(saved.primary == afterRecovery)
    #expect(saved.backup == original)
  }

  @Test("Persisted opaque state restores unchanged in a new store instance")
  func stateRestoresAfterRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "sync-state")
    defer { try? FileManager.default.removeItem(at: directory) }
    let expected = Data((0..<256).map(UInt8.init))

    try await LocalProfileSyncStateStore(fileURL: fileURL)
      .save(expected)
    let restored = try await LocalProfileSyncStateStore(
      fileURL: fileURL
    ).loadCandidates()

    #expect(restored.primary == expected)
  }

  @Test("State restoration selects and marks a valid backup when primary decoding fails")
  func restorationSelectsValidBackup() {
    let selection: ProfileSyncStateSelection<String> =
      selectProfileSyncState(
        from: ProfileSyncStateCandidates(
          primary: Data("corrupt".utf8),
          backup: Data("valid:engine-state".utf8)
        ),
        decode: { data in
          guard
            let value = String(data: data, encoding: .utf8),
            value.hasPrefix("valid:")
          else { return nil }
          return value
        }
      )

    #expect(selection.state == "valid:engine-state")
    #expect(selection.usedBackup)
  }
}

#if canImport(CloudKit)
  @Suite("CloudKit profile sync engine boundary")
  struct CloudKitProfileSyncEngineTests {
    @Test("Adapter stages an initial upload through the engine boundary")
    func stagesInitialUpload() async {
      let engine = ScriptedProfileSyncEngine()
      let adapter = CloudKitProfileSync(engine: engine)
      let snapshot = ProfileSyncSnapshot(
        generation: 0,
        profiles: [rankedProfile(name: "Existing")]
      )

      #expect(
        await adapter.stageLocalProfiles(snapshot) == .available
      )
      #expect(await engine.stagedSnapshots() == [snapshot])
    }

    @Test("Retryable engine failure retains pending upload and retry succeeds")
    func retryRetainsEngineSnapshot() async throws {
      let engine = ScriptedProfileSyncEngine()
      let adapter = CloudKitProfileSync(engine: engine)
      let snapshot = ProfileSyncSnapshot(
        generation: 7,
        profiles: [rankedProfile(name: "Offline edit")]
      )
      let failure = ProfileSyncFailure(
        kind: .offline,
        isRetryable: true,
        retryAfterSeconds: 11
      )
      _ = await adapter.stageLocalProfiles(snapshot)

      let first = Task {
        try await adapter.synchronize()
      }
      await engine.waitForSynchronizeCount(1)
      await engine.completeSynchronize(
        1,
        with: .failure(failure)
      )
      await #expect(throws: failure) {
        try await first.value
      }
      #expect(
        await adapter.status() == .retryScheduled(failure)
      )
      #expect(await engine.stagedSnapshots().last == snapshot)

      let newerSnapshot = ProfileSyncSnapshot(
        generation: 8,
        profiles: [rankedProfile(name: "Newer offline edit")]
      )
      #expect(
        await adapter.stageLocalProfiles(newerSnapshot)
          == .retryScheduled(failure)
      )
      #expect(await engine.stagedSnapshots().last == newerSnapshot)

      let second = Task {
        try await adapter.synchronize()
      }
      await engine.waitForSynchronizeCount(2)
      await engine.completeSynchronize(
        2,
        with: .success(.noChanges)
      )

      #expect(try await second.value == .noChanges)
      #expect(await adapter.status() == .available)
      #expect(await engine.stagedSnapshots().last == newerSnapshot)
    }

    @Test("Canceling queued B keeps running A ahead of C")
    func canceledQueuedSyncPreservesTail() async throws {
      let engine = ScriptedProfileSyncEngine()
      let adapter = CloudKitProfileSync(engine: engine)

      let first = Task {
        try await adapter.synchronize()
      }
      await engine.waitForSynchronizeCount(1)

      let canceled = Task {
        try await adapter.synchronize()
      }
      await Task.yield()
      canceled.cancel()
      let third = Task {
        try await adapter.synchronize()
      }
      await Task.yield()

      #expect(await engine.currentSynchronizeCount() == 1)
      await engine.completeSynchronize(
        1,
        with: .success(.noChanges)
      )
      #expect(try await first.value == .noChanges)
      await #expect(throws: CancellationError.self) {
        try await canceled.value
      }

      await engine.waitForSynchronizeCount(2)
      await engine.completeSynchronize(
        2,
        with: .success(.noChanges)
      )
      #expect(try await third.value == .noChanges)
      #expect(await engine.maximumConcurrentSynchronizations() == 1)
      #expect(await adapter.status() == .available)
    }

    @Test("Explicit cancellation reaches the active engine operation")
    func cancellationReachesEngine() async throws {
      let engine = ScriptedProfileSyncEngine()
      let adapter = CloudKitProfileSync(engine: engine)
      let operation = Task {
        try await adapter.synchronize()
      }
      await engine.waitForSynchronizeCount(1)

      await adapter.cancel()

      await #expect(throws: CancellationError.self) {
        try await operation.value
      }
      #expect(await engine.cancelCount() == 1)
      #expect(await adapter.status() == .available)
    }
  }

  @Suite("Encrypted CloudKit profile record codec")
  struct CloudKitProfileRecordCodecTests {
    @Test("Record name is exactly the profile UUID and round-trips")
    func exactUUIDRecordName() throws {
      let id = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
      )!
      let profile = rankedProfile(id: id, name: "Private")
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )

      let record = try codec.encode(profile)

      #expect(record.recordID.recordName == id.uuidString.lowercased())
      #expect(UUID(uuidString: record.recordID.recordName) == id)
      #expect(try codec.decode(record) == profile)
    }

    @Test("Every private profile field exists only in encrypted values")
    func privateValuesNeverUseOrdinaryFields() throws {
      let profile = rankedProfile(
        name: "Private Lab",
        host: "secret-broker.example",
        username: "private-operator",
        filter: "private/site/#"
      )
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )

      let record = try codec.encode(profile)
      let encryptedData = try #require(
        record.encryptedValues[
          CloudKitProfileRecordCodec.encryptedPayloadKey
        ] as? Data
      )
      let encryptedText = try #require(
        String(data: encryptedData, encoding: .utf8)
      )

      #expect(
        Set(record.allKeys())
          == [CloudKitProfileRecordCodec.encryptedPayloadKey]
      )
      #expect(
        record[
          CloudKitProfileRecordCodec.encryptedPayloadKey
        ] == nil
      )
      #expect(
        Set(record.encryptedValues.allKeys())
          == [CloudKitProfileRecordCodec.encryptedPayloadKey]
      )
      for privateValue in [
        profile.profile.name,
        profile.profile.host,
        profile.profile.username!,
        profile.profile.subscriptions[0].filter,
      ] {
        #expect(encryptedText.contains(privateValue))
        #expect(
          String(
            describing:
              record[
                CloudKitProfileRecordCodec.encryptedPayloadKey
              ]
          ).contains(privateValue) == false
        )
      }
      for excludedSchema in [
        "password",
        "credential",
        "history",
        "workspace",
        "payloadHistory",
      ] {
        #expect(
          encryptedText.localizedCaseInsensitiveContains(
            excludedSchema
          ) == false
        )
      }
    }

    @Test("Metadata suffixes and ordinary fields are rejected")
    func rejectsLeakyRecordMetadata() throws {
      let profile = rankedProfile(name: "Private")
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )
      let encoded = try codec.encode(profile)
      let suffixed = CKRecord(
        recordType: encoded.recordType,
        recordID: CKRecord.ID(
          recordName: profile.id.uuidString.lowercased() + "-broker",
          zoneID: encoded.recordID.zoneID
        )
      )
      suffixed.encryptedValues[
        CloudKitProfileRecordCodec.encryptedPayloadKey
      ] =
        encoded.encryptedValues[
          CloudKitProfileRecordCodec.encryptedPayloadKey
        ]

      #expect(throws: ProfileSyncFailure.self) {
        try codec.decode(suffixed)
      }

      encoded["host"] = profile.profile.host
      #expect(throws: ProfileSyncFailure.self) {
        try codec.decode(encoded)
      }
    }
  }
#endif

private actor ScriptedProfileSyncEngine: ProfileSyncEngine {
  private var snapshots: [ProfileSyncSnapshot] = []
  private var synchronizeCount = 0
  private var activeSynchronizations = 0
  private var maximumActiveSynchronizations = 0
  private var recordedCancelCount = 0
  private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var completions:
    [Int:
      CheckedContinuation<
        ProfileSyncExchange,
        any Error
      >] = [:]

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) {
    guard
      snapshot.generation
        >= (snapshots.last?.generation ?? 0)
    else { return }
    snapshots.append(snapshot)
  }

  func synchronize() async throws -> ProfileSyncExchange {
    synchronizeCount += 1
    activeSynchronizations += 1
    maximumActiveSynchronizations = max(
      maximumActiveSynchronizations,
      activeSynchronizations
    )
    let number = synchronizeCount
    resumeCountWaiters()
    do {
      let exchange = try await withCheckedThrowingContinuation {
        continuation in
        completions[number] = continuation
      }
      activeSynchronizations -= 1
      return exchange
    } catch {
      activeSynchronizations -= 1
      throw error
    }
  }

  func cancel() {
    recordedCancelCount += 1
    let pending = completions
    completions.removeAll()
    for continuation in pending.values {
      continuation.resume(throwing: CancellationError())
    }
  }

  func waitForSynchronizeCount(_ expected: Int) async {
    guard synchronizeCount < expected else { return }
    await withCheckedContinuation { continuation in
      countWaiters.append((expected, continuation))
    }
  }

  func completeSynchronize(
    _ number: Int,
    with result: Result<ProfileSyncExchange, any Error>
  ) {
    completions.removeValue(forKey: number)?
      .resume(with: result)
  }

  func stagedSnapshots() -> [ProfileSyncSnapshot] {
    snapshots
  }

  func currentSynchronizeCount() -> Int {
    synchronizeCount
  }

  func maximumConcurrentSynchronizations() -> Int {
    maximumActiveSynchronizations
  }

  func cancelCount() -> Int {
    recordedCancelCount
  }

  private func resumeCountWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for waiter in countWaiters {
      if synchronizeCount >= waiter.0 {
        waiter.1.resume()
      } else {
        remaining.append(waiter)
      }
    }
    countWaiters = remaining
  }
}

private actor MemoryProfileRepository: ProfileRepositoryProtocol {
  private var profiles: [RankedBrokerProfile]

  init(profiles: [RankedBrokerProfile] = []) {
    self.profiles = profiles
  }

  func load() -> [RankedBrokerProfile] {
    profiles
  }

  func replaceAll(_ profiles: [RankedBrokerProfile]) throws {
    try validateProfiles(profiles)
    self.profiles = profiles
  }
}

private actor GatedProfileRepository: ProfileRepositoryProtocol {
  private var profiles: [RankedBrokerProfile]
  private let blockedWriteNumbers: Set<Int>
  private let failedWriteNumbers: Set<Int>
  private var writeCount = 0
  private var writes: [[RankedBrokerProfile]] = []
  private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
  private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(
    profiles: [RankedBrokerProfile] = [],
    blockedWriteNumbers: Set<Int>,
    failedWriteNumbers: Set<Int> = []
  ) {
    self.profiles = profiles
    self.blockedWriteNumbers = blockedWriteNumbers
    self.failedWriteNumbers = failedWriteNumbers
  }

  func load() -> [RankedBrokerProfile] {
    profiles
  }

  func replaceAll(_ profiles: [RankedBrokerProfile]) async throws {
    try validateProfiles(profiles)
    writeCount += 1
    let number = writeCount
    resumeCountWaiters()
    if blockedWriteNumbers.contains(number) {
      await withCheckedContinuation { continuation in
        releases[number] = continuation
      }
    }
    if failedWriteNumbers.contains(number) {
      throw ProfileSyncTestError.rejected
    }
    writes.append(profiles)
    self.profiles = profiles
  }

  func waitForWriteCount(_ expected: Int) async {
    guard writeCount < expected else { return }
    await withCheckedContinuation { continuation in
      countWaiters.append((expected, continuation))
    }
  }

  func releaseWrite(_ number: Int) {
    releases.removeValue(forKey: number)?.resume()
  }

  func committedWrites() -> [[RankedBrokerProfile]] {
    writes
  }

  private func resumeCountWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for waiter in countWaiters {
      if writeCount >= waiter.0 {
        waiter.1.resume()
      } else {
        remaining.append(waiter)
      }
    }
    countWaiters = remaining
  }
}

private enum ProfileSyncTestError: Error {
  case rejected
}

private actor ScriptedProfileSync: ProfileSyncing {
  private var snapshots: [ProfileSyncSnapshot] = []
  private var currentStatus: ProfileSyncStatus
  private var synchronizeCount = 0
  private var synchronizeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var completions:
    [Int:
      CheckedContinuation<
        ProfileSyncExchange,
        any Error
      >] = [:]

  init(stageStatus: ProfileSyncStatus = .available) {
    self.currentStatus = stageStatus
  }

  func status() -> ProfileSyncStatus {
    currentStatus
  }

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    if snapshot.generation
      >= (snapshots.last?.generation ?? 0)
    {
      snapshots.append(snapshot)
    }
    return currentStatus
  }

  func synchronize() async throws -> ProfileSyncExchange {
    synchronizeCount += 1
    let number = synchronizeCount
    resumeSynchronizeWaiters()
    currentStatus = .syncing
    let result = try await withCheckedThrowingContinuation {
      continuation in
      completions[number] = continuation
    }
    currentStatus = .available
    return result
  }

  func cancel() {
    let pending = completions
    completions.removeAll()
    for continuation in pending.values {
      continuation.resume(throwing: CancellationError())
    }
    currentStatus = .available
  }

  func waitForSynchronizeCount(_ expected: Int) async {
    guard synchronizeCount < expected else { return }
    await withCheckedContinuation { continuation in
      synchronizeWaiters.append((expected, continuation))
    }
  }

  func completeSynchronize(
    _ number: Int,
    with result: Result<ProfileSyncExchange, any Error>
  ) {
    completions.removeValue(forKey: number)?
      .resume(with: result)
    if case .failure(let error) = result,
      let failure = error as? ProfileSyncFailure
    {
      currentStatus =
        failure.isRetryable ? .retryScheduled(failure) : .failed(failure)
    } else {
      currentStatus = .available
    }
  }

  func stagedSnapshots() -> [ProfileSyncSnapshot] {
    snapshots
  }

  func latestStagedProfiles() -> [RankedBrokerProfile]? {
    snapshots.last?.profiles
  }

  private func resumeSynchronizeWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for waiter in synchronizeWaiters {
      if synchronizeCount >= waiter.0 {
        waiter.1.resume()
      } else {
        remaining.append(waiter)
      }
    }
    synchronizeWaiters = remaining
  }
}

private func validateProfiles(
  _ profiles: [RankedBrokerProfile]
) throws {
  var seen: Set<BrokerProfile.ID> = []
  for profile in profiles {
    guard profile.profile.validationIssues.isEmpty else {
      throw LocalProfileRepositoryError.invalidProfile(profile.id)
    }
    guard seen.insert(profile.id).inserted else {
      throw LocalProfileRepositoryError.duplicateProfile(profile.id)
    }
  }
}

private func rankedProfile(
  id: UUID = UUID(),
  name: String,
  host: String = "broker.example",
  username: String? = "operator",
  filter: String = "site/#"
) -> RankedBrokerProfile {
  RankedBrokerProfile(
    profile: BrokerProfile(
      id: id,
      name: name,
      host: host,
      port: 8_883,
      transport: .tls,
      username: username,
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [
        SubscriptionDefinition(
          filter: filter,
          qos: .atLeastOnce
        )
      ]
    ),
    reorderRank: 1_024
  )
}
