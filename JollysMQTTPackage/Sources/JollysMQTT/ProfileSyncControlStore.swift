import JollysMQTTStorage
import Observation

@MainActor
@Observable
public final class ProfileSyncControlStore {
  public private(set) var status: ProfileSyncStatus = .localOnly
  public private(set) var isWorking = false

  private let repository: (any ProfileSynchronizingRepositoryProtocol)?
  private var hasStarted = false

  public init(
    repository: (any ProfileSynchronizingRepositoryProtocol)?
  ) {
    self.repository = repository
  }

  public func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    guard let repository else {
      status = .localOnly
      return
    }
    status = await repository.syncStatus()
    if status == .available {
      await retry()
    }
  }

  public func run() async {
    await start()
    guard repository != nil,
      status != .localOnly,
      status != .cloudSyncDisabled,
      status != .cloudSyncPreferenceSaveFailed
    else {
      return
    }
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      await refreshStatus()
      if status == .localOnly
        || status == .cloudSyncDisabled
        || status == .cloudSyncPreferenceSaveFailed
      {
        return
      }
    }
  }

  public func refreshStatus() async {
    guard let repository, !isWorking else { return }
    status = await repository.syncStatus()
  }

  public func retry() async {
    guard let repository else { return }
    isWorking = true
    status = .syncing
    do {
      status = try await repository.synchronize()
    } catch {
      status = await repository.syncStatus()
    }
    isWorking = false
  }

  public func keepLocalOnly() async {
    await resolve(.keepLocalOnly)
  }

  public func resumeUsingLocalProfiles() async {
    await resolve(.resumeCloudSyncUsingLocalProfiles)
  }

  public func enableCloudSync() async {
    await resolve(.resumeCloudSyncUsingLocalProfiles)
  }

  private func resolve(
    _ decision: ProfileSyncRecoveryDecision
  ) async {
    guard let repository else { return }
    let expectedRecovery: ProfileSyncRecovery? =
      if case .recoveryRequired(let recovery) = status {
        recovery
      } else {
        nil
      }
    isWorking = true
    do {
      status = try await repository.resolveSyncRecovery(
        decision,
        expectedRecovery: expectedRecovery
      )
    } catch {
      status = await repository.syncStatus()
    }
    isWorking = false
  }
}
