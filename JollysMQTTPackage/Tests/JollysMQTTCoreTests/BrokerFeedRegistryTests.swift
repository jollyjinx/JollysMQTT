import Foundation
import JollysMQTTCore
import Synchronization
import Testing

@Suite("Broker feed registry")
struct BrokerFeedRegistryTests {
  @Test("Display-only edits keep the same effective connection key")
  func displayOnlyEditKeepsConnectionKey() {
    let profileID = UUID()
    let first = BrokerFeedConfiguration(
      profile: .registryTest(id: profileID, name: "Production"),
      credentialRevision: 3
    )
    let renamed = BrokerFeedConfiguration(
      profile: .registryTest(id: profileID, name: "Production EU"),
      credentialRevision: 3
    )

    #expect(BrokerConnectionKey(first) == BrokerConnectionKey(renamed))
  }

  @Test("Numeric host identity canonicalizes equivalent IP addresses")
  func numericHostIdentityIsCanonical() {
    let profileID = UUID()
    let expanded = BrokerFeedConfiguration(
      profile: .registryTest(
        id: profileID,
        host: "[2001:0db8:0:0:0:0:0:1]"
      ),
      credentialRevision: 3
    )
    let compressed = BrokerFeedConfiguration(
      profile: .registryTest(id: profileID, host: "2001:db8::1"),
      credentialRevision: 3
    )
    let different = BrokerFeedConfiguration(
      profile: .registryTest(id: profileID, host: "2001:db8::2"),
      credentialRevision: 3
    )

    #expect(BrokerConnectionKey(expanded) == BrokerConnectionKey(compressed))
    #expect(BrokerConnectionKey(expanded) != BrokerConnectionKey(different))
  }

  @Test("Two workspaces for one effective profile share one raw feed")
  func sameProfileSharesRawFeed() async {
    let factory = RegistryRawFeedFactory()
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 30,
      makeFeed: factory.makeFeed
    )
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let second = registry.makeLease(workspaceID: WorkspaceID())
    let configuration = BrokerFeedConfiguration(
      profile: .registryTest(),
      credentialRevision: 0
    )

    await first.connect(configuration)
    await second.connect(configuration)

    #expect(factory.createdCount() == 1)
    #expect(await registry.leaseCount(for: configuration.profile.id) == 2)
    #expect(await factory.onlyFeed()?.connectCount() == 1)
    let firstResources = await first.snapshot().sharedResources
    let secondResources = await second.snapshot().sharedResources
    #expect(firstResources != nil)
    #expect(secondResources?.connection == firstResources?.connection)
    #expect(secondResources?.client == firstResources?.client)
    #expect(
      secondResources?.subscriptionSet == firstResources?.subscriptionSet
    )
    #expect(secondResources?.topicIndex == firstResources?.topicIndex)
    #expect(secondResources?.historyWriter == firstResources?.historyWriter)

    await first.release()
    #expect(await factory.onlyFeed()?.releaseCount() == 0)
    #expect(await registry.leaseCount(for: configuration.profile.id) == 1)
    await second.release()
  }

  @Test("Current and newly attached leases receive the shared newest topic snapshot")
  func sharedTopicSnapshotsFanOut() async throws {
    let factory = RegistryRawFeedFactory()
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 30,
      makeFeed: factory.makeFeed
    )
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let second = registry.makeLease(workspaceID: WorkspaceID())
    var firstSnapshots = await first.topicSnapshots().makeAsyncIterator()
    var secondSnapshots = await second.topicSnapshots().makeAsyncIterator()
    _ = await firstSnapshots.next()
    _ = await secondSnapshots.next()
    let configuration = BrokerFeedConfiguration(
      profile: .registryTest(),
      credentialRevision: 0
    )
    await first.connect(configuration)
    let expected = BrokerTopicTreeSnapshot(
      revision: 7,
      roots: [],
      totalMessageCount: 19,
      valueTopicCount: 4,
      historyIsHealthy: true,
      unpersistedMessageCount: 0
    )

    await factory.onlyFeed()?.emit(expected)

    var firstReceived = await firstSnapshots.next()
    if firstReceived?.revision == 0 {
      firstReceived = await firstSnapshots.next()
    }
    #expect(firstReceived == expected)

    await second.connect(configuration)
    var secondReceived = await secondSnapshots.next()
    if secondReceived?.revision == 0 {
      secondReceived = await secondSnapshots.next()
    }
    #expect(secondReceived == expected)
    await first.release()
    await second.release()
  }

  @Test("Scene dormancy is aggregated across attached leases")
  func sceneDormancyIsAggregated() async {
    let factory = RegistryRawFeedFactory()
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let configuration = BrokerFeedConfiguration(
      profile: .registryTest(),
      credentialRevision: 0
    )
    let active = registry.makeLease(workspaceID: WorkspaceID())
    let inactive = registry.makeLease(workspaceID: WorkspaceID())
    await inactive.setSceneActive(false)

    await active.connect(configuration)
    await inactive.connect(configuration)

    #expect(await factory.onlyFeed()?.lastSceneActivity() == true)

    await active.release()

    #expect(await factory.onlyFeed()?.lastSceneActivity() == false)

    await inactive.setSceneActive(true)

    #expect(await factory.onlyFeed()?.lastSceneActivity() == true)
    await inactive.release()
  }

  @Test("The last lease closes only after the injected grace period")
  func lastLeaseUsesGracePeriod() async {
    let factory = RegistryRawFeedFactory()
    let sleeper = RegistryManualSleeper()
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 12,
      clock: BrokerFeedClock(now: Date.init, sleep: sleeper.sleep),
      makeFeed: factory.makeFeed
    )
    let lease = registry.makeLease(workspaceID: WorkspaceID())
    let configuration = BrokerFeedConfiguration(
      profile: .registryTest(),
      credentialRevision: 0
    )
    await lease.connect(configuration)

    await lease.release()
    await sleeper.waitForRequestCount(1)
    #expect(await factory.onlyFeed()?.releaseCount() == 0)

    await sleeper.resumeNext()
    await factory.onlyFeed()?.waitForReleaseCount(1)
    #expect(await factory.onlyFeed()?.releaseCount() == 1)
  }

  @Test("Last-lease retirement shuts down the shared ingestion resources")
  func lastLeaseRetirementShutsDownIngestion() async {
    let sleeper = RegistryManualSleeper()
    let shutdown = RegistryIngestionShutdownRecorder()
    let writer = RegistryIngestionHistoryWriter(recorder: shutdown)
    let ingestion = BrokerFeedIngestion(
      brokerID: UUID(),
      historySourceID: "source",
      historyWriter: writer
    )
    let attempt = RegistryIngestionAttempt(ingestion: ingestion)
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 12,
      clock: BrokerFeedClock(now: Date.init, sleep: sleeper.sleep)
    ) { _ in
      BrokerFeed(attempt: attempt)
    }
    let configuration = BrokerFeedConfiguration(
      profile: .registryTest(),
      credentialRevision: 0
    )
    let lease = registry.makeLease(workspaceID: WorkspaceID())
    await lease.connect(configuration)
    await ingestion.ingest(
      BrokerInboundMessage(
        connectionEpoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "large/tree",
        payload: Data(repeating: 0xA5, count: 1_048_576),
        qos: .atMostOnce,
        retained: false,
        duplicate: false,
        receivedAtMicroseconds: 1
      )
    )

    await lease.release()
    await sleeper.waitForRequestCount(1)
    #expect(await ingestion.metrics().isShutdown == false)
    #expect(await shutdown.shutdownCount == 0)

    await sleeper.resumeNext()
    await shutdown.waitForCount(1)

    let metrics = await ingestion.metrics()
    #expect(metrics.isShutdown)
    #expect(metrics.topicNodeCount == 0)
    #expect(metrics.retainedPayloadByteCount == 0)
    #expect(metrics.pendingHistoryMessageCount == 0)
    #expect(await shutdown.events == ["append:1", "shutdown"])
  }

  @Test("A lease arriving during grace reuses the active generation")
  func reacquireDuringGrace() async {
    let factory = RegistryRawFeedFactory()
    let sleeper = RegistryManualSleeper()
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 12,
      clock: BrokerFeedClock(now: Date.init, sleep: sleeper.sleep),
      makeFeed: factory.makeFeed
    )
    let configuration = BrokerFeedConfiguration(
      profile: .registryTest(),
      credentialRevision: 0
    )
    let first = registry.makeLease(workspaceID: WorkspaceID())
    await first.connect(configuration)
    await first.release()
    await sleeper.waitForRequestCount(1)

    let second = registry.makeLease(workspaceID: WorkspaceID())
    await second.connect(configuration)
    await sleeper.resumeNext()
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(factory.createdCount() == 1)
    #expect(await factory.onlyFeed()?.releaseCount() == 0)
    #expect(await registry.leaseCount(for: configuration.profile.id) == 1)
    await second.release()
    await sleeper.waitForRequestCount(1)
    await sleeper.resumeNext()
    await factory.onlyFeed()?.waitForReleaseCount(1)
  }

  @Test("A detached retry uses edits persisted after full retirement")
  func detachedRetryAfterRetirementUsesLatestConfiguration() async {
    let factory = RegistryRawFeedFactory()
    let sleeper = RegistryManualSleeper()
    let profileID = UUID()
    let active = BrokerProfile.registryTest(
      id: profileID,
      host: "old.example",
      username: "operator"
    )
    let replacement = BrokerProfile.registryTest(
      id: profileID,
      host: "new.example",
      username: "operator"
    )
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 12,
      clock: BrokerFeedClock(now: Date.init, sleep: sleeper.sleep),
      makeFeed: factory.makeFeed
    )
    let lease = registry.makeLease(workspaceID: WorkspaceID())
    await lease.connect(
      BrokerFeedConfiguration(profile: active, credentialRevision: 4)
    )
    await lease.cancel()
    await sleeper.waitForRequestCount(1)
    await sleeper.resumeNext()
    await factory.onlyFeed()?.waitForReleaseCount(1)
    while await registry.activeConfiguration(for: profileID) != nil {
      await Task.yield()
    }

    await registry.profilesDidChange([replacement])
    await registry.credentialRevisionDidChange(
      profileID: profileID,
      revision: 5
    )
    await lease.retry()

    #expect(factory.createdCount() == 2)
    #expect(await registry.leaseCount(for: profileID) == 1)
    #expect(await lease.snapshot().generation == .current)
    #expect(
      await registry.activeConfiguration(for: profileID)
        == BrokerFeedConfiguration(
          profile: replacement,
          credentialRevision: 5
        )
    )
    await lease.release()
  }

  @Test("A detached retry cannot resurrect a deleted profile")
  func detachedRetryAfterDeletionRemainsDisconnected() async {
    let factory = RegistryRawFeedFactory()
    let sleeper = RegistryManualSleeper()
    let profile = BrokerProfile.registryTest()
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 12,
      clock: BrokerFeedClock(now: Date.init, sleep: sleeper.sleep),
      makeFeed: factory.makeFeed
    )
    let lease = registry.makeLease(workspaceID: WorkspaceID())
    await lease.connect(
      BrokerFeedConfiguration(profile: profile, credentialRevision: 4)
    )
    await lease.cancel()
    await sleeper.waitForRequestCount(1)
    await sleeper.resumeNext()
    await factory.onlyFeed()?.waitForReleaseCount(1)
    while await registry.activeConfiguration(for: profile.id) != nil {
      await Task.yield()
    }

    await registry.profilesDidChange([])
    await lease.retry()

    #expect(factory.createdCount() == 1)
    #expect(await registry.leaseCount(for: profile.id) == 0)
    #expect(await lease.snapshot().phase == .failed)
    #expect(await lease.snapshot().lastFailure == .invalidConfiguration)
    await lease.release()
  }

  @Test("A changed profile is pending for every current and new workspace")
  func profileEditMarksGenerationStale() async {
    let factory = RegistryRawFeedFactory()
    let profileID = UUID()
    let active = BrokerFeedConfiguration(
      profile: .registryTest(id: profileID, host: "old.example"),
      credentialRevision: 2
    )
    let editedProfile = BrokerProfile.registryTest(
      id: profileID,
      host: "new.example"
    )
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let second = registry.makeLease(workspaceID: WorkspaceID())
    await first.connect(active)
    await registry.profilesDidChange([editedProfile])

    let firstGeneration = await first.snapshot().generation
    guard case .stale(let revision, nil) = firstGeneration else {
      Issue.record("Expected the active workspace to show a stale generation")
      await first.release()
      return
    }

    await second.connect(
      BrokerFeedConfiguration(
        profile: editedProfile,
        credentialRevision: 2
      )
    )

    #expect(factory.createdCount() == 1)
    #expect(
      await second.snapshot().generation
        == .stale(pendingRevision: revision, blocker: nil)
    )
    #expect(
      await registry.activeConfiguration(for: profileID)?.profile.host
        == "old.example"
    )
    await first.release()
    await second.release()
  }

  @Test("A credential revision creates a new pending generation")
  func credentialRevisionMarksGenerationStale() async {
    let factory = RegistryRawFeedFactory()
    let profile = BrokerProfile.registryTest(username: "operator")
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let lease = registry.makeLease(workspaceID: WorkspaceID())
    await lease.connect(
      BrokerFeedConfiguration(profile: profile, credentialRevision: 4)
    )

    await registry.credentialRevisionDidChange(
      profileID: profile.id,
      revision: 5
    )

    #expect(
      await lease.snapshot().generation
        == .stale(pendingRevision: 1, blocker: nil)
    )
    #expect(
      await registry.activeConfiguration(for: profile.id)?
        .credentialRevision == 4
    )
    await lease.release()
  }

  @Test("A fixed client ID conflicts only within one broker namespace")
  func fixedClientIDConflictIsBrokerScoped() async {
    let factory = RegistryRawFeedFactory()
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let conflicting = registry.makeLease(workspaceID: WorkspaceID())
    let differentBroker = registry.makeLease(workspaceID: WorkspaceID())
    await first.connect(
      BrokerFeedConfiguration(
        profile: .registryTest(
          host: "broker.example",
          clientIDPolicy: .explicit("console")
        ),
        credentialRevision: 0
      )
    )
    let conflictingProfile = BrokerProfile.registryTest(
      host: "BROKER.EXAMPLE",
      clientIDPolicy: .explicit("console")
    )
    await conflicting.connect(
      BrokerFeedConfiguration(
        profile: conflictingProfile,
        credentialRevision: 0
      )
    )
    await differentBroker.connect(
      BrokerFeedConfiguration(
        profile: .registryTest(
          host: "other.example",
          clientIDPolicy: .explicit("console")
        ),
        credentialRevision: 0
      )
    )

    #expect(factory.createdCount() == 2)
    #expect(
      await conflicting.snapshot().lastFailure == .fixedClientIDConflict
    )
    #expect(await registry.leaseCount(for: conflictingProfile.id) == 0)
    await first.release()
    await conflicting.release()
    await differentBroker.release()
  }

  @Test("Equivalent IPv6 spellings share one fixed-ID namespace")
  func equivalentIPv6HostsConflictWithinNamespace() async {
    let factory = RegistryRawFeedFactory()
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let equivalent = registry.makeLease(workspaceID: WorkspaceID())
    let differentAddress = registry.makeLease(workspaceID: WorkspaceID())
    await first.connect(
      BrokerFeedConfiguration(
        profile: .registryTest(
          host: "[2001:0db8:0:0:0:0:0:1]",
          clientIDPolicy: .explicit("console")
        ),
        credentialRevision: 0
      )
    )
    await equivalent.connect(
      BrokerFeedConfiguration(
        profile: .registryTest(
          host: "2001:db8::1",
          clientIDPolicy: .explicit("console")
        ),
        credentialRevision: 0
      )
    )
    await differentAddress.connect(
      BrokerFeedConfiguration(
        profile: .registryTest(
          host: "2001:db8::2",
          clientIDPolicy: .explicit("console")
        ),
        credentialRevision: 0
      )
    )

    #expect(factory.createdCount() == 2)
    #expect(
      await equivalent.snapshot().lastFailure == .fixedClientIDConflict
    )
    #expect(await differentAddress.snapshot().lastFailure == nil)
    await first.release()
    await equivalent.release()
    await differentAddress.release()
  }

  @Test("The old generation finishes before the replacement is created")
  func reconnectAllIsStrictlyOrdered() async {
    let lifecycle = RegistrySwitchLifecycle()
    let factory = RegistrySequencedFeedFactory(lifecycle: lifecycle)
    let profileID = UUID()
    let active = BrokerProfile.registryTest(
      id: profileID,
      host: "old.example"
    )
    let replacement = BrokerProfile.registryTest(
      id: profileID,
      host: "new.example"
    )
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let second = registry.makeLease(workspaceID: WorkspaceID())
    await first.connect(
      BrokerFeedConfiguration(profile: active, credentialRevision: 0)
    )
    await second.connect(
      BrokerFeedConfiguration(profile: active, credentialRevision: 0)
    )
    let oldResources = await first.snapshot().sharedResources
    await registry.profilesDidChange([replacement])

    let switchTask = Task {
      await first.reconnectAllToApply()
    }
    await lifecycle.waitUntilFirstReleaseStarts()

    #expect(
      lifecycle.events()
        == [
          .created(1),
          .connected(1),
          .releaseStarted(1),
        ]
    )
    #expect(factory.createdCount() == 1)

    await lifecycle.finishFirstRelease()
    await switchTask.value

    #expect(
      lifecycle.events()
        == [
          .created(1),
          .connected(1),
          .releaseStarted(1),
          .releaseFinished(1),
          .created(2),
          .connected(2),
        ]
    )
    #expect(factory.createdCount() == 2)
    #expect(await first.snapshot().generation == .current)
    #expect(await first.snapshot().sharedResources != oldResources)
    #expect(
      await second.snapshot().sharedResources
        == first.snapshot().sharedResources
    )
    #expect(
      await registry.activeConfiguration(for: profileID)?.profile.host
        == "new.example"
    )
    await first.release()
    await second.release()
  }

  @Test("An original lease retries the committed profile and credential")
  func originalLeaseRetryUsesCommittedGeneration() async {
    let factory = RegistryRawFeedFactory()
    let profileID = UUID()
    let active = BrokerProfile.registryTest(
      id: profileID,
      host: "old.example",
      username: "operator"
    )
    let replacement = BrokerProfile.registryTest(
      id: profileID,
      host: "new.example",
      username: "operator"
    )
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let second = registry.makeLease(workspaceID: WorkspaceID())
    let oldConfiguration = BrokerFeedConfiguration(
      profile: active,
      credentialRevision: 4
    )
    await first.connect(oldConfiguration)
    await second.connect(oldConfiguration)
    await registry.profilesDidChange([replacement])
    await registry.credentialRevisionDidChange(
      profileID: profileID,
      revision: 5
    )

    await first.reconnectAllToApply()
    await first.cancel()
    await first.retry()

    #expect(factory.createdCount() == 2)
    #expect(await registry.leaseCount(for: profileID) == 2)
    #expect(await first.snapshot().generation == .current)
    #expect(await second.snapshot().generation == .current)
    #expect(
      await registry.activeConfiguration(for: profileID)
        == BrokerFeedConfiguration(
          profile: replacement,
          credentialRevision: 5
        )
    )
    await first.release()
    await second.release()
  }

  @Test("A pending fixed-ID conflict cannot tear down the active generation")
  func reconnectConflictKeepsOldGeneration() async {
    let lifecycle = RegistrySwitchLifecycle()
    let factory = RegistrySequencedFeedFactory(lifecycle: lifecycle)
    let firstProfile = BrokerProfile.registryTest(
      host: "broker.example",
      clientIDPolicy: .explicit("first")
    )
    let secondProfile = BrokerProfile.registryTest(
      host: "broker.example",
      clientIDPolicy: .explicit("second")
    )
    let conflictingEdit = BrokerProfile.registryTest(
      id: secondProfile.id,
      host: "broker.example",
      clientIDPolicy: .explicit("first")
    )
    let registry = BrokerFeedRegistry(makeFeed: factory.makeFeed)
    let first = registry.makeLease(workspaceID: WorkspaceID())
    let second = registry.makeLease(workspaceID: WorkspaceID())
    await first.connect(
      BrokerFeedConfiguration(profile: firstProfile, credentialRevision: 0)
    )
    await second.connect(
      BrokerFeedConfiguration(profile: secondProfile, credentialRevision: 0)
    )
    await registry.profilesDidChange([conflictingEdit])

    #expect(
      await second.snapshot().generation
        == .stale(
          pendingRevision: 1,
          blocker: .fixedClientIDConflict
        )
    )
    await second.reconnectAllToApply()

    #expect(factory.createdCount() == 2)
    #expect(
      lifecycle.events()
        == [
          .created(1),
          .connected(1),
          .created(2),
          .connected(2),
        ]
    )
    #expect(
      await registry.activeConfiguration(for: secondProfile.id)?
        .profile.clientIDPolicy == .explicit("second")
    )
    await first.release()
    await second.release()
  }
}

private final class RegistryRawFeedFactory: Sendable {
  private let feeds = Mutex<[RegistryRawFeed]>([])

  func makeFeed(
    configuration: BrokerFeedConfiguration
  ) -> any BrokerFeedLeaseControlling {
    let feed = RegistryRawFeed()
    feeds.withLock { $0.append(feed) }
    return feed
  }

  func createdCount() -> Int {
    feeds.withLock(\.count)
  }

  func onlyFeed() -> RegistryRawFeed? {
    feeds.withLock(\.first)
  }
}

private actor RegistryRawFeed: BrokerFeedLeaseControlling {
  private let stream: AsyncStream<BrokerFeedSnapshot>
  private let continuation: AsyncStream<BrokerFeedSnapshot>.Continuation
  private let topicStream: AsyncStream<BrokerTopicTreeSnapshot>
  private let topicContinuation: AsyncStream<BrokerTopicTreeSnapshot>.Continuation
  private var connections = 0
  private var releases = 0
  private var sceneActivities: [Bool] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    (topicStream, topicContinuation) = AsyncStream.makeStream(
      of: BrokerTopicTreeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation.yield(.idle)
    topicContinuation.yield(.empty)
  }

  func snapshots() -> AsyncStream<BrokerFeedSnapshot> {
    stream
  }

  func topicSnapshots() -> AsyncStream<BrokerTopicTreeSnapshot> {
    topicStream
  }

  func emit(_ snapshot: BrokerTopicTreeSnapshot) {
    topicContinuation.yield(snapshot)
  }

  func connect(_ configuration: BrokerFeedConfiguration) {
    connections += 1
    continuation.yield(BrokerFeedSnapshot(phase: .connected))
  }

  func retry() {}
  func cancel() {}
  func setSceneActive(_ isActive: Bool) {
    sceneActivities.append(isActive)
  }

  func release() {
    releases += 1
    continuation.finish()
    topicContinuation.finish()
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func connectCount() -> Int {
    connections
  }

  func releaseCount() -> Int {
    releases
  }

  func waitForReleaseCount(_ count: Int) async {
    while releases < count {
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }
  }

  func lastSceneActivity() -> Bool? {
    sceneActivities.last
  }
}

private actor RegistryIngestionAttempt: BrokerFeedAttempting {
  let ingestion: BrokerFeedIngestion
  private var activeContinuation: AsyncStream<Void>.Continuation?

  init(ingestion: BrokerFeedIngestion) {
    self.ingestion = ingestion
  }

  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws {
    await events.connecting()
    await events.subscribing()
    await events.connected()
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    activeContinuation = continuation
    await withTaskCancellationHandler {
      for await _ in stream {}
    } onCancel: {
      continuation.finish()
    }
    activeContinuation = nil
    throw CancellationError()
  }

  func closeActiveConnection() {
    activeContinuation?.finish()
  }

  func shutdownOwnedWork() async {
    await ingestion.shutdown()
  }

  func topicSnapshots() async -> AsyncStream<BrokerTopicTreeSnapshot> {
    await ingestion.snapshots()
  }
}

private actor RegistryIngestionShutdownRecorder {
  private(set) var events: [String] = []
  var shutdownCount: Int {
    events.count { $0 == "shutdown" }
  }
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func record(_ event: String) {
    events.append(event)
    let ready = waiters
    waiters.removeAll()
    for waiter in ready {
      waiter.resume()
    }
  }

  func waitForCount(_ expected: Int) async {
    while shutdownCount < expected {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }
  }
}

private actor RegistryIngestionHistoryWriter: BrokerHistoryWriting {
  let recorder: RegistryIngestionShutdownRecorder

  init(recorder: RegistryIngestionShutdownRecorder) {
    self.recorder = recorder
  }

  func append(_ messages: [BrokerHistoryMessage]) async throws {
    await recorder.record("append:\(messages.count)")
  }

  func shutdown() async {
    await recorder.record("shutdown")
  }
}

private actor RegistryManualSleeper {
  private struct Request {
    let continuation: CheckedContinuation<Void, Error>
  }

  private var requests: [Request] = []

  func sleep(seconds: Double) async throws {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(Request(continuation: continuation))
    }
  }

  func waitForRequestCount(_ count: Int) async {
    while requests.count < count {
      await Task.yield()
    }
  }

  func resumeNext() {
    guard !requests.isEmpty else { return }
    requests.removeFirst().continuation.resume()
  }
}

private final class RegistrySequencedFeedFactory: Sendable {
  private struct State {
    var nextID = 0
  }

  private let state = Mutex(State())
  private let lifecycle: RegistrySwitchLifecycle

  init(lifecycle: RegistrySwitchLifecycle) {
    self.lifecycle = lifecycle
  }

  func makeFeed(
    configuration: BrokerFeedConfiguration
  ) -> any BrokerFeedLeaseControlling {
    let id = state.withLock { state in
      state.nextID += 1
      return state.nextID
    }
    lifecycle.record(.created(id))
    return RegistrySequencedFeed(id: id, lifecycle: lifecycle)
  }

  func createdCount() -> Int {
    state.withLock(\.nextID)
  }
}

private final class RegistrySwitchLifecycle: Sendable {
  enum Event: Equatable, Sendable {
    case created(Int)
    case connected(Int)
    case releaseStarted(Int)
    case releaseFinished(Int)
  }

  private struct State {
    var events: [Event] = []
  }

  private let state = Mutex(State())
  private let firstReleaseGate = RegistryReleaseGate()

  func record(_ event: Event) {
    state.withLock { $0.events.append(event) }
  }

  func events() -> [Event] {
    state.withLock(\.events)
  }

  func waitUntilFirstReleaseStarts() async {
    await firstReleaseGate.waitUntilStarted()
  }

  func finishFirstRelease() async {
    await firstReleaseGate.finish()
  }

  func holdFirstRelease() async {
    await firstReleaseGate.hold()
  }
}

private actor RegistryReleaseGate {
  private var started = false
  private var canFinish = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  func hold() async {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    guard !canFinish else { return }
    await withCheckedContinuation { continuation in
      finishWaiters.append(continuation)
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finish() {
    canFinish = true
    let waiters = finishWaiters
    finishWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor RegistrySequencedFeed: BrokerFeedLeaseControlling {
  private let id: Int
  private let lifecycle: RegistrySwitchLifecycle
  private let stream: AsyncStream<BrokerFeedSnapshot>
  private let continuation: AsyncStream<BrokerFeedSnapshot>.Continuation

  init(id: Int, lifecycle: RegistrySwitchLifecycle) {
    self.id = id
    self.lifecycle = lifecycle
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation.yield(.idle)
  }

  func snapshots() -> AsyncStream<BrokerFeedSnapshot> {
    stream
  }

  func connect(_ configuration: BrokerFeedConfiguration) {
    lifecycle.record(.connected(id))
    continuation.yield(BrokerFeedSnapshot(phase: .connected))
  }

  func retry() {}
  func cancel() {}
  func setSceneActive(_ isActive: Bool) {}

  func release() async {
    lifecycle.record(.releaseStarted(id))
    if id == 1 {
      await lifecycle.holdFirstRelease()
    }
    lifecycle.record(.releaseFinished(id))
    continuation.finish()
  }
}

extension BrokerProfile {
  fileprivate static func registryTest(
    id: UUID = UUID(),
    name: String = "Test",
    host: String = "broker.example",
    username: String? = nil,
    clientIDPolicy: ClientIDPolicy = .stableGenerated,
    subscriptions: [SubscriptionDefinition] = [
      SubscriptionDefinition(filter: "#", qos: .atMostOnce)
    ]
  ) -> BrokerProfile {
    BrokerProfile(
      id: id,
      name: name,
      host: host,
      port: 1_883,
      transport: .tcp,
      username: username,
      clientIDPolicy: clientIDPolicy,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: subscriptions
    )
  }
}
