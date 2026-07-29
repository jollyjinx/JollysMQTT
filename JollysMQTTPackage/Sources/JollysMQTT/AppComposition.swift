import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import Observation

public struct BrokerFeedLeaseFactory: Sendable {
  public static let noop = BrokerFeedLeaseFactory { _ in
    NoopBrokerFeedLease()
  }

  private let operation: @Sendable (WorkspaceID) -> any BrokerFeedLeaseControlling

  public init(
    _ operation:
      @escaping @Sendable (WorkspaceID) -> any BrokerFeedLeaseControlling
  ) {
    self.operation = operation
  }

  public func makeFeed(
    for workspaceID: WorkspaceID
  ) -> any BrokerFeedLeaseControlling {
    operation(workspaceID)
  }
}

private actor NoopBrokerFeedLease: BrokerFeedLeaseControlling {
  private let stream: AsyncStream<BrokerFeedSnapshot>

  init() {
    let (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    self.stream = stream
    continuation.yield(.idle)
  }

  func snapshots() -> AsyncStream<BrokerFeedSnapshot> {
    stream
  }

  func connect(_ configuration: BrokerFeedConfiguration) {}
  func retry() {}
  func cancel() {}
  func setSceneActive(_ isActive: Bool) {}
  func release() {}
}

private actor WorkspaceBrokerFeedLease: BrokerFeedLeaseControlling {
  private let workspaceID: WorkspaceID
  private let factory: BrokerFeedLeaseFactory
  private let stream: AsyncStream<BrokerFeedSnapshot>
  private let continuation: AsyncStream<BrokerFeedSnapshot>.Continuation
  private let topicStream: AsyncStream<BrokerTopicTreeSnapshot>
  private let topicContinuation: AsyncStream<BrokerTopicTreeSnapshot>.Continuation

  private var currentFeed: (any BrokerFeedLeaseControlling)?
  private var observationTask: Task<Void, Never>?
  private var topicObservationTask: Task<Void, Never>?
  private var sceneIsActive = true

  init(
    workspaceID: WorkspaceID,
    factory: BrokerFeedLeaseFactory
  ) {
    self.workspaceID = workspaceID
    self.factory = factory
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedSnapshot.self,
      bufferingPolicy: .bufferingOldest(64)
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

  func connect(_ configuration: BrokerFeedConfiguration) async {
    let feed: any BrokerFeedLeaseControlling
    if let currentFeed {
      feed = currentFeed
    } else {
      feed = factory.makeFeed(for: workspaceID)
      currentFeed = feed
      let continuation = continuation
      observationTask = Task {
        let snapshots = await feed.snapshots()
        for await snapshot in snapshots {
          if Task.isCancelled { return }
          continuation.yield(snapshot)
        }
      }
      let topicContinuation = topicContinuation
      topicObservationTask = Task {
        let snapshots = await feed.topicSnapshots()
        for await snapshot in snapshots {
          if Task.isCancelled { return }
          topicContinuation.yield(snapshot)
        }
      }
      await feed.setSceneActive(sceneIsActive)
    }
    await feed.connect(configuration)
  }

  func retry() async {
    await currentFeed?.retry()
  }

  func retryHistoryPersistence() async {
    await currentFeed?.retryHistoryPersistence()
  }

  func cancel() async {
    await currentFeed?.cancel()
  }

  func setSceneActive(_ isActive: Bool) async {
    sceneIsActive = isActive
    await currentFeed?.setSceneActive(isActive)
  }

  func reconnectAllToApply() async {
    await currentFeed?.reconnectAllToApply()
  }

  func publish(
    _ request: BrokerPublishRequest
  ) async -> BrokerPublishResult {
    guard let currentFeed else {
      return .failure(.notConnected)
    }
    return await currentFeed.publish(request)
  }

  func release() async {
    let feed = currentFeed
    let observer = observationTask
    let topicObserver = topicObservationTask
    currentFeed = nil
    observationTask = nil
    topicObservationTask = nil
    observer?.cancel()
    topicObserver?.cancel()
    await feed?.release()
    await observer?.value
    await topicObserver?.value
    continuation.yield(.idle)
    topicContinuation.yield(.empty)
  }
}

public struct JollysMQTTAppDependencies: Sendable {
  public static let shared: JollysMQTTAppDependencies = {
    let support =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    let root = support.appending(
      path: "JollysMQTT",
      directoryHint: .isDirectory
    )
    let installationID = JollysMQTTAppDependencies.installationID()
    let historyDirectory = root.appending(
      path: "history",
      directoryHint: .isDirectory
    )
    let registry = BrokerFeedRegistry { configuration in
      let profile = configuration.profile
      let historyWriter = SQLiteBrokerHistoryWriter(
        databaseURL: historyDirectory.appending(
          path: "\(profile.id.uuidString.lowercased()).sqlite3"
        )
      )
      let ingestion = BrokerFeedIngestion(
        brokerID: profile.id,
        historySourceID: MQTTBrokerFeedAttempt.historySourceID(
          for: profile
        ),
        historyWriter: historyWriter
      )
      let attempt = MQTTBrokerFeedAttempt(
        credentialResolver: CredentialRepository.shared,
        installationID: installationID,
        ingestion: ingestion
      )
      return BrokerFeed(attempt: attempt)
    }
    return JollysMQTTAppDependencies(
      profileRepository: LocalProfileRepository(
        fileURL: root.appending(path: "profiles.json")
      ),
      credentialRepository: CredentialRepository.shared,
      workspaceRepository: LocalWorkspaceRepository(
        directoryURL: root.appending(
          path: "workspaces",
          directoryHint: .isDirectory
        )
      ),
      brokerFeedFactory: .init { workspaceID in
        registry.makeLease(workspaceID: workspaceID)
      },
      brokerFeedGenerationCoordinator: registry
    )
  }()

  public let profileRepository: any ProfileRepositoryProtocol
  public let credentialRepository: any CredentialRepositoryProtocol
  public let workspaceRepository: any WorkspaceRepositoryProtocol
  public let workspaceReleaser: any WorkspaceLeaseReleasing
  public let brokerFeedFactory: BrokerFeedLeaseFactory
  public let brokerFeedGenerationCoordinator: any BrokerFeedGenerationCoordinating

  public init(
    profileRepository: any ProfileRepositoryProtocol,
    credentialRepository: any CredentialRepositoryProtocol = CredentialRepository.shared,
    workspaceRepository: any WorkspaceRepositoryProtocol,
    workspaceReleaser: any WorkspaceLeaseReleasing = NoopWorkspaceLeaseReleaser(),
    brokerFeedFactory: BrokerFeedLeaseFactory = .noop,
    brokerFeedGenerationCoordinator:
      any BrokerFeedGenerationCoordinating =
      NoopBrokerFeedGenerationCoordinator()
  ) {
    self.profileRepository = profileRepository
    self.credentialRepository = credentialRepository
    self.workspaceRepository = workspaceRepository
    self.workspaceReleaser = workspaceReleaser
    self.brokerFeedFactory = brokerFeedFactory
    self.brokerFeedGenerationCoordinator =
      brokerFeedGenerationCoordinator
  }

  @MainActor
  public func makeSceneStore(id: WorkspaceID) -> WorkspaceSceneStore {
    WorkspaceSceneStore(id: id, dependencies: self)
  }

  static func installationID(
    defaults: UserDefaults = .standard,
    key: String = "eu.jinx.JollysMQTT.installation-id.v1"
  ) -> UUID {
    if let value = defaults.string(forKey: key),
      let id = UUID(uuidString: value)
    {
      return id
    }
    let id = UUID()
    defaults.set(id.uuidString.lowercased(), forKey: key)
    return id
  }
}

@MainActor
@Observable
public final class WorkspaceSceneStore {
  public let workspace: WorkspaceStore
  public let serverList: ServerListStore
  public let connection: ConnectionStore
  public let topics: TopicOutlineStore
  public let payloadInspector: PayloadInspectorStore
  public let publishComposer: PublishStore
  public let retainedDeletion: RetainedDeletionStore

  private let workspaceRepository: any WorkspaceRepositoryProtocol
  private let credentialRepository: any CredentialRepositoryProtocol
  private let feed: any BrokerFeedLeaseControlling
  private let lifecycle: WorkspaceLifecycleOwner
  private var hasStarted = false
  private var hasRun = false

  public init(
    id: WorkspaceID,
    dependencies: JollysMQTTAppDependencies
  ) {
    let workspace = WorkspaceStore(
      id: id,
      repository: dependencies.workspaceRepository
    )
    let feed = WorkspaceBrokerFeedLease(
      workspaceID: id,
      factory: dependencies.brokerFeedFactory
    )
    self.workspace = workspace
    self.feed = feed
    self.connection = ConnectionStore(feed: feed)
    self.topics = TopicOutlineStore(feed: feed)
    let payloadInspector = PayloadInspectorStore()
    self.payloadInspector = payloadInspector
    let publishComposer = PublishStore(publisher: feed)
    self.publishComposer = publishComposer
    let retainedDeletion = RetainedDeletionStore(publisher: feed)
    self.retainedDeletion = retainedDeletion
    self.serverList = ServerListStore(
      repository: dependencies.profileRepository,
      credentialRepository: dependencies.credentialRepository,
      brokerFeedGenerationCoordinator:
        dependencies.brokerFeedGenerationCoordinator
    )
    self.workspaceRepository = dependencies.workspaceRepository
    self.credentialRepository = dependencies.credentialRepository
    self.lifecycle = WorkspaceLifecycleOwner(
      id: id,
      repository: dependencies.workspaceRepository,
      releaser: BrokerFeedWorkspaceReleaser(
        feed: feed,
        downstream: dependencies.workspaceReleaser
      ),
      prepareForRelease: {
        await workspace.flush()
      }
    )
    self.topics.onPayloadSelectionChange = {
      [weak payloadInspector, weak publishComposer] selection in
      payloadInspector?.send(
        .selectionChanged(selection)
      )
      publishComposer?.send(
        .selectionChanged(selection.topic)
      )
    }
    self.topics.onRetainedDeletionContextChange = {
      [weak retainedDeletion] context, snapshot in
      retainedDeletion?.updateContext(context, snapshot: snapshot)
    }
  }

  public var selectedProfileID: UUID? {
    get { workspace.state.record.selectedProfileID }
    set {
      workspace.selectedProfileID = newValue
      serverList.sendImmediately(.select(newValue))
    }
  }

  public var selectedTopicID: BrokerTopicID? {
    get {
      topics.state.rows.first(where: \.isSelected)?.id
    }
    set {
      selectTopic(newValue)
    }
  }

  public var topicSearchText: String {
    get { topics.state.searchText }
    set { setTopicSearchText(newValue) }
  }

  public var topicSortMode: BrokerTopicSortMode {
    get { topics.state.sortMode }
    set { setTopicSortMode(newValue) }
  }

  public func run() async {
    guard !hasRun else { return }
    hasRun = true
    await start()
    await restoreConnectionIfNeeded()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await self.lifecycle.run()
      }
      group.addTask {
        await self.connection.observe()
      }
      group.addTask {
        await self.topics.observe()
      }
      await group.next()
      group.cancelAll()
    }
  }

  public func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    do {
      try await workspaceRepository.pruneClosed()
    } catch {
      // Pruning old closed records must not block opening the current scene.
    }
    await workspace.load()
    let expectedBrokerID: UUID?
    switch workspace.state.record.route {
    case .serverList:
      expectedBrokerID = nil
    case .connected(let profileID):
      expectedBrokerID = profileID
    }
    topics.restorePresentation(
      selectedTopic: workspace.state.record.selectedTopic,
      expandedTopics: Set(workspace.state.record.expandedTopics),
      searchText: workspace.state.record.topicSearchText,
      sortMode: workspace.state.record.topicSortMode,
      expectedBrokerID: expectedBrokerID
    )

    let restoredSelection = workspace.state.record.selectedProfileID
    serverList.sendImmediately(.select(restoredSelection))
    await serverList.send(.load)

    if !workspace.state.persistenceError,
      case .serverList = workspace.state.record.route
    {
      let resolvedSelection =
        serverList.state.profiles.contains { $0.id == restoredSelection }
        ? restoredSelection
        : serverList.state.selectedProfileID
      selectedProfileID = resolvedSelection
      await workspace.flush()
    }
  }

  public func connectCurrentWorkspace(_ ready: ConnectReadyState) async {
    workspace.sendImmediately(.connect(profileID: ready.profile.id))
    topics.restorePresentation(
      selectedTopic: workspace.state.record.selectedTopic,
      expandedTopics: Set(workspace.state.record.expandedTopics),
      searchText: workspace.state.record.topicSearchText,
      sortMode: workspace.state.record.topicSortMode,
      expectedBrokerID: ready.profile.id
    )
    serverList.sendImmediately(.consumeConnectReady(requestID: ready.requestID))
    await connection.connect(
      BrokerFeedConfiguration(
        profile: ready.profile,
        credentialRevision: ready.credentialRevision
      )
    )
  }

  public func showServerList() async {
    await connection.cancel()
    await feed.release()
    workspace.sendImmediately(.showServerList)
    topics.restorePresentation(
      selectedTopic: nil,
      expandedTopics: [],
      searchText: topics.state.searchText,
      sortMode: topics.state.sortMode,
      expectedBrokerID: nil
    )
  }

  public func setSceneActive(_ isActive: Bool) async {
    await connection.setSceneActive(isActive)
  }

  public func selectTopic(_ id: BrokerTopicID?) {
    guard
      id == nil || topics.state.rows.contains(where: { $0.id == id })
    else {
      return
    }
    topics.send(.selectTopic(id))
    workspace.sendImmediately(.selectTopic(id?.fullTopic))
  }

  public func toggleTopicExpansion(_ id: BrokerTopicID) {
    topics.send(.toggleExpansion(id))
    persistTopicOutlinePresentation()
  }

  public func setTopicSearchText(_ text: String) {
    topics.send(.setSearchText(text))
    persistTopicOutlinePresentation()
  }

  public func setTopicSortMode(_ mode: BrokerTopicSortMode) {
    topics.send(.setSortMode(mode))
    persistTopicOutlinePresentation()
  }

  public func freezeTopicView() {
    topics.send(.freezeView)
  }

  public func jumpTopicViewToLive() {
    topics.send(.jumpToLive)
  }

  public func retryHistoryPersistence() async {
    await connection.retryHistoryPersistence()
  }

  public func waitUntilOwned() async {
    await lifecycle.waitUntilRunning()
  }

  private func restoreConnectionIfNeeded() async {
    guard case .connected(let profileID) = workspace.state.record.route,
      let profile = serverList.state.profiles.first(where: {
        $0.id == profileID
      })?.profile
    else { return }

    let revision: UInt64
    if profile.username == nil {
      revision = 0
    } else {
      let status = try? await credentialRepository.status(for: profileID)
      revision = status?.revision ?? 0
    }
    await connection.connect(
      BrokerFeedConfiguration(
        profile: profile,
        credentialRevision: revision
      )
    )
  }

  private func persistTopicOutlinePresentation() {
    workspace.sendImmediately(
      .setTopicOutlinePresentation(
        expandedTopics: topics.state.expandedTopics,
        searchText: topics.state.searchText,
        sortMode: topics.state.sortMode
      )
    )
  }
}

@MainActor
@Observable
public final class TopicOutlineStore {
  public private(set) var state = TopicOutlineFeature.State()

  public var snapshot: BrokerTopicTreeSnapshot {
    state.snapshot
  }

  private let feed: any BrokerFeedLeaseControlling
  var onPayloadSelectionChange: (@MainActor @Sendable (PayloadTopicSelection) -> Void)?
  var onRetainedDeletionContextChange:
    (
      @MainActor @Sendable (
        RetainedDeletionContext?,
        BrokerTopicTreeSnapshot
      ) -> Void
    )?

  init(feed: any BrokerFeedLeaseControlling) {
    self.feed = feed
  }

  func restorePresentation(
    selectedTopic: String?,
    expandedTopics: Set<String>,
    searchText: String,
    sortMode: BrokerTopicSortMode,
    expectedBrokerID: UUID? = nil
  ) {
    state = TopicOutlineFeature.State(
      selectedTopic: selectedTopic,
      expandedTopics: expandedTopics,
      searchText: searchText,
      sortMode: sortMode,
      expectedBrokerID: expectedBrokerID
    )
    onPayloadSelectionChange?(state.payloadSelection)
    notifyRetainedDeletionContext()
  }

  func send(_ intent: TopicOutlineFeature.Intent) {
    TopicOutlineFeature.reduce(state: &state, intent: intent)
    onPayloadSelectionChange?(state.payloadSelection)
    notifyRetainedDeletionContext()
  }

  func receive(_ snapshot: BrokerTopicTreeSnapshot) {
    guard
      snapshot.revision == 0
        || snapshot.revision >= state.snapshot.revision
    else {
      return
    }
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )
    onPayloadSelectionChange?(state.payloadSelection)
    notifyRetainedDeletionContext()
  }

  func observe() async {
    let snapshots = await feed.topicSnapshots()
    for await snapshot in snapshots {
      if Task.isCancelled { return }
      receive(snapshot)
    }
  }

  private func notifyRetainedDeletionContext() {
    guard
      let brokerID =
        state.expectedBrokerID
        ?? state.liveSnapshot.roots.first?.id.brokerID,
      let connectionEpoch = state.liveSnapshot.connectionEpoch
    else {
      onRetainedDeletionContextChange?(nil, state.liveSnapshot)
      return
    }
    onRetainedDeletionContextChange?(
      RetainedDeletionContext(
        brokerID: brokerID,
        connectionEpoch: connectionEpoch,
        selectedTopic: state.selectedTopic,
        selectedHasCurrentValue: {
          if case .current = state.payloadSelection { return true }
          return false
        }()
      ),
      state.liveSnapshot
    )
  }
}

@MainActor
@Observable
public final class ConnectionStore {
  public private(set) var state = ConnectionFeature.State()

  private let feed: any BrokerFeedLeaseControlling

  init(feed: any BrokerFeedLeaseControlling) {
    self.feed = feed
  }

  func observe() async {
    let snapshots = await feed.snapshots()
    for await snapshot in snapshots {
      if Task.isCancelled { return }
      ConnectionFeature.reduce(
        state: &state,
        action: .snapshotReceived(snapshot)
      )
    }
  }

  func connect(_ configuration: BrokerFeedConfiguration) async {
    await feed.connect(configuration)
  }

  func retry() async {
    let effect = ConnectionFeature.reduce(
      state: &state,
      intent: .retry
    )
    guard effect == .retry else { return }
    await feed.retry()
  }

  func retryHistoryPersistence() async {
    let effect = ConnectionFeature.reduce(
      state: &state,
      intent: .retryHistoryPersistence
    )
    guard effect == .retryHistoryPersistence else { return }
    await feed.retryHistoryPersistence()
  }

  func cancel() async {
    let effect = ConnectionFeature.reduce(
      state: &state,
      intent: .cancel
    )
    guard effect == .cancel else { return }
    await feed.cancel()
  }

  func setSceneActive(_ isActive: Bool) async {
    await feed.setSceneActive(isActive)
  }

  func applyPendingGenerationLater() {
    let effect = ConnectionFeature.reduce(
      state: &state,
      intent: .applyLater
    )
    precondition(effect == .none)
  }

  func reconnectAllToApply() async {
    let effect = ConnectionFeature.reduce(
      state: &state,
      intent: .reconnectAllToApply
    )
    guard effect == .reconnectAllToApply else { return }
    await feed.reconnectAllToApply()
  }
}

private struct BrokerFeedWorkspaceReleaser: WorkspaceLeaseReleasing {
  let feed: any BrokerFeedLeaseControlling
  let downstream: any WorkspaceLeaseReleasing

  func release(workspaceID: WorkspaceID) async {
    await feed.release()
    await downstream.release(workspaceID: workspaceID)
  }
}
