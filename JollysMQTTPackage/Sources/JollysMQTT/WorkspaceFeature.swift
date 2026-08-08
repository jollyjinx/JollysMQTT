import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

public enum WorkspaceFeature {
  public struct State: Equatable, Sendable {
    public var record: WorkspaceRecord
    public var isLoaded: Bool
    public var persistenceError: Bool

    public init(
      record: WorkspaceRecord,
      isLoaded: Bool = false,
      persistenceError: Bool = false
    ) {
      self.record = record
      self.isLoaded = isLoaded
      self.persistenceError = persistenceError
    }
  }

  public enum Intent: Equatable, Sendable {
    case load
    case selectProfile(UUID?)
    case connect(profileID: UUID)
    case showServerList
    case profileDeleted(
      profileID: UUID,
      fallbackSelection: UUID?
    )
    case selectTopic(String?)
    case setDestination(WorkspaceDestination)
    case setTopicOutlinePresentation(
      expandedTopics: Set<String>,
      searchText: String,
      sortMode: BrokerTopicSortMode
    )
    case setTopicScrollAnchor(String?)
    case setNumericChart(NumericChartConfiguration?)
    case setNumericChartDashboard(NumericChartDashboardConfiguration)
    case dismissPersistenceError
  }

  public enum Action: Sendable {
    case loaded(Result<WorkspaceRecord, WorkspaceFailure>)
    case persisted(Result<Void, WorkspaceFailure>)
  }

  public enum Effect: Equatable, Sendable {
    case load(WorkspaceID)
    case save(WorkspaceRecord)
  }

  public static func reduce(state: inout State, intent: Intent) -> Effect? {
    switch intent {
    case .load:
      return .load(state.record.id)

    case .selectProfile(let id):
      guard state.record.selectedProfileID != id else { return nil }
      state.record.selectedProfileID = id
      state.record.numericChartDashboard = sanitizedDashboard(
        state.record.numericChartDashboard,
        brokerID: id
      )
      return .save(state.record)

    case .connect(let profileID):
      if state.record.selectedProfileID != profileID {
        state.record.selectedTopic = nil
        state.record.expandedTopics = []
        state.record.topicScrollAnchor = nil
      }
      state.record.numericChartDashboard = sanitizedDashboard(
        state.record.numericChartDashboard,
        brokerID: profileID
      )
      state.record.route = .connected(profileID: profileID)
      state.record.selectedProfileID = profileID
      state.record.closedAt = nil
      return .save(state.record)

    case .showServerList:
      state.record.route = .serverList
      state.record.selectedTopic = nil
      state.record.topicScrollAnchor = nil
      state.record.closedAt = nil
      return .save(state.record)

    case .profileDeleted(let profileID, let fallbackSelection):
      let routeReferencesProfile =
        if case .connected(let connectedProfileID) = state.record.route {
          connectedProfileID == profileID
        } else {
          false
        }
      guard
        routeReferencesProfile
          || state.record.selectedProfileID == profileID
          || state.record.numericChartDashboard.cards.contains(where: {
            $0.chart.series.id.brokerID == profileID
          })
      else {
        return nil
      }
      state.record.route = .serverList
      state.record.selectedProfileID = fallbackSelection
      state.record.selectedTopic = nil
      state.record.expandedTopics = []
      state.record.topicSearchText = ""
      state.record.topicScrollAnchor = nil
      state.record.numericChartDashboard = .init()
      state.record.closedAt = nil
      return .save(state.record)

    case .selectTopic(let topic):
      guard state.record.selectedTopic != topic else { return nil }
      state.record.selectedTopic = topic
      return .save(state.record)

    case .setDestination(let destination):
      guard state.record.destination != destination else { return nil }
      state.record.destination = destination
      return .save(state.record)

    case .setTopicOutlinePresentation(
      let expandedTopics,
      let searchText,
      let sortMode
    ):
      let sortedTopics = expandedTopics.sorted()
      guard
        state.record.expandedTopics != sortedTopics
          || state.record.topicSearchText != searchText
          || state.record.topicSortMode != sortMode
      else {
        return nil
      }
      state.record.expandedTopics = sortedTopics
      state.record.topicSearchText = searchText
      state.record.topicSortMode = sortMode
      return .save(state.record)

    case .setTopicScrollAnchor(let topic):
      guard state.record.topicScrollAnchor != topic else { return nil }
      state.record.topicScrollAnchor = topic
      return .save(state.record)

    case .setNumericChart(let configuration):
      let dashboard = NumericChartDashboardConfiguration(
        cards: configuration.map {
          [
            NumericChartCardConfiguration(
              id: NumericChartCardID(rawValue: state.record.id.rawValue),
              chart: $0.normalizingAutoScroll()
            )
          ]
        } ?? []
      )
      return reduce(
        state: &state,
        intent: .setNumericChartDashboard(dashboard)
      )

    case .setNumericChartDashboard(let dashboard):
      guard case .connected(let profileID) = state.record.route else {
        return nil
      }
      let normalized = dashboard.normalized(
        maximumCardCount:
          NumericChartDashboardPolicy.default.maximumCardCount
      )
      guard normalized.cards.count == dashboard.cards.count,
        normalized.cards.allSatisfy({
          $0.chart.series.id.brokerID == profileID
        }),
        state.record.numericChartDashboard != normalized
      else {
        return nil
      }
      state.record.numericChartDashboard = normalized
      return .save(state.record)

    case .dismissPersistenceError:
      state.persistenceError = false
      return nil
    }
  }

  public static func reduce(state: inout State, action: Action) {
    switch action {
    case .loaded(.success(var record)):
      record.closedAt = nil
      record.numericChartDashboard = NumericChartDashboardConfiguration(
        cards: record.numericChartDashboard.cards.map {
          var card = $0
          card.chart = card.chart.normalizingAutoScroll()
          return card
        }
      )
      if case .connected(let profileID) = record.route {
        record.numericChartDashboard = sanitizedDashboard(
          record.numericChartDashboard,
          brokerID: profileID
        )
      }
      state.record = record
      state.isLoaded = true
      state.persistenceError = false
    case .loaded(.failure):
      state.isLoaded = true
      state.persistenceError = true
    case .persisted(.success):
      state.persistenceError = false
    case .persisted(.failure):
      state.persistenceError = true
    }
  }

  private static func sanitizedDashboard(
    _ dashboard: NumericChartDashboardConfiguration,
    brokerID: UUID?
  ) -> NumericChartDashboardConfiguration {
    guard let brokerID else { return .init() }
    return dashboard.normalized(
      maximumCardCount:
        NumericChartDashboardPolicy.default.maximumCardCount,
      brokerID: brokerID
    )
  }
}

public struct WorkspaceFailure: Error, Equatable, Sendable {
  public init() {}
}

public protocol WorkspaceLeaseReleasing: Sendable {
  func release(workspaceID: WorkspaceID) async
}

public struct NoopWorkspaceLeaseReleaser: WorkspaceLeaseReleasing {
  public init() {}

  public func release(workspaceID: WorkspaceID) async {}
}

public actor WorkspaceLifecycleOwner {
  private let id: WorkspaceID
  private let repository: any WorkspaceRepositoryProtocol
  private let releaser: any WorkspaceLeaseReleasing
  private let prepareForRelease: @Sendable () async -> Void
  private var isRunning = false
  private var hasReleased = false
  private var runningWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    id: WorkspaceID,
    repository: any WorkspaceRepositoryProtocol,
    releaser: any WorkspaceLeaseReleasing = NoopWorkspaceLeaseReleaser(),
    prepareForRelease: @escaping @Sendable () async -> Void = {}
  ) {
    self.id = id
    self.repository = repository
    self.releaser = releaser
    self.prepareForRelease = prepareForRelease
  }

  public func run() async {
    guard !isRunning, !hasReleased else { return }
    isRunning = true
    let waiters = runningWaiters
    runningWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    let (stream, continuation) = AsyncStream<Void>.makeStream()
    await withTaskCancellationHandler {
      for await _ in stream {}
    } onCancel: {
      continuation.finish()
    }
    await release()
  }

  public func waitUntilRunning() async {
    guard !isRunning, !hasReleased else { return }
    await withCheckedContinuation { continuation in
      runningWaiters.append(continuation)
    }
  }

  public func release() async {
    guard !hasReleased else { return }
    hasReleased = true
    await prepareForRelease()
    do {
      try await repository.markClosed(id: id)
    } catch {
      // Lease release remains mandatory even if restoration metadata fails.
    }
    await releaser.release(workspaceID: id)
  }
}

@MainActor
@Observable
public final class WorkspaceStore {
  public private(set) var state: WorkspaceFeature.State

  private let repository: any WorkspaceRepositoryProtocol
  private var persistenceTail: Task<Result<Void, WorkspaceFailure>, Never>?
  private var pendingPersistenceCount = 0
  private var persistenceGeneration: UInt64 = 0
  private var completedPersistenceGeneration: UInt64 = 0
  private var isFlushWaiting = false
  private var flushWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    id: WorkspaceID,
    repository: any WorkspaceRepositoryProtocol
  ) {
    self.state = WorkspaceFeature.State(record: WorkspaceRecord(id: id))
    self.repository = repository
  }

  public func load() async {
    guard !state.isLoaded else { return }
    do {
      let record = try await repository.load(id: state.record.id)
      WorkspaceFeature.reduce(
        state: &state,
        action: .loaded(.success(record))
      )
      try await repository.save(state.record)
    } catch {
      WorkspaceFeature.reduce(
        state: &state,
        action: .loaded(.failure(WorkspaceFailure()))
      )
    }
  }

  public func send(_ intent: WorkspaceFeature.Intent) async {
    guard state.isLoaded else { return }
    guard let effect = WorkspaceFeature.reduce(state: &state, intent: intent) else {
      return
    }
    guard case .save(let record) = effect else { return }
    let task = enqueueSave(record)
    _ = await task.value
  }

  public func sendImmediately(_ intent: WorkspaceFeature.Intent) {
    guard state.isLoaded else { return }
    guard let effect = WorkspaceFeature.reduce(state: &state, intent: intent)
    else {
      return
    }
    guard case .save(let record) = effect else {
      preconditionFailure("Immediate workspace intents can only save presentation state")
    }
    _ = enqueueSave(record)
  }

  public func flush() async {
    while completedPersistenceGeneration < persistenceGeneration {
      guard let persistenceTail else { return }
      isFlushWaiting = true
      let waiters = flushWaiters
      flushWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      _ = await persistenceTail.value
      isFlushWaiting = false
    }
  }

  func waitUntilFlushIsWaiting() async {
    guard !isFlushWaiting else { return }
    await withCheckedContinuation { continuation in
      flushWaiters.append(continuation)
    }
  }

  public var selectedProfileID: UUID? {
    get { state.record.selectedProfileID }
    set { sendImmediately(.selectProfile(newValue)) }
  }

  public var persistenceErrorPresented: Bool {
    get { state.persistenceError }
    set {
      if !newValue {
        sendImmediately(.dismissPersistenceError)
      }
    }
  }

  private func enqueueSave(
    _ record: WorkspaceRecord
  ) -> Task<Result<Void, WorkspaceFailure>, Never> {
    pendingPersistenceCount += 1
    persistenceGeneration &+= 1
    let generation = persistenceGeneration
    let previous = persistenceTail
    let repository = repository
    let task = Task<Result<Void, WorkspaceFailure>, Never> {
      if let previous {
        _ = await previous.value
      }
      let result: Result<Void, WorkspaceFailure>
      do {
        try await repository.save(record)
        result = .success(())
      } catch {
        result = .failure(WorkspaceFailure())
      }
      self.finishedPersistence(result, generation: generation)
      return result
    }
    persistenceTail = task
    return task
  }

  private func finishedPersistence(
    _ result: Result<Void, WorkspaceFailure>,
    generation: UInt64
  ) {
    pendingPersistenceCount -= 1
    completedPersistenceGeneration = max(
      completedPersistenceGeneration,
      generation
    )
    switch result {
    case .success where pendingPersistenceCount == 0:
      WorkspaceFeature.reduce(
        state: &state,
        action: .persisted(.success(()))
      )
    case .failure:
      WorkspaceFeature.reduce(
        state: &state,
        action: .persisted(.failure(WorkspaceFailure()))
      )
    case .success:
      break
    }
  }
}
