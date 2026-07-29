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
        fileURL: directory.appending(path: "profiles.json")
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
      fileURL: directory.appending(path: "profiles.json")
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
      fileURL: directory.appending(path: "profiles.json")
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
  name: String,
  rank: Int64
) -> RankedBrokerProfile {
  RankedBrokerProfile(
    profile: BrokerProfile(
      id: UUID(),
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
