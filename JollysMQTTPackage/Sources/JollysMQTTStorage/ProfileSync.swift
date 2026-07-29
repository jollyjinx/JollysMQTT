import Foundation
import JollysMQTTCore

public struct ProfileSyncFailure: Error, Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case unavailable
    case offline
    case rateLimited
    case invalidRemoteProfile
    case corruptRemotePayload
    case internalFailure
  }

  public let kind: Kind
  public let isRetryable: Bool
  public let retryAfterSeconds: TimeInterval?

  public init(
    kind: Kind,
    isRetryable: Bool,
    retryAfterSeconds: TimeInterval? = nil
  ) {
    self.kind = kind
    self.isRetryable = isRetryable
    self.retryAfterSeconds = retryAfterSeconds
  }
}

public enum ProfileSyncStatus: Equatable, Sendable {
  case localOnly
  case available
  case syncing
  case retryScheduled(ProfileSyncFailure)
  case failed(ProfileSyncFailure)
}

public struct ProfileSyncExchange: Equatable, Sendable {
  public let remoteProfiles: [RankedBrokerProfile]?
  public let remoteRecords: [ProfileReplicaRecord]?

  public init(remoteProfiles: [RankedBrokerProfile]?) {
    self.remoteProfiles = remoteProfiles
    self.remoteRecords = nil
  }

  public init(remoteRecords: [ProfileReplicaRecord]?) {
    self.remoteRecords = remoteRecords
    self.remoteProfiles = nil
  }

  public static let noChanges = ProfileSyncExchange(remoteProfiles: nil)
}

public struct ProfileSyncSnapshot: Equatable, Sendable {
  public let generation: UInt64
  public let profiles: [RankedBrokerProfile]
  public let replicaRecords: [ProfileReplicaRecord]?

  public init(
    generation: UInt64,
    profiles: [RankedBrokerProfile]
  ) {
    self.generation = generation
    self.profiles = profiles
    self.replicaRecords = nil
  }

  public init(
    generation: UInt64,
    replica: ProfileReplica
  ) {
    self.generation = generation
    self.profiles = replica.visibleProfiles
    self.replicaRecords = replica.records
  }
}

/// The CloudKit-facing boundary used by `CloudKitProfileSync`.
///
/// Staging is local bookkeeping only. Implementations must not wait for
/// network progress from `stageLocalProfiles`.
public protocol ProfileSyncEngine: Sendable {
  func stageLocalProfiles(_ snapshot: ProfileSyncSnapshot) async throws
  func synchronize() async throws -> ProfileSyncExchange
  func cancel() async
}

public protocol ProfileSyncing: Sendable {
  func status() async -> ProfileSyncStatus

  /// Records a local snapshot for a future sync without waiting on a network
  /// operation. The returned status is diagnostic and never changes whether
  /// the caller's local commit succeeded.
  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) async -> ProfileSyncStatus

  func synchronize() async throws -> ProfileSyncExchange
  func cancel() async
}

public protocol ProfileSynchronizingRepositoryProtocol:
  ProfileRepositoryProtocol
{
  func syncStatus() async -> ProfileSyncStatus
  func synchronize() async throws -> ProfileSyncStatus
  func cancelSynchronization() async
}

public actor LocalOnlyProfileSync: ProfileSyncing {
  public init() {}

  public func status() -> ProfileSyncStatus {
    .localOnly
  }

  public func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    .localOnly
  }

  public func synchronize() -> ProfileSyncExchange {
    .noChanges
  }

  public func cancel() {}
}

/// A local-first repository that keeps the atomic local document authoritative
/// for every interactive read and write. Cloud synchronization is explicitly
/// best-effort and cannot make valid local profile management fail.
public actor LocalFirstProfileRepository:
  ProfileSynchronizingRepositoryProtocol
{
  private let local: any ProfileRepositoryProtocol
  private let sync: any ProfileSyncing

  private var localMutationGeneration: UInt64 = 0
  private var latestRequestedMutationGeneration: UInt64 = 0
  private var snapshotGeneration: UInt64 = 0
  private var latestSyncAttempt: UInt64 = 0
  private var persistenceTail: Task<ProfileSyncStatus, any Error>?
  private var persistenceTailID: UInt64?
  private var nextPersistenceOperationID: UInt64 = 0
  private var currentStatus: ProfileSyncStatus

  public init(
    local: any ProfileRepositoryProtocol,
    sync: any ProfileSyncing = LocalOnlyProfileSync()
  ) {
    self.local = local
    self.sync = sync
    self.currentStatus = .localOnly
  }

  public func load() async throws -> [RankedBrokerProfile] {
    if let persistenceTail {
      _ = try? await persistenceTail.value
    }
    let snapshot = try await makeSnapshot(
      generation: snapshotGeneration
    )
    currentStatus = await sync.stageLocalProfiles(
      snapshot
    )
    return snapshot.profiles
  }

  public func replaceAll(
    _ profiles: [RankedBrokerProfile]
  ) async throws {
    latestRequestedMutationGeneration &+= 1
    let requestedGeneration = latestRequestedMutationGeneration
    snapshotGeneration &+= 1
    let requestedSnapshotGeneration = snapshotGeneration
    let predecessor = persistenceTail
    let local = local
    let sync = sync
    let operation = Task<ProfileSyncStatus, any Error> {
      if let predecessor {
        _ = try? await predecessor.value
      }
      try Task.checkCancellation()
      try await local.replaceAll(profiles)
      let snapshot: ProfileSyncSnapshot
      if let replicaLocal =
        local as? any ProfileReplicaRepositoryProtocol
      {
        snapshot = ProfileSyncSnapshot(
          generation: requestedSnapshotGeneration,
          replica: try await replicaLocal.loadReplica()
        )
      } else {
        snapshot = ProfileSyncSnapshot(
          generation: requestedSnapshotGeneration,
          profiles: profiles
        )
      }
      return await sync.stageLocalProfiles(snapshot)
    }
    nextPersistenceOperationID &+= 1
    let operationID = nextPersistenceOperationID
    persistenceTail = operation
    persistenceTailID = operationID

    let stagedStatus: ProfileSyncStatus
    do {
      stagedStatus = try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
    } catch {
      if persistenceTailID == operationID {
        latestRequestedMutationGeneration =
          localMutationGeneration
        persistenceTail = nil
        persistenceTailID = nil
      }
      throw error
    }

    localMutationGeneration = max(
      localMutationGeneration,
      requestedGeneration
    )
    if persistenceTailID == operationID {
      currentStatus = stagedStatus
      persistenceTail = nil
      persistenceTailID = nil
    }
  }

  public func syncStatus() async -> ProfileSyncStatus {
    let adapterStatus = await sync.status()
    switch currentStatus {
    case .retryScheduled, .failed:
      return currentStatus
    case .localOnly, .available, .syncing:
      return adapterStatus
    }
  }

  public func synchronize() async throws -> ProfileSyncStatus {
    try Task.checkCancellation()
    latestSyncAttempt &+= 1
    let syncAttempt = latestSyncAttempt
    if let persistenceTail {
      _ = try? await persistenceTail.value
    }

    let requestedGeneration = localMutationGeneration
    let localSnapshot = try await makeSnapshot(
      generation: snapshotGeneration
    )
    currentStatus = .syncing
    _ = await sync.stageLocalProfiles(localSnapshot)

    let exchange: ProfileSyncExchange
    do {
      exchange = try await sync.synchronize()
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as ProfileSyncFailure {
      guard syncAttempt == latestSyncAttempt else {
        return currentStatus
      }
      currentStatus =
        failure.isRetryable ? .retryScheduled(failure) : .failed(failure)
      return currentStatus
    } catch {
      guard syncAttempt == latestSyncAttempt else {
        return currentStatus
      }
      let failure = ProfileSyncFailure(
        kind: .internalFailure,
        isRetryable: true
      )
      currentStatus = .retryScheduled(failure)
      return currentStatus
    }

    if let remoteRecords = exchange.remoteRecords,
      let replicaLocal =
        local as? any ProfileReplicaRepositoryProtocol
    {
      snapshotGeneration &+= 1
      let remoteSnapshotGeneration = snapshotGeneration
      do {
        currentStatus = try await applyRemoteRecords(
          remoteRecords,
          to: replicaLocal,
          snapshotGeneration: remoteSnapshotGeneration,
          syncAttempt: syncAttempt
        )
      } catch is ProfileReplicaError {
        currentStatus = .failed(
          ProfileSyncFailure(
            kind: .invalidRemoteProfile,
            isRetryable: false
          )
        )
      } catch let failure as ProfileSyncFailure {
        currentStatus = .failed(failure)
      }
      try Task.checkCancellation()
      return currentStatus
    }

    try Task.checkCancellation()
    guard syncAttempt == latestSyncAttempt,
      requestedGeneration == localMutationGeneration
    else {
      let newest = try await makeSnapshot(
        generation: snapshotGeneration
      )
      guard syncAttempt == latestSyncAttempt else {
        return currentStatus
      }
      currentStatus = await sync.stageLocalProfiles(
        newest
      )
      return currentStatus
    }

    guard let remoteProfiles = exchange.remoteProfiles,
      !remoteProfiles.isEmpty
    else {
      currentStatus = await sync.status()
      return currentStatus
    }

    do {
      currentStatus = try await applyRemoteProfiles(
        remoteProfiles,
        expectedLocalGeneration: requestedGeneration,
        syncAttempt: syncAttempt
      )
      return currentStatus
    } catch let error as LocalProfileRepositoryError {
      switch error {
      case .invalidProfile, .duplicateProfile, .corruptDocument:
        currentStatus = .failed(
          ProfileSyncFailure(
            kind: .invalidRemoteProfile,
            isRetryable: false
          )
        )
        return currentStatus
      case .unsupportedVersion:
        throw error
      }
    }
  }

  public func cancelSynchronization() async {
    await sync.cancel()
  }

  private func makeSnapshot(
    generation: UInt64
  ) async throws -> ProfileSyncSnapshot {
    if let replicaLocal =
      local as? any ProfileReplicaRepositoryProtocol
    {
      return ProfileSyncSnapshot(
        generation: generation,
        replica: try await replicaLocal.loadReplica()
      )
    }
    return ProfileSyncSnapshot(
      generation: generation,
      profiles: try await local.load()
    )
  }

  private func applyRemoteRecords(
    _ records: [ProfileReplicaRecord],
    to replicaLocal: any ProfileReplicaRepositoryProtocol,
    snapshotGeneration remoteSnapshotGeneration: UInt64,
    syncAttempt: UInt64
  ) async throws -> ProfileSyncStatus {
    let remote: ProfileReplica
    do {
      remote = try ProfileReplica(records: records)
    } catch {
      let failure = ProfileSyncFailure(
        kind: .invalidRemoteProfile,
        isRetryable: false
      )
      throw failure
    }

    let predecessor = persistenceTail
    let sync = sync
    let operation = Task<ProfileSyncStatus, any Error> {
      if let predecessor {
        _ = try? await predecessor.value
      }
      let localReplica = try await replicaLocal.loadReplica()
      let merged = try localReplica.merging(remote)
      if merged != localReplica {
        try await replicaLocal.replaceReplica(merged)
      }
      _ = await sync.stageLocalProfiles(
        ProfileSyncSnapshot(
          generation: remoteSnapshotGeneration,
          replica: merged
        )
      )
      return await sync.status()
    }
    nextPersistenceOperationID &+= 1
    let operationID = nextPersistenceOperationID
    persistenceTail = operation
    persistenceTailID = operationID

    let status = try await operation.value
    if persistenceTailID == operationID {
      persistenceTail = nil
      persistenceTailID = nil
    }
    guard syncAttempt == latestSyncAttempt else {
      return currentStatus
    }
    return status
  }

  private func applyRemoteProfiles(
    _ profiles: [RankedBrokerProfile],
    expectedLocalGeneration: UInt64,
    syncAttempt: UInt64
  ) async throws -> ProfileSyncStatus {
    let predecessor = persistenceTail
    let local = local
    let sync = sync
    let operation = Task<ProfileSyncStatus, any Error> { [self] in
      if let predecessor {
        _ = try? await predecessor.value
      }
      try Task.checkCancellation()
      guard
        shouldApplyRemote(
          expectedLocalGeneration: expectedLocalGeneration,
          syncAttempt: syncAttempt
        )
      else {
        return await sync.status()
      }
      try await local.replaceAll(profiles)
      return await sync.status()
    }
    nextPersistenceOperationID &+= 1
    let operationID = nextPersistenceOperationID
    persistenceTail = operation
    persistenceTailID = operationID

    let status: ProfileSyncStatus
    do {
      status = try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
    } catch {
      if persistenceTailID == operationID {
        persistenceTail = nil
        persistenceTailID = nil
      }
      throw error
    }

    if persistenceTailID == operationID {
      persistenceTail = nil
      persistenceTailID = nil
    }
    guard syncAttempt == latestSyncAttempt else {
      return currentStatus
    }
    return status
  }

  private func shouldApplyRemote(
    expectedLocalGeneration: UInt64,
    syncAttempt: UInt64
  ) -> Bool {
    syncAttempt == latestSyncAttempt
      && expectedLocalGeneration == localMutationGeneration
      && expectedLocalGeneration
        == latestRequestedMutationGeneration
  }
}
