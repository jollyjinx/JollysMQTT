import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Synchronization
import Testing

@testable import JollysMQTT

@Suite("Workspace broker-feed composition")
struct WorkspaceConnectionTests {
  @MainActor
  @Test("Fresh connections restore broker charts and geometry after closing the original workspace")
  func brokerChartsSurviveNewConnection() async throws {
    let fixture = try await WorkspaceConnectionFixture()
    defer { fixture.remove() }
    let chartDirectory = fixture.directory.appending(path: "broker-charts")
    func dependencies() -> JollysMQTTAppDependencies {
      JollysMQTTAppDependencies(
        profileRepository: fixture.profileRepository,
        workspaceRepository: fixture.workspaceRepository,
        brokerChartRepository: LocalBrokerChartRepository(directoryURL: chartDirectory)
      )
    }
    let original = dependencies().makeSceneStore(id: WorkspaceID())
    await original.start()
    await original.connectCurrentWorkspace(fixture.connectReady(requestID: 1))
    let series = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: fixture.profile.id, topic: "device/metrics",
        jsonPointer: PayloadJSONPointer(rawValue: "/temperature")
      ),
      conversion: NumericChartValueConversion(kind: .number, multiplier: 0.1)
    )
    original.pinNumericChart(series)
    let cardID = try #require(original.numericChartDashboard.state.cards.first?.id)
    original.numericChartDashboard.send(.setColor(cardID, .orange))
    original.numericChartDashboard.cardStore(for: cardID)?.send(.setPaused(true))
    let frame = ChartWindowFrame(x: 1400, y: 200, width: 720, height: 600)
    original.brokerCharts.saveWindowFrame(frame)
    let lifetime = Task { await original.run() }
    await original.waitUntilOwned()
    lifetime.cancel()
    await lifetime.value

    // A different repository and workspace model a later connection/app launch.
    let nextDependencies = dependencies()
    let brokers = nextDependencies.makeSceneStore(id: WorkspaceID())
    await brokers.start()
    await brokers.serverList.send(.connect(fixture.profile.id))
    let ready = try #require(brokers.serverList.state.connectReady)
    let nextID = try #require(await brokers.prepareConnectionWindow(ready))
    let next = nextDependencies.makeSceneStore(id: nextID)
    await next.start()
    #expect(next.numericChartDashboard.state.configuration == original.numericChartDashboard.state.configuration)
    #expect(next.brokerCharts.windowFrame == frame)

    // Removing the final card is an explicit empty preference, never a missing record.
    next.numericChartDashboard.send(.remove(cardID))
    await next.brokerCharts.flush()
    let reopened = dependencies().makeSceneStore(id: original.workspace.state.record.id)
    await reopened.start()
    #expect(reopened.numericChartDashboard.state.cards.isEmpty)
  }

  @MainActor
  @Test("Opening connection windows preserves the broker list and shares the broker feed")
  func separateConnectionWindows() async throws {
    let fixture = try await WorkspaceConnectionFixture()
    defer { fixture.remove() }
    let recorder = RecordingFeedFactory()
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 30,
      makeFeed: { _ in recorder.makeFeed() }
    )
    let dependencies = fixture.dependencies(
      brokerFeedFactory: BrokerFeedLeaseFactory { registry.makeLease(workspaceID: $0) },
      brokerFeedGenerationCoordinator: registry
    )
    let brokers = dependencies.makeSceneStore(id: WorkspaceID())
    await brokers.start()
    await brokers.serverList.send(.connect(fixture.profile.id))
    let ready = try #require(brokers.serverList.state.connectReady)
    let firstID = try #require(await brokers.prepareConnectionWindow(ready))
    #expect(await brokers.prepareConnectionWindow(ready) == nil)
    #expect(brokers.workspace.state.record.route == .serverList)
    #expect(brokers.serverList.state.connectReady == nil)
    #expect(recorder.feeds().isEmpty)

    await brokers.serverList.send(.connect(fixture.profile.id))
    let nextReady = try #require(brokers.serverList.state.connectReady)
    let secondID = try #require(await brokers.prepareConnectionWindow(nextReady))
    #expect(firstID != secondID)
    let first = dependencies.makeSceneStore(id: firstID)
    let second = dependencies.makeSceneStore(id: secondID)
    let firstTask = Task { await first.run() }
    let secondTask = Task { await second.run() }
    await first.waitUntilOwned()
    await second.waitUntilOwned()
    #expect(first.workspace.state.record.route == .connected(profileID: fixture.profile.id))
    #expect(second.workspace.state.record.route == .connected(profileID: fixture.profile.id))
    #expect(await registry.leaseCount(for: fixture.profile.id) == 2)
    #expect(recorder.feeds().count == 1)
    firstTask.cancel()
    await firstTask.value
    #expect(await registry.leaseCount(for: fixture.profile.id) == 1)
    #expect(brokers.workspace.state.record.route == .serverList)
    secondTask.cancel()
    await secondTask.value
    #expect(await registry.leaseCount(for: fixture.profile.id) == 0)
  }

  @MainActor
  @Test("A failed connection-window save leaves the broker list usable and reports the failure")
  func connectionWindowSaveFailure() async throws {
    let fixture = try await WorkspaceConnectionFixture()
    defer { fixture.remove() }
    let repository = FailingConnectionWindowRepository()
    let dependencies = JollysMQTTAppDependencies(
      profileRepository: fixture.profileRepository,
      workspaceRepository: repository
    )
    let brokers = dependencies.makeSceneStore(id: WorkspaceID())
    await brokers.start()
    await brokers.serverList.send(.connect(fixture.profile.id))
    let ready = try #require(brokers.serverList.state.connectReady)
    #expect(await brokers.prepareConnectionWindow(ready) == nil)
    #expect(brokers.workspace.state.persistenceError)
    #expect(brokers.workspace.state.record.route == .serverList)
    #expect(brokers.serverList.state.connectReady == nil)
    await brokers.serverList.send(.connect(fixture.profile.id))
    #expect(brokers.serverList.state.connectReady != nil)
  }

  @MainActor
  @Test("Two scene stores share the process-wide registry feed")
  func sceneStoresShareRegistryFeed() async throws {
    let fixture = try await WorkspaceConnectionFixture()
    defer { fixture.remove() }
    let recorder = RecordingFeedFactory()
    let registry = BrokerFeedRegistry(
      gracePeriodSeconds: 30,
      makeFeed: { _ in recorder.makeFeed() }
    )
    let dependencies = fixture.dependencies(
      brokerFeedFactory: BrokerFeedLeaseFactory { workspaceID in
        registry.makeLease(workspaceID: workspaceID)
      },
      brokerFeedGenerationCoordinator: registry
    )
    let first = dependencies.makeSceneStore(id: WorkspaceID())
    let second = dependencies.makeSceneStore(id: WorkspaceID())
    await first.start()
    await second.start()

    await first.connectCurrentWorkspace(fixture.connectReady(requestID: 1))
    await second.connectCurrentWorkspace(fixture.connectReady(requestID: 2))

    #expect(recorder.feeds().count == 1)
    #expect(await recorder.feeds().first?.connectCount() == 1)
    #expect(await registry.leaseCount(for: fixture.profile.id) == 2)

    await first.showServerList()

    #expect(await registry.leaseCount(for: fixture.profile.id) == 1)
    #expect(await recorder.feeds().first?.releaseCount() == 0)
    await second.showServerList()
  }

  @MainActor
  @Test("Show Brokers releases the feed and the next Connect acquires a fresh one")
  func showBrokersThenReconnectsWithFreshFeed() async throws {
    let fixture = try await WorkspaceConnectionFixture()
    defer { fixture.remove() }
    let recorder = RecordingFeedFactory()
    let dependencies = fixture.dependencies(
      brokerFeedFactory: BrokerFeedLeaseFactory { _ in
        recorder.makeFeed()
      }
    )
    let scene = dependencies.makeSceneStore(id: WorkspaceID())
    await scene.start()

    await scene.setSceneActive(false)
    await scene.connectCurrentWorkspace(fixture.connectReady(requestID: 1))
    let first = try #require(recorder.feeds().first)
    #expect(
      await first.recordedEvents()
        == [
          .sceneActive(false),
          .connect,
        ]
    )

    await scene.showServerList()
    #expect(
      await first.recordedEvents()
        == [
          .sceneActive(false),
          .connect,
          .cancel,
          .release,
        ]
    )

    await scene.connectCurrentWorkspace(fixture.connectReady(requestID: 2))
    let feeds = recorder.feeds()
    #expect(feeds.count == 2)
    let second = try #require(feeds.last)
    #expect(first !== second)
    #expect(
      await second.recordedEvents()
        == [
          .sceneActive(false),
          .connect,
        ]
    )
  }

  @MainActor
  @Test("Structured scene cancellation releases the live feed once")
  func sceneCancellationReleasesFeed() async throws {
    let fixture = try await WorkspaceConnectionFixture()
    defer { fixture.remove() }
    let recorder = RecordingFeedFactory()
    let dependencies = fixture.dependencies(
      brokerFeedFactory: BrokerFeedLeaseFactory { _ in
        recorder.makeFeed()
      }
    )
    let scene = dependencies.makeSceneStore(id: WorkspaceID())
    await scene.start()
    await scene.connectCurrentWorkspace(fixture.connectReady(requestID: 1))
    let feed = try #require(recorder.feeds().first)
    let task = Task { await scene.run() }
    await scene.waitUntilOwned()

    task.cancel()
    await task.value

    #expect(await feed.releaseCount() == 1)
  }

  @MainActor
  @Test("Restarting the scene task does not reconnect a restored feed")
  func repeatedRunDoesNotReconnect() async throws {
    let fixture = try await WorkspaceConnectionFixture()
    defer { fixture.remove() }
    let recorder = RecordingFeedFactory()
    let workspaceID = WorkspaceID()
    try await fixture.workspaceRepository.save(
      WorkspaceRecord(
        id: workspaceID,
        route: .connected(profileID: fixture.profile.id),
        selectedProfileID: fixture.profile.id
      )
    )
    let dependencies = fixture.dependencies(
      brokerFeedFactory: BrokerFeedLeaseFactory { _ in
        recorder.makeFeed()
      }
    )
    let scene = dependencies.makeSceneStore(id: workspaceID)
    let firstRun = Task { await scene.run() }
    await scene.waitUntilOwned()
    let feed = try #require(recorder.feeds().first)
    #expect(await feed.connectCount() == 1)

    let repeatedRun = Task { await scene.run() }
    await repeatedRun.value

    #expect(await feed.connectCount() == 1)
    firstRun.cancel()
    await firstRun.value
  }

  @Test("Installation identity survives a new defaults instance")
  func installationIdentityIsStableAcrossLaunches() throws {
    let suiteName = "JollysMQTTTests.\(UUID().uuidString)"
    let key = "installation-test"
    let firstDefaults = try #require(UserDefaults(suiteName: suiteName))
    firstDefaults.removePersistentDomain(forName: suiteName)
    defer { firstDefaults.removePersistentDomain(forName: suiteName) }

    let first = JollysMQTTAppDependencies.installationID(
      defaults: firstDefaults,
      key: key
    )
    let relaunchedDefaults = try #require(UserDefaults(suiteName: suiteName))
    let second = JollysMQTTAppDependencies.installationID(
      defaults: relaunchedDefaults,
      key: key
    )

    #expect(first == second)
  }
}

private actor FailingConnectionWindowRepository: WorkspaceRepositoryProtocol {
  func load(id: WorkspaceID) -> WorkspaceRecord { WorkspaceRecord(id: id) }
  func save(_ record: WorkspaceRecord) throws {
    if case .connected = record.route { throw WorkspaceFailure() }
  }
  func markClosed(id: WorkspaceID) {}
  func pruneClosed() {}
}

private struct WorkspaceConnectionFixture {
  let directory: URL
  let profile: BrokerProfile
  let profileRepository: LocalProfileRepository
  let workspaceRepository: LocalWorkspaceRepository

  init() async throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    profile = BrokerProfile(
      id: UUID(),
      name: "Test",
      host: "broker.example",
      port: 1_883,
      transport: .tcp,
      username: nil,
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [
        SubscriptionDefinition(filter: "#", qos: .atMostOnce)
      ]
    )
    profileRepository = LocalProfileRepository(
      fileURL: directory.appending(path: "profiles.json"),
      installationID: workspaceConnectionTestInstallationID
    )
    workspaceRepository = LocalWorkspaceRepository(
      directoryURL: directory.appending(
        path: "workspaces",
        directoryHint: .isDirectory
      )
    )
    try await profileRepository.replaceAll([
      RankedBrokerProfile(profile: profile, reorderRank: 1_024)
    ])
  }

  func dependencies(
    brokerFeedFactory: BrokerFeedLeaseFactory,
    brokerFeedGenerationCoordinator:
      any BrokerFeedGenerationCoordinating =
      NoopBrokerFeedGenerationCoordinator()
  ) -> JollysMQTTAppDependencies {
    JollysMQTTAppDependencies(
      profileRepository: profileRepository,
      workspaceRepository: workspaceRepository,
      brokerFeedFactory: brokerFeedFactory,
      brokerFeedGenerationCoordinator:
        brokerFeedGenerationCoordinator
    )
  }

  func connectReady(requestID: UInt64) -> ConnectReadyState {
    ConnectReadyState(
      profile: profile,
      credentialRevision: 0,
      requestID: requestID
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private let workspaceConnectionTestInstallationID = UUID(
  uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
)

private final class RecordingFeedFactory: Sendable {
  private let storage = Mutex<[RecordingFeed]>([])

  func makeFeed() -> RecordingFeed {
    let feed = RecordingFeed()
    storage.withLock { $0.append(feed) }
    return feed
  }

  func feeds() -> [RecordingFeed] {
    storage.withLock { $0 }
  }
}

private actor RecordingFeed: BrokerFeedLeaseControlling {
  enum Event: Equatable, Sendable {
    case sceneActive(Bool)
    case connect
    case retry
    case cancel
    case release
  }

  private let stream: AsyncStream<BrokerFeedSnapshot>
  private let continuation: AsyncStream<BrokerFeedSnapshot>.Continuation
  private var events: [Event] = []

  init() {
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
    events.append(.connect)
    continuation.yield(BrokerFeedSnapshot(phase: .connected))
  }

  func retry() {
    events.append(.retry)
  }

  func cancel() {
    events.append(.cancel)
    continuation.yield(.idle)
  }

  func setSceneActive(_ isActive: Bool) {
    events.append(.sceneActive(isActive))
  }

  func release() {
    events.append(.release)
    continuation.yield(.idle)
  }

  func recordedEvents() -> [Event] {
    events
  }

  func releaseCount() -> Int {
    events.count(where: { $0 == .release })
  }

  func connectCount() -> Int {
    events.count(where: { $0 == .connect })
  }
}
