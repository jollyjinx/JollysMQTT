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
  /// `nil` means that the engine fetched no profile changes. An empty array is
  /// reserved for a later, explicit delete/tombstone merge.
  public let remoteProfiles: [RankedBrokerProfile]?

  public init(remoteProfiles: [RankedBrokerProfile]?) {
    self.remoteProfiles = remoteProfiles
  }

  public static let noChanges = ProfileSyncExchange(remoteProfiles: nil)
}

public struct ProfileSyncSnapshot: Equatable, Sendable {
  public let generation: UInt64
  public let profiles: [RankedBrokerProfile]

  public init(
    generation: UInt64,
    profiles: [RankedBrokerProfile]
  ) {
    self.generation = generation
    self.profiles = profiles
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
  private var latestSyncAttempt: UInt64 = 0
  private var persistenceTail: Task<ProfileSyncStatus, any Error>?
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
    let profiles = try await local.load()
    currentStatus = await sync.stageLocalProfiles(
      ProfileSyncSnapshot(
        generation: localMutationGeneration,
        profiles: profiles
      )
    )
    return profiles
  }

  public func replaceAll(
    _ profiles: [RankedBrokerProfile]
  ) async throws {
    latestRequestedMutationGeneration &+= 1
    let requestedGeneration = latestRequestedMutationGeneration
    let predecessor = persistenceTail
    let local = local
    let sync = sync
    let snapshot = ProfileSyncSnapshot(
      generation: requestedGeneration,
      profiles: profiles
    )
    let operation = Task<ProfileSyncStatus, any Error> {
      if let predecessor {
        _ = try? await predecessor.value
      }
      try Task.checkCancellation()
      try await local.replaceAll(profiles)
      return await sync.stageLocalProfiles(snapshot)
    }
    persistenceTail = operation

    let stagedStatus: ProfileSyncStatus
    do {
      stagedStatus = try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
    } catch {
      if requestedGeneration == latestRequestedMutationGeneration {
        latestRequestedMutationGeneration =
          localMutationGeneration
        persistenceTail = nil
      }
      throw error
    }

    localMutationGeneration = max(
      localMutationGeneration,
      requestedGeneration
    )
    if requestedGeneration == latestRequestedMutationGeneration {
      currentStatus = stagedStatus
      persistenceTail = nil
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

    let localProfiles = try await local.load()
    let requestedGeneration = localMutationGeneration
    currentStatus = .syncing
    _ = await sync.stageLocalProfiles(
      ProfileSyncSnapshot(
        generation: requestedGeneration,
        profiles: localProfiles
      )
    )

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

    try Task.checkCancellation()
    guard syncAttempt == latestSyncAttempt,
      requestedGeneration == localMutationGeneration
    else {
      let newest = try await local.load()
      guard syncAttempt == latestSyncAttempt else {
        return currentStatus
      }
      currentStatus = await sync.stageLocalProfiles(
        ProfileSyncSnapshot(
          generation: localMutationGeneration,
          profiles: newest
        )
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
    persistenceTail = operation

    let status: ProfileSyncStatus
    do {
      status = try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
    } catch {
      if expectedLocalGeneration
        == latestRequestedMutationGeneration
      {
        persistenceTail = nil
      }
      throw error
    }

    if expectedLocalGeneration
      == latestRequestedMutationGeneration
    {
      persistenceTail = nil
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
