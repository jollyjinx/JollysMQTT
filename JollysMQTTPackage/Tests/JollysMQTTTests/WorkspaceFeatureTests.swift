import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("Workspace feature")
struct WorkspaceFeatureTests {
  @Test("Connecting transforms only the current workspace")
  func connectTransformsCurrentWorkspace() {
    let firstID = WorkspaceID()
    let secondID = WorkspaceID()
    let profileID = UUID()
    var first = WorkspaceFeature.State(record: WorkspaceRecord(id: firstID))
    let second = WorkspaceFeature.State(record: WorkspaceRecord(id: secondID))

    let effect = WorkspaceFeature.reduce(
      state: &first,
      intent: .connect(profileID: profileID)
    )

    #expect(first.record.route == .connected(profileID: profileID))
    #expect(second.record.route == .serverList)
    #expect(effect == .save(first.record))
  }

  @Test("Pinning one chart persists it and changing brokers clears that broker-specific series")
  func chartConfigurationFollowsBrokerIdentity() {
    let firstBroker = UUID()
    let secondBroker = UUID()
    let chart = NumericChartConfiguration(
      series: NumericChartSeries(
        id: NumericChartSeriesID(
          brokerID: firstBroker,
          topic: "factory/temperature"
        ),
        conversion: NumericChartValueConversion(kind: .number)
      ),
      isPaused: true,
      autoScroll: false
    )
    var state = WorkspaceFeature.State(
      record: WorkspaceRecord(
        id: WorkspaceID(),
        route: .connected(profileID: firstBroker),
        selectedProfileID: firstBroker
      ),
      isLoaded: true
    )

    let save = WorkspaceFeature.reduce(
      state: &state,
      intent: .setNumericChart(chart)
    )

    #expect(state.record.numericChart == chart)
    #expect(save == .save(state.record))

    _ = WorkspaceFeature.reduce(
      state: &state,
      intent: .connect(profileID: secondBroker)
    )

    #expect(state.record.numericChart == nil)
  }

  @Test("Connecting the selected broker still clears a foreign chart")
  func connectingSelectedBrokerClearsForeignChart() {
    let chartBroker = UUID()
    let selectedBroker = UUID()
    let chart = numericChartConfiguration(brokerID: chartBroker)
    var state = WorkspaceFeature.State(
      record: WorkspaceRecord(
        id: WorkspaceID(),
        route: .serverList,
        selectedProfileID: selectedBroker,
        numericChart: chart
      )
    )

    _ = WorkspaceFeature.reduce(
      state: &state,
      intent: .connect(profileID: selectedBroker)
    )

    #expect(state.record.route == .connected(profileID: selectedBroker))
    #expect(state.record.numericChart == nil)
  }

  @Test("A chart can only be set for the connected broker")
  func chartSettingRequiresMatchingConnectedRoute() {
    let brokerID = UUID()
    let chart = numericChartConfiguration(brokerID: brokerID)
    var serverList = WorkspaceFeature.State(
      record: WorkspaceRecord(
        id: WorkspaceID(),
        route: .serverList,
        selectedProfileID: brokerID
      )
    )
    var wrongConnection = WorkspaceFeature.State(
      record: WorkspaceRecord(
        id: WorkspaceID(),
        route: .connected(profileID: UUID())
      )
    )

    #expect(
      WorkspaceFeature.reduce(
        state: &serverList,
        intent: .setNumericChart(chart)
      ) == nil
    )
    #expect(serverList.record.numericChart == nil)
    #expect(
      WorkspaceFeature.reduce(
        state: &wrongConnection,
        intent: .setNumericChart(chart)
      ) == nil
    )
    #expect(wrongConnection.record.numericChart == nil)
  }

  @Test("Loading sanitizes a foreign connected chart but retains it at the broker list")
  func loadingSanitizesChartAgainstConnectedRoute() {
    let chartBroker = UUID()
    let connectedBroker = UUID()
    let chart = numericChartConfiguration(brokerID: chartBroker)
    var connected = WorkspaceFeature.State(
      record: WorkspaceRecord(id: WorkspaceID())
    )
    var serverList = WorkspaceFeature.State(
      record: WorkspaceRecord(id: WorkspaceID())
    )

    WorkspaceFeature.reduce(
      state: &connected,
      action: .loaded(
        .success(
          WorkspaceRecord(
            id: connected.record.id,
            route: .connected(profileID: connectedBroker),
            selectedProfileID: connectedBroker,
            numericChart: chart
          )
        )
      )
    )
    WorkspaceFeature.reduce(
      state: &serverList,
      action: .loaded(
        .success(
          WorkspaceRecord(
            id: serverList.record.id,
            route: .serverList,
            selectedProfileID: chartBroker,
            numericChart: chart
          )
        )
      )
    )

    #expect(connected.record.numericChart == nil)
    #expect(serverList.record.numericChart == chart)
  }

  @Test("Connected restoration preserves matching card order and sanitizes every foreign card")
  func loadingSanitizesAllDashboardCards() {
    let connectedBroker = UUID()
    let foreignBroker = UUID()
    let first = numericChartCard(
      brokerID: connectedBroker,
      topic: "first"
    )
    let foreign = numericChartCard(
      brokerID: foreignBroker,
      topic: "foreign"
    )
    let second = numericChartCard(
      brokerID: connectedBroker,
      topic: "second"
    )
    var state = WorkspaceFeature.State(
      record: WorkspaceRecord(id: WorkspaceID())
    )

    WorkspaceFeature.reduce(
      state: &state,
      action: .loaded(
        .success(
          WorkspaceRecord(
            id: state.record.id,
            route: .connected(profileID: connectedBroker),
            selectedProfileID: connectedBroker,
            numericChartDashboard: .init(
              cards: [first, foreign, second]
            )
          )
        )
      )
    )

    #expect(
      state.record.numericChartDashboard.cards.map(\.id)
        == [first.id, second.id]
    )

    _ = WorkspaceFeature.reduce(
      state: &state,
      intent: .connect(profileID: foreignBroker)
    )
    #expect(state.record.numericChartDashboard.cards.isEmpty)
  }

  @Test("A dashboard update is rejected unless every card belongs to the connected broker")
  func dashboardSettingRequiresOneConnectedBroker() {
    let connectedBroker = UUID()
    let matching = numericChartCard(
      brokerID: connectedBroker,
      topic: "matching"
    )
    let foreign = numericChartCard(
      brokerID: UUID(),
      topic: "foreign"
    )
    var state = WorkspaceFeature.State(
      record: WorkspaceRecord(
        id: WorkspaceID(),
        route: .connected(profileID: connectedBroker),
        selectedProfileID: connectedBroker
      )
    )

    #expect(
      WorkspaceFeature.reduce(
        state: &state,
        intent: .setNumericChartDashboard(
          .init(cards: [matching, foreign])
        )
      ) == nil
    )
    #expect(state.record.numericChartDashboard.cards.isEmpty)
  }

  @Test("The wide layout keeps topic, payload, publish, and chart in one candidate")
  func wideChartCoexistsWithTopicExplorer() {
    let layout = SelectedPayloadWorkspaceLayout(hasPinnedChart: true)

    #expect(
      layout.wideCandidateRegions == [
        .topicExplorer,
        .payloadInspector,
        .publishComposer,
        .numericChart,
      ]
    )
    #expect(layout.showsWideChart)
  }

  @Test("The scene rejects chart pinning outside its connected broker")
  @MainActor
  func scenePinningRequiresConnectedBroker() {
    let scene = JollysMQTTAppDependencies(
      profileRepository: SceneProfileRepository(profiles: []),
      workspaceRepository: RecordingWorkspaceRepository()
    ).makeSceneStore(id: WorkspaceID())
    let chart = numericChartConfiguration(brokerID: UUID())

    scene.pinNumericChart(chart.series)

    #expect(scene.numericChartDashboard.state.cards.isEmpty)
    #expect(scene.workspace.state.record.numericChart == nil)
  }

  @Test("The scene restores, feeds, and persists its numeric chart")
  @MainActor
  func sceneNumericChartComposition() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let brokerID = UUID()
    let workspaceID = WorkspaceID()
    let chart = numericChartConfiguration(brokerID: brokerID)
    let profileRepository = LocalProfileRepository(
      fileURL: directory.appending(path: "profiles.json"),
      installationID: workspaceFeatureTestInstallationID
    )
    try await profileRepository.replaceAll([
      workspaceRankedProfile(id: brokerID, name: "Chart", rank: 1)
    ])
    let workspaceRepository = LocalWorkspaceRepository(
      directoryURL: directory.appending(
        path: "workspaces",
        directoryHint: .isDirectory
      )
    )
    try await workspaceRepository.save(
      WorkspaceRecord(
        id: workspaceID,
        route: .connected(profileID: brokerID),
        selectedProfileID: brokerID,
        numericChart: chart
      )
    )
    let historyRepository = EmptyChartWorkspaceHistoryRepository()
    let scene = JollysMQTTAppDependencies(
      profileRepository: profileRepository,
      workspaceRepository: workspaceRepository,
      historyRepositoryProvider: .init { _ in historyRepository }
    ).makeSceneStore(id: workspaceID)

    await scene.start()
    let cardID = try #require(
      scene.numericChartDashboard.state.cards.first?.id
    )
    let chartStore = try #require(
      scene.numericChartDashboard.cardStore(for: cardID)
    )
    #expect(chartStore.state.configuration == chart)

    scene.topics.receive(
      await workspaceTopicSnapshot(
        brokerID: brokerID,
        historySourceID: "current-source"
      )
    )
    for _ in 0..<1_000 {
      if chartStore.state.samples.map(\.id.ordinal) == [1] {
        break
      }
      await Task.yield()
    }

    #expect(chartStore.state.historySourceID == "current-source")
    #expect(chartStore.state.samples.map(\.value) == [42])

    chartStore.send(.setPaused(true))
    await scene.workspace.flush()
    let persisted = try await workspaceRepository.load(id: workspaceID)
    #expect(persisted.numericChart?.isPaused == true)
  }

  @Test("The observable store restores routing and presentation on relaunch")
  @MainActor
  func storeRestoresWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = WorkspaceID()
    let profileID = UUID()
    let repository = LocalWorkspaceRepository(directoryURL: directory)
    let first = WorkspaceStore(id: id, repository: repository)

    await first.load()
    await first.send(.selectProfile(profileID))
    await first.send(.connect(profileID: profileID))
    await first.send(.selectTopic("devices/pump/state"))
    await first.send(
      .setTopicOutlinePresentation(
        expandedTopics: ["devices", "devices/pump"],
        searchText: "state",
        sortMode: .descendantMessages
      )
    )

    let relaunched = WorkspaceStore(id: id, repository: repository)
    await relaunched.load()

    #expect(relaunched.state.record.route == .connected(profileID: profileID))
    #expect(relaunched.state.record.selectedProfileID == profileID)
    #expect(relaunched.state.record.selectedTopic == "devices/pump/state")
    #expect(
      relaunched.state.record.expandedTopics
        == ["devices", "devices/pump"]
    )
    #expect(relaunched.state.record.topicSearchText == "state")
    #expect(
      relaunched.state.record.topicSortMode == .descendantMessages
    )
  }

  @Test("Freeze state is deliberately absent from durable workspace state")
  func freezeIsEphemeral() throws {
    let data = try JSONEncoder().encode(
      WorkspaceRecord(
        id: WorkspaceID(),
        expandedTopics: ["root"],
        topicSearchText: "value",
        topicSortMode: .descendantTopics
      )
    )
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(json["isTopicViewFrozen"] == nil)
    #expect(json["pendingChangeCount"] == nil)
  }

  @Test("Changing brokers clears broker-specific topic navigation")
  func changingBrokerClearsTopicIdentity() {
    let firstBroker = UUID()
    let secondBroker = UUID()
    var state = WorkspaceFeature.State(
      record: WorkspaceRecord(
        id: WorkspaceID(),
        route: .connected(profileID: firstBroker),
        selectedProfileID: firstBroker,
        selectedTopic: "same/path",
        expandedTopics: ["same", "same/path"],
        topicSearchText: "same",
        topicSortMode: .recentActivity
      )
    )

    _ = WorkspaceFeature.reduce(
      state: &state,
      intent: .connect(profileID: secondBroker)
    )

    #expect(state.record.selectedTopic == nil)
    #expect(state.record.expandedTopics.isEmpty)
    #expect(state.record.topicSearchText == "same")
    #expect(state.record.topicSortMode == .recentActivity)
  }

  @Test("Scene topic intents persist navigation preferences but not Freeze")
  @MainActor
  func sceneTopicPresentationPersistence() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspaceRepository = LocalWorkspaceRepository(
      directoryURL: directory.appending(
        path: "workspaces",
        directoryHint: .isDirectory
      )
    )
    let dependencies = JollysMQTTAppDependencies(
      profileRepository: LocalProfileRepository(
        fileURL: directory.appending(path: "profiles.json"),
        installationID: workspaceFeatureTestInstallationID
      ),
      workspaceRepository: workspaceRepository
    )
    let id = WorkspaceID()
    let scene = dependencies.makeSceneStore(id: id)
    await scene.start()

    scene.topics.restorePresentation(
      selectedTopic: nil,
      expandedTopics: ["root"],
      searchText: "",
      sortMode: .name
    )
    scene.setTopicSearchText("temperature")
    scene.setTopicSortMode(.recentActivity)
    scene.freezeTopicView()
    await scene.workspace.flush()

    let restored = dependencies.makeSceneStore(id: id)
    await restored.start()

    #expect(restored.topics.state.expandedTopics == ["root"])
    #expect(restored.topics.state.searchText == "temperature")
    #expect(restored.topics.state.sortMode == .recentActivity)
    #expect(!restored.topics.state.isFrozen)
    #expect(restored.topics.state.pendingChangeCount == 0)
  }

  @Test("Cancelling the structured owner closes and releases exactly once")
  func lifecycleCancellationIsIdempotent() async {
    let id = WorkspaceID()
    let repository = RecordingWorkspaceRepository()
    let releaser = RecordingWorkspaceReleaser()
    let owner = WorkspaceLifecycleOwner(
      id: id,
      repository: repository,
      releaser: releaser
    )
    let task = Task {
      await owner.run()
    }
    await owner.waitUntilRunning()

    task.cancel()
    await task.value
    await owner.release()
    await owner.release()

    #expect(await repository.closedIDs() == [id])
    #expect(await releaser.releasedIDs() == [id])
  }

  @Test("Two scene stores share repositories but restore independent state")
  @MainActor
  func sceneCompositionRestoresIndependentState() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profileRepository = LocalProfileRepository(
      fileURL: directory.appending(path: "profiles.json"),
      installationID: workspaceFeatureTestInstallationID
    )
    let workspaceRepository = LocalWorkspaceRepository(
      directoryURL: directory.appending(
        path: "workspaces",
        directoryHint: .isDirectory
      )
    )
    let firstProfile = RankedBrokerProfile(
      profile: BrokerProfile(
        id: UUID(),
        name: "First",
        host: "first.example",
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
      ),
      reorderRank: 1_024
    )
    let secondProfile = RankedBrokerProfile(
      profile: BrokerProfile(
        id: UUID(),
        name: "Second",
        host: "second.example",
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
      ),
      reorderRank: 2_048
    )
    try await profileRepository.replaceAll([firstProfile, secondProfile])
    let dependencies = JollysMQTTAppDependencies(
      profileRepository: profileRepository,
      workspaceRepository: workspaceRepository
    )
    let firstID = WorkspaceID()
    let secondID = WorkspaceID()
    let first = dependencies.makeSceneStore(id: firstID)
    let second = dependencies.makeSceneStore(id: secondID)
    #expect(first !== second)
    #expect(first.workspace !== second.workspace)
    #expect(first.serverList !== second.serverList)

    await first.start()
    await second.start()
    await first.connectCurrentWorkspace(
      ConnectReadyState(
        profile: firstProfile.profile,
        credentialRevision: 0,
        requestID: 1
      )
    )
    await first.workspace.send(.selectTopic("first/topic"))
    second.selectedProfileID = secondProfile.id
    await second.workspace.flush()

    let restoredFirst = dependencies.makeSceneStore(id: firstID)
    let restoredSecond = dependencies.makeSceneStore(id: secondID)
    await restoredFirst.start()
    await restoredSecond.start()

    #expect(
      restoredFirst.workspace.state.record.route
        == .connected(profileID: firstProfile.id)
    )
    #expect(restoredFirst.workspace.state.record.selectedTopic == "first/topic")
    #expect(restoredSecond.workspace.state.record.route == .serverList)
    #expect(restoredSecond.selectedProfileID == secondProfile.id)
  }

  @Test("Committed profile deletion synchronizes scene selection and maintenance context")
  @MainActor
  func profileDeletionSynchronizesSceneContext() async {
    let first = workspaceRankedProfile(name: "First", rank: 1)
    let second = workspaceRankedProfile(name: "Second", rank: 2)
    let successfulRepository = SceneProfileRepository(
      profiles: [first, second]
    )
    let successfulScene = JollysMQTTAppDependencies(
      profileRepository: successfulRepository,
      workspaceRepository: RecordingWorkspaceRepository()
    ).makeSceneStore(id: WorkspaceID())
    await successfulScene.start()
    successfulScene.selectedProfileID = first.id
    #expect(
      successfulScene.historyMaintenance.state.context?.brokerID == first.id
    )

    successfulScene.serverList.sendImmediately(
      .requestDeleteProfile(first.id)
    )
    await successfulScene.serverList.send(.confirmDeleteProfile)

    #expect(successfulScene.selectedProfileID == second.id)
    #expect(
      successfulScene.workspace.state.record.selectedProfileID == second.id
    )
    #expect(
      successfulScene.historyMaintenance.state.context?.brokerID == second.id
    )

    let failingRepository = SceneProfileRepository(
      profiles: [first, second],
      failWrites: true
    )
    let failingScene = JollysMQTTAppDependencies(
      profileRepository: failingRepository,
      workspaceRepository: RecordingWorkspaceRepository()
    ).makeSceneStore(id: WorkspaceID())
    await failingScene.start()
    failingScene.selectedProfileID = first.id

    failingScene.serverList.sendImmediately(
      .requestDeleteProfile(first.id)
    )
    await failingScene.serverList.send(.confirmDeleteProfile)

    #expect(failingScene.serverList.state.deletionOutcome?.profile == .failed)
    #expect(failingScene.selectedProfileID == first.id)
    #expect(
      failingScene.historyMaintenance.state.context?.brokerID == first.id
    )
  }

  @Test("Rapid presentation changes persist in intent order")
  @MainActor
  func presentationWritesRemainOrdered() async {
    let repository = ControlledWorkspaceRepository()
    let store = WorkspaceStore(id: WorkspaceID(), repository: repository)
    await store.load()
    await repository.holdNextSave()
    let olderSelection = UUID()
    let latestSelection = UUID()

    store.selectedProfileID = olderSelection
    await repository.waitForHeldSave()
    store.selectedProfileID = latestSelection
    await repository.releaseHeldSave()
    await store.flush()

    #expect(await repository.persistedRecord()?.selectedProfileID == latestSelection)
  }

  @Test("A normally closed scene restores its connected placeholder")
  @MainActor
  func closedSceneRestoresOnRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = RankedBrokerProfile(
      profile: BrokerProfile(
        id: UUID(),
        name: "Restored",
        host: "restored.example",
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
      ),
      reorderRank: 1_024
    )
    let profileRepository = LocalProfileRepository(
      fileURL: directory.appending(path: "profiles.json"),
      installationID: workspaceFeatureTestInstallationID
    )
    try await profileRepository.replaceAll([profile])
    let workspaceRepository = LocalWorkspaceRepository(
      directoryURL: directory.appending(
        path: "workspaces",
        directoryHint: .isDirectory
      )
    )
    let dependencies = JollysMQTTAppDependencies(
      profileRepository: profileRepository,
      workspaceRepository: workspaceRepository
    )
    let id = WorkspaceID()
    let scene = dependencies.makeSceneStore(id: id)
    await scene.start()
    await scene.connectCurrentWorkspace(
      ConnectReadyState(
        profile: profile.profile,
        credentialRevision: 0,
        requestID: 1
      )
    )
    let ownerTask = Task {
      await scene.run()
    }
    await scene.waitUntilOwned()

    ownerTask.cancel()
    await ownerTask.value
    let closed = try await workspaceRepository.load(id: id)
    #expect(closed.closedAt != nil)

    let relaunched = dependencies.makeSceneStore(id: id)
    await relaunched.start()
    #expect(
      relaunched.workspace.state.record.route
        == .connected(profileID: profile.id)
    )
    #expect(relaunched.workspace.state.record.closedAt == nil)
  }

  @Test("Flush includes a write enqueued while an older write is pending")
  @MainActor
  func flushTracksTheLatestTail() async {
    let repository = ControlledWorkspaceRepository()
    let store = WorkspaceStore(id: WorkspaceID(), repository: repository)
    await store.load()
    await repository.holdNextSave()
    let firstSelection = UUID()
    let latestSelection = UUID()
    store.selectedProfileID = firstSelection
    await repository.waitForHeldSave()

    let flushing = Task {
      await store.flush()
    }
    await store.waitUntilFlushIsWaiting()
    store.selectedProfileID = latestSelection
    await repository.releaseHeldSave()
    await flushing.value

    #expect(await repository.persistedRecord()?.selectedProfileID == latestSelection)
  }

  @Test("A future workspace version is visible and never overwritten")
  @MainActor
  func futureVersionFailureIsPresented() async {
    let repository = FutureWorkspaceRepository()
    let store = WorkspaceStore(id: WorkspaceID(), repository: repository)

    await store.load()

    #expect(store.persistenceErrorPresented)
    #expect(store.state.record.route == .serverList)
    #expect(await repository.saveCount() == 0)
    store.persistenceErrorPresented = false
    #expect(!store.persistenceErrorPresented)
  }
}

private let workspaceFeatureTestInstallationID = UUID(
  uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
)

private func numericChartConfiguration(
  brokerID: UUID
) -> NumericChartConfiguration {
  NumericChartConfiguration(
    series: NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: brokerID,
        topic: "factory/temperature"
      ),
      conversion: NumericChartValueConversion(kind: .number)
    )
  )
}

private func numericChartCard(
  brokerID: UUID,
  topic: String
) -> NumericChartCardConfiguration {
  NumericChartCardConfiguration(
    chart: NumericChartConfiguration(
      series: NumericChartSeries(
        id: NumericChartSeriesID(
          brokerID: brokerID,
          topic: topic
        ),
        conversion: NumericChartValueConversion(kind: .number)
      )
    )
  )
}

private actor RecordingWorkspaceRepository: WorkspaceRepositoryProtocol {
  private var closed: [WorkspaceID] = []

  func load(id: WorkspaceID) -> WorkspaceRecord {
    WorkspaceRecord(id: id)
  }

  func save(_ record: WorkspaceRecord) {}

  func markClosed(id: WorkspaceID) {
    closed.append(id)
  }

  func pruneClosed() {}

  func closedIDs() -> [WorkspaceID] { closed }
}

private actor SceneProfileRepository: ProfileRepositoryProtocol {
  private var profiles: [RankedBrokerProfile]
  private let failWrites: Bool

  init(
    profiles: [RankedBrokerProfile],
    failWrites: Bool = false
  ) {
    self.profiles = profiles
    self.failWrites = failWrites
  }

  func load() -> [RankedBrokerProfile] { profiles }

  func replaceAll(_ profiles: [RankedBrokerProfile]) throws {
    if failWrites {
      throw ProfileRepositoryFailure()
    }
    self.profiles = profiles
  }
}

private actor RecordingWorkspaceReleaser: WorkspaceLeaseReleasing {
  private var ids: [WorkspaceID] = []

  func release(workspaceID: WorkspaceID) {
    ids.append(workspaceID)
  }

  func releasedIDs() -> [WorkspaceID] { ids }
}

private actor ControlledWorkspaceRepository: WorkspaceRepositoryProtocol {
  private var record: WorkspaceRecord?
  private var shouldHoldNextSave = false
  private var heldSaveStarted = false
  private var heldSaveWaiters: [CheckedContinuation<Void, Never>] = []
  private var heldSaveContinuation: CheckedContinuation<Void, Never>?

  func load(id: WorkspaceID) -> WorkspaceRecord {
    record ?? WorkspaceRecord(id: id)
  }

  func save(_ record: WorkspaceRecord) async {
    if shouldHoldNextSave {
      shouldHoldNextSave = false
      heldSaveStarted = true
      let waiters = heldSaveWaiters
      heldSaveWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        heldSaveContinuation = continuation
      }
    }
    self.record = record
  }

  func markClosed(id: WorkspaceID) {}
  func pruneClosed() {}

  func holdNextSave() {
    shouldHoldNextSave = true
  }

  func waitForHeldSave() async {
    guard !heldSaveStarted else { return }
    await withCheckedContinuation { continuation in
      heldSaveWaiters.append(continuation)
    }
  }

  func releaseHeldSave() {
    heldSaveContinuation?.resume()
    heldSaveContinuation = nil
  }

  func persistedRecord() -> WorkspaceRecord? { record }
}

private actor FutureWorkspaceRepository: WorkspaceRepositoryProtocol {
  private var saves = 0

  func load(id: WorkspaceID) throws -> WorkspaceRecord {
    throw LocalWorkspaceRepositoryError.unsupportedVersion(99)
  }

  func save(_ record: WorkspaceRecord) {
    saves += 1
  }

  func markClosed(id: WorkspaceID) {}
  func pruneClosed() {}
  func saveCount() -> Int { saves }
}

private func workspaceRankedProfile(
  id: UUID = UUID(),
  name: String,
  rank: Int64
) -> RankedBrokerProfile {
  RankedBrokerProfile(
    profile: BrokerProfile(
      id: id,
      name: name,
      host: "\(name.lowercased()).example",
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
    ),
    reorderRank: rank
  )
}

private func workspaceTopicSnapshot(
  brokerID: UUID,
  historySourceID: String
) async -> BrokerTopicTreeSnapshot {
  let ingestion = BrokerFeedIngestion(
    brokerID: brokerID,
    historySourceID: historySourceID,
    historyWriter: DisabledBrokerHistoryWriter()
  )
  await ingestion.ingest(
    BrokerInboundMessage(
      connectionEpoch: ConnectionEpochID(),
      ordinal: 1,
      topic: "factory/temperature",
      payload: Data("42".utf8),
      qos: .atMostOnce,
      retained: false,
      duplicate: false,
      receivedAtMicroseconds: 42
    )
  )
  return await ingestion.flush()
}

private actor EmptyChartWorkspaceHistoryRepository:
  BrokerHistoryReading
{
  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }
}
