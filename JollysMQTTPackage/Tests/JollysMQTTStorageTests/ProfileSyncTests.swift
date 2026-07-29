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

  @Test("Recovery supersedes an older retry diagnostic")
  func recoverySupersedesRetryStatus() async throws {
    let retry = ProfileSyncFailure(
      kind: .offline,
      isRetryable: true
    )
    let sync = ScriptedProfileSync(
      stageStatus: .retryScheduled(retry)
    )
    let repository = LocalFirstProfileRepository(
      local: MemoryProfileRepository(),
      sync: sync
    )
    try await repository.replaceAll([
      rankedProfile(name: "Local")
    ])
    let recovery = ProfileSyncRecovery(
      reason: .accountChanged
    )

    await sync.setStatus(.recoveryRequired(recovery))

    #expect(
      await repository.syncStatus()
        == .recoveryRequired(recovery)
    )
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
    let atomic = LocalProfileRepository(
      fileURL: fileURL,
      installationID: profileSyncTestInstallationID
    )
    try await atomic.replaceAll([original])
    try await atomic.replaceAll([newer])
    try Data("{corrupt".utf8).write(to: fileURL)

    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: LocalProfileRepository(
        fileURL: fileURL,
        installationID: profileSyncTestInstallationID
      ),
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

  @Test("Account recovery re-stages durable local data only after user consent")
  func accountRecoveryRestagesLocalAfterConsent() async throws {
    let profile = rankedProfile(name: "Preserved local")
    let recovery = ProfileSyncRecovery(
      reason: .accountChanged
    )
    let local = MemoryProfileRepository(profiles: [profile])
    let sync = ScriptedProfileSync(
      stageStatus: .recoveryRequired(recovery)
    )
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )

    #expect(
      await repository.syncStatus()
        == .recoveryRequired(recovery)
    )
    #expect(await sync.stagedSnapshots().isEmpty)

    let status = try await repository.resolveSyncRecovery(
      .resumeCloudSyncUsingLocalProfiles
    )

    #expect(status == .available)
    #expect(try await repository.load() == [profile])
    #expect(await sync.stagedSnapshots().last?.profiles == [profile])
  }

  @Test("A stale workspace cannot reverse another workspace recovery choice")
  func staleRecoveryChoiceIsIgnored() async throws {
    let recovery = ProfileSyncRecovery(
      reason: .accountChanged
    )
    let sync = ScriptedProfileSync(
      stageStatus: .recoveryRequired(recovery)
    )
    let repository = LocalFirstProfileRepository(
      local: MemoryProfileRepository(
        profiles: [rankedProfile(name: "Local")]
      ),
      sync: sync
    )

    #expect(
      try await repository.resolveSyncRecovery(
        .resumeCloudSyncUsingLocalProfiles,
        expectedRecovery: recovery
      ) == .available
    )
    #expect(
      try await repository.resolveSyncRecovery(
        .keepLocalOnly,
        expectedRecovery: recovery
      ) == .available
    )
    #expect(
      await sync.recoveryDecisions()
        == [.resumeCloudSyncUsingLocalProfiles]
    )
  }

  @Test("Concurrent workspaces cannot both apply opposing recovery choices")
  func concurrentRecoveryChoicesAreSerialized() async throws {
    let recovery = ProfileSyncRecovery(
      reason: .accountChanged
    )
    let sync = SuspendedStatusProfileSync(recovery: recovery)
    let repository = LocalFirstProfileRepository(
      local: MemoryProfileRepository(
        profiles: [rankedProfile(name: "Local")]
      ),
      sync: sync
    )
    await sync.suspendNextStatus()

    let first = Task {
      try await repository.resolveSyncRecovery(
        .resumeCloudSyncUsingLocalProfiles,
        expectedRecovery: recovery
      )
    }
    await sync.waitUntilStatusIsSuspended()

    let stale = Task {
      try await repository.resolveSyncRecovery(
        .keepLocalOnly,
        expectedRecovery: recovery
      )
    }
    await Task.yield()

    await sync.resumeStatus()
    #expect(try await first.value == .available)
    #expect(try await stale.value == .available)
    #expect(
      await sync.recoveryDecisions()
        == [.resumeCloudSyncUsingLocalProfiles]
    )
  }

  @Test("A local edit racing a drained record exchange preserves both edits")
  func localEditRacingRecordExchangeConverges() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installationA = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000A"
    )!
    let installationB = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000B"
    )!
    let first = rankedProfile(name: "First")
    let second = rankedProfile(name: "Second")
    let local = LocalProfileRepository(
      fileURL: fileURL,
      installationID: installationA
    )
    try await local.replaceAll([first, second])
    let baseline = try await local.loadReplica()
    let remote = try baseline.applyingLocalSnapshot(
      [renamed(first, "Remote first"), second],
      installationID: installationB
    )
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )

    let syncTask = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    try await repository.replaceAll([
      first,
      renamed(second, "Local second"),
    ])
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteRecords: remote.records)
      )
    )
    _ = try await syncTask.value

    let visible = try await repository.load()
    #expect(
      Set(visible.map(\.profile.name))
        == ["Remote first", "Local second"]
    )
    let staged = await sync.stagedSnapshots()
    #expect(staged.last?.replicaRecords != nil)
    #expect(
      Set(staged.last?.profiles.map(\.profile.name) ?? [])
        == ["Remote first", "Local second"]
    )
  }

  @Test("An older record exchange completing last is still merged")
  func olderRecordExchangeIsNotDiscarded() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installationA = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000A"
    )!
    let installationB = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000B"
    )!
    let first = rankedProfile(name: "First")
    let second = rankedProfile(name: "Second")
    let local = LocalProfileRepository(
      fileURL: fileURL,
      installationID: installationA
    )
    try await local.replaceAll([first, second])
    let baseline = try await local.loadReplica()
    let olderRemote = try baseline.applyingLocalSnapshot(
      [renamed(first, "Older completion"), second],
      installationID: installationA
    )
    let newerRemote = try baseline.applyingLocalSnapshot(
      [first, renamed(second, "Newer completion")],
      installationID: installationB
    )
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )

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
        ProfileSyncExchange(remoteRecords: newerRemote.records)
      )
    )
    _ = try await newerTask.value
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteRecords: olderRemote.records)
      )
    )
    _ = try await olderTask.value

    #expect(
      Set(try await repository.load().map(\.profile.name))
        == ["Older completion", "Newer completion"]
    )
  }

  @Test("Local and record-merge persistence tails remain one FIFO chain")
  func recordMergeDoesNotDetachPersistenceTail() async throws {
    let installationA = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000A"
    )!
    let installationB = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000B"
    )!
    let first = rankedProfile(name: "First")
    let second = rankedProfile(name: "Second")
    let initial = try ProfileReplica().applyingLocalSnapshot(
      [first, second],
      installationID: installationA
    )
    let remote = try initial.applyingLocalSnapshot(
      [renamed(first, "Remote middle"), second],
      installationID: installationB
    )
    let local = GatedReplicaRepository(
      replica: initial,
      installationID: installationA,
      blockedWriteNumbers: [1, 2]
    )
    let sync = ScriptedProfileSync()
    let repository = LocalFirstProfileRepository(
      local: local,
      sync: sync
    )

    let syncTask = Task {
      try await repository.synchronize()
    }
    await sync.waitForSynchronizeCount(1)
    let predecessor = Task {
      try await repository.replaceAll([
        first,
        renamed(second, "Local predecessor"),
      ])
    }
    await local.waitForWriteCount(1)
    await sync.completeSynchronize(
      1,
      with: .success(
        ProfileSyncExchange(remoteRecords: remote.records)
      )
    )
    await local.releaseWrite(1)
    try await predecessor.value
    await local.waitForWriteCount(2)

    let successor = Task {
      try await repository.replaceAll([
        renamed(first, "Remote middle"),
        renamed(second, "Local successor"),
      ])
    }
    await local.releaseWrite(2)
    _ = try await syncTask.value
    try await successor.value

    let writes = await local.committedReplicas()
    #expect(writes.count == 3)
    #expect(
      Set(writes[1].visibleProfiles.map(\.profile.name))
        == ["Remote middle", "Local predecessor"]
    )
    #expect(
      Set(writes[2].visibleProfiles.map(\.profile.name))
        == ["Remote middle", "Local successor"]
    )
  }

  @Test("Cancellation after a record exchange cannot discard the drained delta")
  func cancellationAfterRecordExchangeStillCommits() async throws {
    let installationA = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000A"
    )!
    let installationB = UUID(
      uuidString: "00000000-0000-0000-0000-00000000000B"
    )!
    let profile = rankedProfile(name: "Initial")
    let initial = try ProfileReplica().applyingLocalSnapshot(
      [profile],
      installationID: installationA
    )
    let remote = try initial.applyingLocalSnapshot(
      [renamed(profile, "Fetched before cancellation")],
      installationID: installationB
    )
    let local = GatedReplicaRepository(
      replica: initial,
      installationID: installationA,
      blockedWriteNumbers: [1]
    )
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
        ProfileSyncExchange(remoteRecords: remote.records)
      )
    )
    await local.waitForWriteCount(1)
    task.cancel()
    await local.releaseWrite(1)

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(
      await local.load().map(\.profile.name)
        == ["Fetched before cancellation"]
    )
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

    @Test("Adapter retains edits in memory until recovery consent")
    func adapterSuppressesStagingUntilRecoveryConsent() async throws {
      let engine = ScriptedProfileSyncEngine()
      let adapter = CloudKitProfileSync(engine: engine)
      let initial = ProfileSyncSnapshot(
        generation: 1,
        profiles: [rankedProfile(name: "Initial")]
      )
      _ = await adapter.stageLocalProfiles(initial)
      let operation = Task {
        try await adapter.synchronize()
      }
      await engine.waitForSynchronizeCount(1)
      let recovery = ProfileSyncRecovery(
        reason: .accountChanged
      )
      await engine.completeSynchronize(
        1,
        with: .failure(recovery)
      )
      await #expect(throws: recovery) {
        try await operation.value
      }

      let edited = ProfileSyncSnapshot(
        generation: 2,
        profiles: [rankedProfile(name: "Edited locally")]
      )
      #expect(
        await adapter.stageLocalProfiles(edited)
          == .recoveryRequired(recovery)
      )
      #expect(await engine.stagedSnapshots() == [initial])

      #expect(
        await adapter.resolveRecovery(
          .resumeCloudSyncUsingLocalProfiles,
          localSnapshot: edited
        ) == .available
      )
      #expect(await engine.stagedSnapshots() == [initial, edited])
    }

    @Test("Asynchronous engine recovery is visible without a manual sync")
    func asynchronousRecoveryIsVisibleFromStatus() async {
      let engine = ScriptedProfileSyncEngine()
      let adapter = CloudKitProfileSync(engine: engine)
      let recovery = ProfileSyncRecovery(
        reason: .zoneDeleted
      )

      await engine.setPendingRecovery(recovery)

      #expect(
        await adapter.status() == .recoveryRequired(recovery)
      )
    }
  }

  @Suite("Encrypted CloudKit profile record codec")
  struct CloudKitProfileRecordCodecTests {
    @Test("CloudKit account and zone reset events retain distinct recovery reasons")
    func cloudKitResetReasonsRemainDistinct() {
      let user = CKRecord.ID(recordName: "user")

      #expect(
        CKSyncEngineProfileDelegate.recoveryReason(
          for: .signOut(previousUser: user)
        ) == .signedOut
      )
      #expect(
        CKSyncEngineProfileDelegate.recoveryReason(
          for: .signIn(currentUser: user)
        ) == .accountChanged
      )
      #expect(
        CKSyncEngineProfileDelegate.recoveryReason(
          for: .switchAccounts(
            previousUser: user,
            currentUser: user
          )
        ) == .accountChanged
      )
      #expect(
        CKSyncEngineProfileDelegate.recoveryReason(
          for: .deleted
        ) == .zoneDeleted
      )
      #expect(
        CKSyncEngineProfileDelegate.recoveryReason(
          for: .purged
        ) == .zonePurged
      )
      #expect(
        CKSyncEngineProfileDelegate.recoveryReason(
          for: .encryptedDataReset
        ) == .encryptedDataReset
      )
    }

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

    @Test("A v2 tombstone round-trips as an encrypted durable record")
    func tombstoneRoundTrips() throws {
      let id = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
      )!
      let revision = ProfileLogicalRevision(
        counter: 42,
        installationID: UUID(
          uuidString: "11111111-2222-3333-4444-555555555555"
        )!
      )
      let tombstone = ProfileReplicaRecord(
        id: id,
        content: nil,
        rank: nil,
        tombstone: revision
      )
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )

      let record = try codec.encodeReplicaRecord(tombstone)

      #expect(record.recordID.recordName == id.uuidString.lowercased())
      #expect(try codec.decodeReplicaRecord(record) == tombstone)
      #expect(record[CloudKitProfileRecordCodec.encryptedPayloadKey] == nil)
    }

    @Test("A v1 encrypted envelope gets the receiver-independent legacy revision")
    func v1EnvelopeMigratesDeterministically() throws {
      struct LegacyEnvelope: Encodable {
        let version: Int
        let rankedProfile: RankedBrokerProfile
      }

      let profile = rankedProfile(name: "Legacy cloud")
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )
      let record = CKRecord(
        recordType: codec.recordType,
        recordID: CKRecord.ID(
          recordName: profile.id.uuidString.lowercased(),
          zoneID: codec.zoneID
        )
      )
      record.encryptedValues[
        CloudKitProfileRecordCodec.encryptedPayloadKey
      ] = try JSONEncoder().encode(
        LegacyEnvelope(version: 1, rankedProfile: profile)
      )

      let migrated = try codec.decodeReplicaRecord(record)

      #expect(migrated.content?.revision == .legacy)
      #expect(migrated.rank?.revision == .legacy)
      #expect(migrated.visibleProfile == profile)
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

    @Test("Fetched remote content is merged and re-staged before its server-tagged retry")
    func fetchedContentIsMergedBeforeRetry() async throws {
      let installationA = UUID(
        uuidString: "00000000-0000-0000-0000-00000000000A"
      )!
      let installationB = UUID(
        uuidString: "00000000-0000-0000-0000-00000000000B"
      )!
      let localProfile = rankedProfile(name: "Stale local")
      let localReplica = try replica(
        profiles: [localProfile],
        revision: ProfileLogicalRevision(
          counter: 1,
          installationID: installationA
        )
      )
      let remoteProfile = rankedProfile(
        id: localProfile.id,
        name: "Newer server"
      )
      let remoteReplica = try replica(
        profiles: [remoteProfile],
        revision: ProfileLogicalRevision(
          counter: 2,
          installationID: installationB
        )
      )
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )
      let serverRecord = try codec.encodeReplicaRecord(
        remoteReplica.records[0]
      )
      let delegate = CKSyncEngineProfileDelegate(
        codec: codec,
        stateStore: MemoryProfileSyncStateStore()
      )
      await delegate.stage(
        ProfileSyncSnapshot(generation: 1, replica: localReplica)
      )
      await delegate.acceptFetchedRecord(serverRecord)

      let fetched = try #require(
        await delegate.takeFetchedExchangeBeforeSend()
      )
      let fetchedReplica = try ProfileReplica(
        records: try #require(fetched.remoteRecords)
      )
      let merged = try localReplica.merging(fetchedReplica)
      await delegate.stage(
        ProfileSyncSnapshot(generation: 2, replica: merged)
      )
      let outbound = try #require(
        await delegate.record(for: serverRecord.recordID)
      )

      #expect(outbound === serverRecord)
      #expect(
        try codec.decodeReplicaRecord(outbound)
          == merged.records[0]
      )
      #expect(
        try await delegate.takeFetchedExchangeBeforeSend()
          == nil
      )
    }

    @Test("Unresolved recovery clears transport state and suppresses staging")
    func recoverySuppressesTransportState() async throws {
      let profile = rankedProfile(name: "Local recovery")
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )
      let delegate = CKSyncEngineProfileDelegate(
        codec: codec,
        stateStore: MemoryProfileSyncStateStore()
      )
      let initial = ProfileSyncSnapshot(
        generation: 1,
        profiles: [profile]
      )
      #expect(await delegate.stage(initial))
      let fetched = try codec.encode(profile)
      await delegate.acceptFetchedRecord(fetched)

      let recovery = ProfileSyncRecovery(
        reason: .encryptedDataReset
      )
      await delegate.beginRecovery(recovery)
      let pending = ProfileSyncSnapshot(
        generation: 2,
        profiles: [profile]
      )

      #expect(await delegate.stage(pending) == false)
      #expect(
        await delegate.pendingRecovery() == recovery
      )
      await #expect(throws: recovery) {
        try await delegate.takeFetchedExchangeBeforeSend()
      }
      #expect(
        try await delegate.record(
          for: fetched.recordID
        ) == nil
      )

      await delegate.resumeAfterRecovery(using: pending)

      #expect(await delegate.pendingRecovery() == nil)
      #expect(
        try await delegate.record(
          for: fetched.recordID
        ) != nil
      )
    }

    @Test("Every server-record conflict in one batch becomes a domain merge input")
    func multipleServerConflictsAreCollected() async throws {
      let first = rankedProfile(name: "First")
      let second = rankedProfile(name: "Second")
      let revision = ProfileLogicalRevision(
        counter: 8,
        installationID: UUID(
          uuidString: "00000000-0000-0000-0000-00000000000B"
        )!
      )
      let remoteReplica = try replica(
        profiles: [first, second],
        revision: revision
      )
      let codec = CloudKitProfileRecordCodec(
        zoneName: "EncryptedProfiles",
        recordType: "EncryptedBrokerProfile"
      )
      let serverRecords = try remoteReplica.records.map {
        try codec.encodeReplicaRecord($0)
      }
      let attemptedRecords = try remoteReplica.records.map {
        try codec.encodeReplicaRecord($0)
      }
      var failures = zip(attemptedRecords, serverRecords).map {
        attempted, server in
        CloudKitFailedProfileSave(
          record: attempted,
          error: CKError(
            _nsError: NSError(
              domain: CKError.errorDomain,
              code: CKError.Code.serverRecordChanged.rawValue,
              userInfo: [
                CKRecordChangedErrorServerRecordKey: server
              ]
            )
          )
        )
      }
      let rejected = rankedProfile(
        id: UUID(
          uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        )!,
        name: "Rate limited"
      )
      failures.append(
        CloudKitFailedProfileSave(
          record: try codec.encode(rejected),
          error: CKError(
            _nsError: NSError(
              domain: CKError.errorDomain,
              code: CKError.Code.requestRateLimited.rawValue
            )
          )
        )
      )
      let delegate = CKSyncEngineProfileDelegate(
        codec: codec,
        stateStore: MemoryProfileSyncStateStore()
      )

      await delegate.acceptFailedRecordSaves(
        Array(failures.reversed())
      )
      await #expect(
        throws: ProfileSyncFailure(
          kind: .rateLimited,
          isRetryable: true
        )
      ) {
        try await delegate.takeFetchedExchangeBeforeSend()
      }
      await delegate.beginOperation()
      let exchange = try #require(
        await delegate.takeFetchedExchangeBeforeSend()
      )

      #expect(exchange.remoteRecords == remoteReplica.records)
    }

    @Test("CloudKit transport metadata never enters replica JSON")
    func transportMetadataDoesNotEnterDomainJSON() throws {
      let profile = rankedProfile(name: "Domain only")
      let replica = try replica(
        profiles: [profile],
        revision: ProfileLogicalRevision(
          counter: 3,
          installationID: UUID(
            uuidString: "00000000-0000-0000-0000-00000000000A"
          )!
        )
      )
      let text = try #require(
        String(
          data: JSONEncoder().encode(replica),
          encoding: .utf8
        )
      )

      for transportMetadata in [
        "recordChangeTag",
        "modificationDate",
        "creationDate",
        "etag",
        "CKRecord",
      ] {
        #expect(!text.contains(transportMetadata))
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
  private var recovery: ProfileSyncRecovery?
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

  func pendingRecovery() -> ProfileSyncRecovery? {
    recovery
  }

  func setPendingRecovery(
    _ recovery: ProfileSyncRecovery?
  ) {
    self.recovery = recovery
  }

  func resumeAfterRecovery(
    using snapshot: ProfileSyncSnapshot
  ) {
    snapshots.append(snapshot)
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

#if canImport(CloudKit)
  private actor MemoryProfileSyncStateStore:
    ProfileSyncStateStoring
  {
    private var candidates = ProfileSyncStateCandidates(
      primary: nil,
      backup: nil
    )

    func loadCandidates() -> ProfileSyncStateCandidates {
      candidates
    }

    func save(_ data: Data) {
      candidates = ProfileSyncStateCandidates(
        primary: data,
        backup: candidates.primary
      )
    }

    func restoreBackup() {
      candidates = ProfileSyncStateCandidates(
        primary: candidates.backup,
        backup: candidates.backup
      )
    }

    func clear() {
      candidates = ProfileSyncStateCandidates(
        primary: nil,
        backup: nil
      )
    }
  }

  private func replica(
    profiles: [RankedBrokerProfile],
    revision: ProfileLogicalRevision
  ) throws -> ProfileReplica {
    try ProfileReplica(
      records: profiles.map {
        ProfileReplicaRecord(
          id: $0.id,
          content: ProfileContentRegister(
            value: $0.profile,
            revision: revision
          ),
          rank: ProfileRankRegister(
            value: $0.reorderRank,
            revision: revision
          ),
          tombstone: nil
        )
      }
    )
  }
#endif

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

private actor GatedReplicaRepository:
  ProfileReplicaRepositoryProtocol
{
  private var replica: ProfileReplica
  private let installationID: UUID
  private let blockedWriteNumbers: Set<Int>
  private var writeCount = 0
  private var writes: [ProfileReplica] = []
  private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
  private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(
    replica: ProfileReplica,
    installationID: UUID,
    blockedWriteNumbers: Set<Int>
  ) {
    self.replica = replica
    self.installationID = installationID
    self.blockedWriteNumbers = blockedWriteNumbers
  }

  func load() -> [RankedBrokerProfile] {
    replica.visibleProfiles
  }

  func loadReplica() -> ProfileReplica {
    replica
  }

  func replaceAll(_ profiles: [RankedBrokerProfile]) async throws {
    let updated = try replica.applyingLocalSnapshot(
      profiles,
      installationID: installationID
    )
    await commit(updated)
  }

  func replaceReplica(_ replica: ProfileReplica) async {
    await commit(replica)
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

  func committedReplicas() -> [ProfileReplica] {
    writes
  }

  private func commit(_ replica: ProfileReplica) async {
    writeCount += 1
    let number = writeCount
    resumeCountWaiters()
    if blockedWriteNumbers.contains(number) {
      await withCheckedContinuation { continuation in
        releases[number] = continuation
      }
    }
    writes.append(replica)
    self.replica = replica
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

private actor SuspendedStatusProfileSync: ProfileSyncing {
  private var currentStatus: ProfileSyncStatus
  private var shouldSuspendStatus = false
  private var statusIsSuspended = false
  private var statusRelease: CheckedContinuation<Void, Never>?
  private var statusWaiters: [CheckedContinuation<Void, Never>] = []
  private var decisions: [ProfileSyncRecoveryDecision] = []

  init(recovery: ProfileSyncRecovery) {
    currentStatus = .recoveryRequired(recovery)
  }

  func suspendNextStatus() {
    shouldSuspendStatus = true
  }

  func status() async -> ProfileSyncStatus {
    if shouldSuspendStatus {
      shouldSuspendStatus = false
      statusIsSuspended = true
      for waiter in statusWaiters {
        waiter.resume()
      }
      statusWaiters.removeAll()
      await withCheckedContinuation { continuation in
        statusRelease = continuation
      }
      statusIsSuspended = false
    }
    return currentStatus
  }

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    currentStatus
  }

  func synchronize() -> ProfileSyncExchange {
    .noChanges
  }

  func resolveRecovery(
    _ decision: ProfileSyncRecoveryDecision,
    localSnapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    decisions.append(decision)
    currentStatus =
      decision == .keepLocalOnly ? .localOnly : .available
    return currentStatus
  }

  func cancel() {}

  func waitUntilStatusIsSuspended() async {
    guard !statusIsSuspended else { return }
    await withCheckedContinuation { continuation in
      statusWaiters.append(continuation)
    }
  }

  func resumeStatus() {
    statusRelease?.resume()
    statusRelease = nil
  }

  func recoveryDecisions() -> [ProfileSyncRecoveryDecision] {
    decisions
  }
}

private actor ScriptedProfileSync: ProfileSyncing {
  private var snapshots: [ProfileSyncSnapshot] = []
  private var currentStatus: ProfileSyncStatus
  private var synchronizeCount = 0
  private var resolvedRecoveryDecisions: [ProfileSyncRecoveryDecision] = []
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

  func resolveRecovery(
    _ decision: ProfileSyncRecoveryDecision,
    localSnapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    resolvedRecoveryDecisions.append(decision)
    switch decision {
    case .keepLocalOnly:
      currentStatus = .localOnly
    case .resumeCloudSyncUsingLocalProfiles:
      snapshots.append(localSnapshot)
      currentStatus = .available
    }
    return currentStatus
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

  func setStatus(_ status: ProfileSyncStatus) {
    currentStatus = status
  }

  func recoveryDecisions() -> [ProfileSyncRecoveryDecision] {
    resolvedRecoveryDecisions
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

private func renamed(
  _ profile: RankedBrokerProfile,
  _ name: String
) -> RankedBrokerProfile {
  RankedBrokerProfile(
    profile: BrokerProfile(
      id: profile.id,
      name: name,
      host: profile.profile.host,
      port: profile.profile.port,
      transport: profile.profile.transport,
      username: profile.profile.username,
      clientIDPolicy: profile.profile.clientIDPolicy,
      cleanSession: profile.profile.cleanSession,
      keepAliveSeconds: profile.profile.keepAliveSeconds,
      reconnectPolicy: profile.profile.reconnectPolicy,
      subscriptions: profile.profile.subscriptions
    ),
    reorderRank: profile.reorderRank
  )
}

private let profileSyncTestInstallationID = UUID(
  uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
)
