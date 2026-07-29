import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private enum BrokerHostIdentity: Hashable, Sendable {
  case ipv4(Data)
  case ipv6(Data)
  case dnsName(String)

  init(_ host: String) {
    let numericHost: String
    if host.first == "[", host.last == "]" {
      numericHost = String(host.dropFirst().dropLast())
    } else {
      numericHost = host
    }

    #if canImport(Darwin) || canImport(Glibc)
      var ipv4Address = in_addr()
      if numericHost.withCString({
        inet_pton(AF_INET, $0, &ipv4Address) == 1
      }) {
        self = .ipv4(withUnsafeBytes(of: ipv4Address) { Data($0) })
        return
      }

      var ipv6Address = in6_addr()
      if numericHost.withCString({
        inet_pton(AF_INET6, $0, &ipv6Address) == 1
      }) {
        self = .ipv6(withUnsafeBytes(of: ipv6Address) { Data($0) })
        return
      }
    #endif

    self = .dnsName(host.lowercased())
  }
}

public struct BrokerConnectionKey: Hashable, Sendable {
  private struct Subscription: Hashable, Sendable {
    let filter: String
    let qos: MQTTQualityOfService
  }

  private let host: BrokerHostIdentity
  private let port: Int
  private let transport: BrokerTransport
  private let username: String?
  private let clientIDPolicy: ClientIDPolicy
  private let cleanSession: Bool
  private let keepAliveSeconds: Int
  private let reconnectPolicy: ReconnectPolicy
  private let subscriptions: [Subscription]
  private let credentialRevision: UInt64

  public init(_ configuration: BrokerFeedConfiguration) {
    let profile = configuration.profile
    self.host = BrokerHostIdentity(profile.host)
    self.port = profile.port
    self.transport = profile.transport
    self.username = profile.username
    self.clientIDPolicy = profile.clientIDPolicy
    self.cleanSession = profile.cleanSession
    self.keepAliveSeconds = profile.keepAliveSeconds
    self.reconnectPolicy = profile.reconnectPolicy
    self.subscriptions = profile.subscriptions
      .filter(\.isEnabled)
      .map { Subscription(filter: $0.filter, qos: $0.qos) }
      .sorted {
        if $0.filter != $1.filter {
          return $0.filter < $1.filter
        }
        return $0.qos.rawValue < $1.qos.rawValue
      }
    self.credentialRevision = configuration.credentialRevision
  }
}

public protocol BrokerFeedGenerationCoordinating: Sendable {
  func profilesDidChange(_ profiles: [BrokerProfile]) async
  func credentialRevisionDidChange(
    profileID: BrokerProfile.ID,
    revision: UInt64
  ) async
}

public struct NoopBrokerFeedGenerationCoordinator:
  BrokerFeedGenerationCoordinating
{
  public init() {}

  public func profilesDidChange(_ profiles: [BrokerProfile]) {}

  public func credentialRevisionDidChange(
    profileID: BrokerProfile.ID,
    revision: UInt64
  ) {}
}

public actor BrokerFeedRegistry: BrokerFeedGenerationCoordinating {
  public typealias FeedFactory =
    @Sendable (BrokerFeedConfiguration) -> any BrokerFeedLeaseControlling

  private struct LeaseRecord: Sendable {
    let lease: BrokerFeedRegistryLease
    var sceneIsActive: Bool
  }

  private struct BrokerNamespace: Equatable, Sendable {
    let host: BrokerHostIdentity
    let port: Int
    let transport: BrokerTransport

    init(_ profile: BrokerProfile) {
      self.host = BrokerHostIdentity(profile.host)
      self.port = profile.port
      self.transport = profile.transport
    }
  }

  private struct PendingGeneration: Sendable {
    var configuration: BrokerFeedConfiguration
    let revision: UInt64
    var blocker: BrokerFeedGenerationBlocker?
  }

  private struct Entry {
    var configuration: BrokerFeedConfiguration
    var key: BrokerConnectionKey
    var generation: UInt64
    var resources: BrokerFeedSharedResourceIdentity
    var feed: (any BrokerFeedLeaseControlling)?
    var feedIdentity: UUID?
    var leases: [UUID: LeaseRecord]
    var snapshot: BrokerFeedSnapshot
    var topicSnapshot: BrokerTopicTreeSnapshot
    var observationTask: Task<Void, Never>?
    var topicObservationTask: Task<Void, Never>?
    var graceTask: Task<Void, Never>?
    var graceToken: UInt64
    var pending: PendingGeneration?
    var switchTarget: PendingGeneration?
    var nextPendingRevision: UInt64
  }

  private struct Retirement {
    let token: UUID
    let configuration: BrokerFeedConfiguration
    let task: Task<Void, Never>
  }

  private let gracePeriodSeconds: Double
  private let clock: BrokerFeedClock
  private let makeFeedOperation: FeedFactory
  private var entries: [BrokerProfile.ID: Entry] = [:]
  private var leaseProfiles: [UUID: BrokerProfile.ID] = [:]
  private var retirements: [BrokerProfile.ID: Retirement] = [:]
  private var committedConfigurations: [BrokerProfile.ID: BrokerFeedConfiguration] = [:]
  private var desiredConfigurations: [BrokerProfile.ID: BrokerFeedConfiguration] = [:]
  private var deletedProfileIDs: Set<BrokerProfile.ID> = []

  public init(
    gracePeriodSeconds: Double = 2,
    clock: BrokerFeedClock = .continuous,
    makeFeed: @escaping FeedFactory
  ) {
    precondition(gracePeriodSeconds >= 0)
    self.gracePeriodSeconds = gracePeriodSeconds
    self.clock = clock
    self.makeFeedOperation = makeFeed
  }

  public nonisolated func makeLease(
    workspaceID: WorkspaceID
  ) -> BrokerFeedRegistryLease {
    BrokerFeedRegistryLease(
      id: UUID(),
      workspaceID: workspaceID,
      registry: self
    )
  }

  public func leaseCount(for profileID: BrokerProfile.ID) -> Int {
    entries[profileID]?.leases.count ?? 0
  }

  public func activeConfiguration(
    for profileID: BrokerProfile.ID
  ) -> BrokerFeedConfiguration? {
    entries[profileID]?.configuration
  }

  public func profilesDidChange(_ profiles: [BrokerProfile]) async {
    let persistedProfileIDs = Set(profiles.map(\.id))
    let knownProfileIDs =
      Set(entries.keys)
      .union(committedConfigurations.keys)
      .union(desiredConfigurations.keys)
    for profileID in knownProfileIDs.subtracting(persistedProfileIDs) {
      desiredConfigurations[profileID] = nil
      committedConfigurations[profileID] = nil
      deletedProfileIDs.insert(profileID)
    }

    for profile in profiles {
      deletedProfileIDs.remove(profile.id)
      let entry = entries[profile.id]
      let liveConfiguration =
        entry?.pending?.configuration
        ?? entry?.switchTarget?.configuration
        ?? entry?.configuration
        ?? committedConfigurations[profile.id]
      let credentialRevision =
        desiredConfigurations[profile.id]?.credentialRevision
        ?? liveConfiguration?.credentialRevision
        ?? 0
      let desired = BrokerFeedConfiguration(
        profile: profile,
        credentialRevision: credentialRevision
      )
      desiredConfigurations[profile.id] = desired
      if entry != nil {
        updateDesiredConfiguration(desired, profileID: profile.id)
        await broadcast(profileID: profile.id)
      }
    }
  }

  public func credentialRevisionDidChange(
    profileID: BrokerProfile.ID,
    revision: UInt64
  ) async {
    guard !deletedProfileIDs.contains(profileID) else { return }
    let entry = entries[profileID]
    let liveConfiguration =
      entry?.pending?.configuration
      ?? entry?.switchTarget?.configuration
      ?? entry?.configuration
      ?? committedConfigurations[profileID]
    let profile =
      desiredConfigurations[profileID]?.profile
      ?? liveConfiguration?.profile
    guard let profile else { return }
    let desired = BrokerFeedConfiguration(
      profile: profile,
      credentialRevision: revision
    )
    desiredConfigurations[profileID] = desired
    if entry != nil {
      updateDesiredConfiguration(desired, profileID: profileID)
      await broadcast(profileID: profileID)
    }
  }

  fileprivate func acquire(
    lease: BrokerFeedRegistryLease,
    leaseID: UUID,
    configuration: BrokerFeedConfiguration,
    sceneIsActive: Bool
  ) async {
    if let retirement = retirements[configuration.profile.id] {
      await retirement.task.value
      finishRetirement(
        profileID: configuration.profile.id,
        token: retirement.token
      )
    }

    if let oldProfileID = leaseProfiles[leaseID],
      oldProfileID != configuration.profile.id
    {
      await detach(leaseID: leaseID)
    }

    let profileID = configuration.profile.id
    guard !deletedProfileIDs.contains(profileID) else {
      await lease.receive(
        BrokerFeedSnapshot(
          phase: .failed,
          lastFailure: .invalidConfiguration
        )
      )
      return
    }

    let key = BrokerConnectionKey(configuration)
    if var entry = entries[profileID] {
      entry.graceTask?.cancel()
      entry.graceTask = nil
      entry.graceToken &+= 1
      if key != entry.key {
        setPending(configuration, in: &entry)
      } else if entry.pending == nil, entry.switchTarget == nil {
        entry.configuration = configuration
        committedConfigurations[profileID] = configuration
      }
      entry.leases[leaseID] = LeaseRecord(
        lease: lease,
        sceneIsActive: sceneIsActive
      )
      entries[profileID] = entry
      leaseProfiles[leaseID] = profileID
      await lease.receive(decoratedSnapshot(for: entry))
      await lease.receive(entry.topicSnapshot)
      await updateSceneActivity(profileID: profileID)
      return
    }

    if hasFixedClientIDConflict(configuration, excluding: profileID) {
      await lease.receive(
        BrokerFeedSnapshot(
          phase: .failed,
          lastFailure: .fixedClientIDConflict
        )
      )
      return
    }

    let entry = Entry(
      configuration: configuration,
      key: key,
      generation: 1,
      resources: BrokerFeedSharedResourceIdentity(),
      feed: nil,
      feedIdentity: nil,
      leases: [
        leaseID: LeaseRecord(
          lease: lease,
          sceneIsActive: sceneIsActive
        )
      ],
      snapshot: .idle,
      topicSnapshot: .empty,
      observationTask: nil,
      topicObservationTask: nil,
      graceTask: nil,
      graceToken: 0,
      pending: nil,
      switchTarget: nil,
      nextPendingRevision: 0
    )
    entries[profileID] = entry
    committedConfigurations[profileID] = configuration
    if desiredConfigurations[profileID] == nil {
      desiredConfigurations[profileID] = configuration
    }
    leaseProfiles[leaseID] = profileID
    await lease.receive(decoratedSnapshot(for: entry))
    await installFeed(
      configuration: configuration,
      profileID: profileID,
      generation: entry.generation
    )
  }

  fileprivate func retry(
    leaseID: UUID,
    lease: BrokerFeedRegistryLease,
    configuration: BrokerFeedConfiguration,
    sceneIsActive: Bool
  ) async {
    guard let profileID = leaseProfiles[leaseID],
      let feed = entries[profileID]?.feed
    else {
      let resolvedConfiguration =
        entries[configuration.profile.id]?.configuration
        ?? desiredConfigurations[configuration.profile.id]
        ?? committedConfigurations[configuration.profile.id]
        ?? configuration
      await lease.adoptCommittedConfiguration(resolvedConfiguration)
      await acquire(
        lease: lease,
        leaseID: leaseID,
        configuration: resolvedConfiguration,
        sceneIsActive: sceneIsActive
      )
      return
    }
    await feed.retry()
  }

  fileprivate func retryHistoryPersistence(
    leaseID: UUID
  ) async {
    guard let profileID = leaseProfiles[leaseID],
      let feed = entries[profileID]?.feed
    else { return }
    await feed.retryHistoryPersistence()
  }

  fileprivate func reconnectAll(leaseID: UUID) async {
    guard let profileID = leaseProfiles[leaseID],
      var entry = entries[profileID],
      entry.switchTarget == nil,
      var target = entry.pending
    else { return }

    target.blocker = blocker(
      for: target.configuration,
      excluding: profileID
    )
    entry.pending = target
    entries[profileID] = entry
    guard target.blocker == nil else {
      await broadcast(profileID: profileID)
      return
    }

    let oldFeed = entry.feed
    let oldObserver = entry.observationTask
    let oldTopicObserver = entry.topicObservationTask
    entry.feed = nil
    entry.feedIdentity = nil
    entry.observationTask = nil
    entry.topicObservationTask = nil
    entry.pending = nil
    entry.switchTarget = target
    entry.snapshot = BrokerFeedSnapshot(phase: .disconnecting)
    entries[profileID] = entry
    oldObserver?.cancel()
    oldTopicObserver?.cancel()
    await broadcast(profileID: profileID)

    await oldFeed?.release()
    await oldObserver?.value
    await oldTopicObserver?.value

    guard var current = entries[profileID],
      current.switchTarget?.revision == target.revision
    else { return }
    current.switchTarget = nil
    guard !current.leases.isEmpty else {
      entries[profileID] = nil
      await refreshPendingBlockersAndBroadcast()
      return
    }

    current.configuration = target.configuration
    current.key = BrokerConnectionKey(target.configuration)
    current.generation &+= 1
    current.resources = BrokerFeedSharedResourceIdentity()
    current.snapshot = .idle
    if let pending = current.pending,
      BrokerConnectionKey(pending.configuration) == current.key
    {
      current.configuration = pending.configuration
      current.pending = nil
    }
    entries[profileID] = current
    committedConfigurations[profileID] = target.configuration
    let leases = current.leases.values.map(\.lease)
    for lease in leases {
      await lease.adoptCommittedConfiguration(target.configuration)
    }
    await installFeed(
      configuration: target.configuration,
      profileID: profileID,
      generation: current.generation
    )
    await refreshPendingBlockersAndBroadcast()
  }

  fileprivate func detach(leaseID: UUID) async {
    guard let profileID = leaseProfiles.removeValue(forKey: leaseID),
      var entry = entries[profileID]
    else { return }
    entry.leases[leaseID] = nil
    guard entry.leases.isEmpty else {
      entries[profileID] = entry
      await updateSceneActivity(profileID: profileID)
      return
    }

    guard entry.switchTarget == nil else {
      entries[profileID] = entry
      return
    }
    entry.graceToken &+= 1
    let token = entry.graceToken
    let clock = clock
    let delay = gracePeriodSeconds
    entry.graceTask = Task { [weak self] in
      do {
        try await clock.sleep(seconds: delay)
        try Task.checkCancellation()
      } catch {
        return
      }
      await self?.expire(profileID: profileID, token: token)
    }
    entries[profileID] = entry
  }

  fileprivate func setSceneActive(
    _ isActive: Bool,
    leaseID: UUID
  ) async {
    guard let profileID = leaseProfiles[leaseID],
      var entry = entries[profileID],
      var lease = entry.leases[leaseID]
    else { return }
    lease.sceneIsActive = isActive
    entry.leases[leaseID] = lease
    entries[profileID] = entry
    await updateSceneActivity(profileID: profileID)
  }

  private func updateDesiredConfiguration(
    _ configuration: BrokerFeedConfiguration,
    profileID: BrokerProfile.ID
  ) {
    guard var entry = entries[profileID] else { return }
    let comparisonKey =
      entry.switchTarget.map {
        BrokerConnectionKey($0.configuration)
      } ?? entry.key
    let key = BrokerConnectionKey(configuration)
    if key == comparisonKey {
      if entry.switchTarget == nil {
        entry.configuration = configuration
        committedConfigurations[profileID] = configuration
      }
      entry.pending = nil
    } else {
      setPending(configuration, in: &entry)
    }
    entries[profileID] = entry
  }

  private func setPending(
    _ configuration: BrokerFeedConfiguration,
    in entry: inout Entry
  ) {
    if var pending = entry.pending,
      BrokerConnectionKey(pending.configuration)
        == BrokerConnectionKey(configuration)
    {
      pending.configuration = configuration
      pending.blocker = blocker(
        for: configuration,
        excluding: configuration.profile.id
      )
      entry.pending = pending
      return
    }
    entry.nextPendingRevision &+= 1
    entry.pending = PendingGeneration(
      configuration: configuration,
      revision: entry.nextPendingRevision,
      blocker: blocker(
        for: configuration,
        excluding: configuration.profile.id
      )
    )
  }

  private func updateSceneActivity(
    profileID: BrokerProfile.ID
  ) async {
    guard let entry = entries[profileID],
      !entry.leases.isEmpty,
      let feed = entry.feed
    else { return }
    await feed.setSceneActive(
      entry.leases.values.contains(where: \.sceneIsActive)
    )
  }

  private func installFeed(
    configuration: BrokerFeedConfiguration,
    profileID: BrokerProfile.ID,
    generation: UInt64
  ) async {
    guard var entry = entries[profileID],
      entry.generation == generation,
      entry.feed == nil,
      !entry.leases.isEmpty
    else { return }
    let feed = makeFeedOperation(configuration)
    let identity = UUID()
    let observer = Task { [weak self] in
      let snapshots = await feed.snapshots()
      for await snapshot in snapshots {
        if Task.isCancelled { return }
        await self?.receive(
          snapshot,
          profileID: profileID,
          feedIdentity: identity
        )
      }
    }
    let topicObserver = Task { [weak self] in
      let snapshots = await feed.topicSnapshots()
      for await snapshot in snapshots {
        if Task.isCancelled { return }
        await self?.receive(
          snapshot,
          profileID: profileID,
          feedIdentity: identity
        )
      }
    }
    entry.feed = feed
    entry.feedIdentity = identity
    entry.observationTask = observer
    entry.topicObservationTask = topicObserver
    entries[profileID] = entry
    await feed.setSceneActive(
      entry.leases.values.contains(where: \.sceneIsActive)
    )
    await feed.connect(configuration)
  }

  private func receive(
    _ snapshot: BrokerFeedSnapshot,
    profileID: BrokerProfile.ID,
    feedIdentity: UUID
  ) async {
    guard var entry = entries[profileID],
      entry.feedIdentity == feedIdentity
    else { return }
    entry.snapshot = snapshot
    entries[profileID] = entry
    await broadcast(profileID: profileID)
  }

  private func receive(
    _ snapshot: BrokerTopicTreeSnapshot,
    profileID: BrokerProfile.ID,
    feedIdentity: UUID
  ) async {
    guard var entry = entries[profileID],
      entry.feedIdentity == feedIdentity
    else { return }
    entry.topicSnapshot = snapshot
    entries[profileID] = entry
    let leases = entry.leases.values.map(\.lease)
    for lease in leases {
      await lease.receive(snapshot)
    }
  }

  private func decoratedSnapshot(for entry: Entry) -> BrokerFeedSnapshot {
    let pending = entry.switchTarget ?? entry.pending
    let generation: BrokerFeedGenerationState
    if let pending {
      generation = .stale(
        pendingRevision: pending.revision,
        blocker: pending.blocker
      )
    } else {
      generation = .current
    }
    return BrokerFeedSnapshot(
      phase: entry.snapshot.phase,
      lastFailure: entry.snapshot.lastFailure,
      retry: entry.snapshot.retry,
      generation: generation,
      sharedResources: entry.resources,
      diagnostic: entry.snapshot.diagnostic
    )
  }

  private func broadcast(profileID: BrokerProfile.ID) async {
    guard let entry = entries[profileID] else { return }
    let snapshot = decoratedSnapshot(for: entry)
    let leases = entry.leases.values.map(\.lease)
    for lease in leases {
      await lease.receive(snapshot)
    }
  }

  private func expire(
    profileID: BrokerProfile.ID,
    token: UInt64
  ) async {
    guard let entry = entries[profileID],
      entry.leases.isEmpty,
      entry.graceToken == token,
      entry.switchTarget == nil
    else { return }
    entries[profileID] = nil
    entry.observationTask?.cancel()
    entry.topicObservationTask?.cancel()
    let retirementToken = UUID()
    let feed = entry.feed
    let observer = entry.observationTask
    let topicObserver = entry.topicObservationTask
    let task = Task {
      await feed?.release()
      await observer?.value
      await topicObserver?.value
    }
    retirements[profileID] = Retirement(
      token: retirementToken,
      configuration: entry.configuration,
      task: task
    )
    await task.value
    finishRetirement(profileID: profileID, token: retirementToken)
    await refreshPendingBlockersAndBroadcast()
  }

  private func finishRetirement(
    profileID: BrokerProfile.ID,
    token: UUID
  ) {
    guard retirements[profileID]?.token == token else { return }
    retirements[profileID] = nil
  }

  private func hasFixedClientIDConflict(
    _ configuration: BrokerFeedConfiguration,
    excluding profileID: BrokerProfile.ID
  ) -> Bool {
    blocker(for: configuration, excluding: profileID) != nil
  }

  private func blocker(
    for configuration: BrokerFeedConfiguration,
    excluding profileID: BrokerProfile.ID
  ) -> BrokerFeedGenerationBlocker? {
    guard
      case .explicit(let candidate) =
        configuration.profile.clientIDPolicy
    else { return nil }
    let namespace = BrokerNamespace(configuration.profile)
    for (otherID, entry) in entries where otherID != profileID {
      let configurations = [
        entry.configuration,
        entry.switchTarget?.configuration,
      ].compactMap { $0 }
      if configurations.contains(where: {
        guard BrokerNamespace($0.profile) == namespace else {
          return false
        }
        guard case .explicit(let value) = $0.profile.clientIDPolicy else {
          return false
        }
        return value == candidate
      }) {
        return .fixedClientIDConflict
      }
    }
    for (otherID, retirement) in retirements where otherID != profileID {
      if BrokerNamespace(retirement.configuration.profile) == namespace,
        case .explicit(let value) =
          retirement.configuration.profile.clientIDPolicy,
        value == candidate
      {
        return .fixedClientIDConflict
      }
    }
    return nil
  }

  private func refreshPendingBlockersAndBroadcast() async {
    let profileIDs = Array(entries.keys)
    for profileID in profileIDs {
      guard var entry = entries[profileID] else { continue }
      if var pending = entry.pending {
        pending.blocker = blocker(
          for: pending.configuration,
          excluding: profileID
        )
        entry.pending = pending
        entries[profileID] = entry
      }
      await broadcast(profileID: profileID)
    }
  }
}

public actor BrokerFeedRegistryLease: BrokerFeedLeaseControlling {
  private let id: UUID
  public nonisolated let workspaceID: WorkspaceID
  private let registry: BrokerFeedRegistry
  private let stream: AsyncStream<BrokerFeedSnapshot>
  private let continuation: AsyncStream<BrokerFeedSnapshot>.Continuation
  private let topicStream: AsyncStream<BrokerTopicTreeSnapshot>
  private let topicContinuation: AsyncStream<BrokerTopicTreeSnapshot>.Continuation
  private var configuration: BrokerFeedConfiguration?
  private var sceneIsActive = true
  private var isReleased = false
  private var currentSnapshot = BrokerFeedSnapshot.idle

  fileprivate init(
    id: UUID,
    workspaceID: WorkspaceID,
    registry: BrokerFeedRegistry
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.registry = registry
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedSnapshot.self,
      bufferingPolicy: .bufferingNewest(64)
    )
    (topicStream, topicContinuation) = AsyncStream.makeStream(
      of: BrokerTopicTreeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation.yield(.idle)
    topicContinuation.yield(.empty)
  }

  public func snapshots() -> AsyncStream<BrokerFeedSnapshot> {
    stream
  }

  public func topicSnapshots() -> AsyncStream<BrokerTopicTreeSnapshot> {
    topicStream
  }

  public func snapshot() -> BrokerFeedSnapshot {
    currentSnapshot
  }

  public func connect(_ configuration: BrokerFeedConfiguration) async {
    guard !isReleased else { return }
    self.configuration = configuration
    await registry.acquire(
      lease: self,
      leaseID: id,
      configuration: configuration,
      sceneIsActive: sceneIsActive
    )
  }

  public func retry() async {
    guard !isReleased, let configuration else { return }
    await registry.retry(
      leaseID: id,
      lease: self,
      configuration: configuration,
      sceneIsActive: sceneIsActive
    )
  }

  public func retryHistoryPersistence() async {
    guard !isReleased else { return }
    await registry.retryHistoryPersistence(leaseID: id)
  }

  public func cancel() async {
    guard !isReleased else { return }
    await registry.detach(leaseID: id)
    currentSnapshot = .idle
    continuation.yield(.idle)
  }

  public func setSceneActive(_ isActive: Bool) async {
    guard !isReleased else { return }
    sceneIsActive = isActive
    await registry.setSceneActive(isActive, leaseID: id)
  }

  public func reconnectAllToApply() async {
    guard !isReleased else { return }
    await registry.reconnectAll(leaseID: id)
  }

  public func release() async {
    guard !isReleased else { return }
    isReleased = true
    await registry.detach(leaseID: id)
    currentSnapshot = .idle
    continuation.yield(.idle)
    continuation.finish()
    topicContinuation.finish()
  }

  fileprivate func receive(_ snapshot: BrokerFeedSnapshot) {
    guard !isReleased else { return }
    currentSnapshot = snapshot
    continuation.yield(snapshot)
  }

  fileprivate func receive(_ snapshot: BrokerTopicTreeSnapshot) {
    guard !isReleased else { return }
    topicContinuation.yield(snapshot)
  }

  fileprivate func adoptCommittedConfiguration(
    _ configuration: BrokerFeedConfiguration
  ) {
    guard !isReleased else { return }
    self.configuration = configuration
  }
}
