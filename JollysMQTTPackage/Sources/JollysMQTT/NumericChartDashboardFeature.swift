import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

public enum NumericChartDashboardFeature {
  public struct State: Equatable, Sendable {
    public fileprivate(set) var configuration: NumericChartDashboardConfiguration

    public init(
      configuration: NumericChartDashboardConfiguration = .init()
    ) {
      self.configuration = configuration
    }

    public var cards: [NumericChartCardConfiguration] {
      configuration.cards
    }
  }

  public enum MoveDirection: Equatable, Sendable {
    case earlier
    case later
  }

  public enum Intent: Equatable, Sendable {
    case setPresentationStyle(
      NumericChartCardID,
      NumericChartPresentationStyle
    )
    case setColor(NumericChartCardID, NumericChartColor)
    case setGridSpan(NumericChartCardID, NumericChartGridSpan)
    case move(NumericChartCardID, MoveDirection)
    case remove(NumericChartCardID)
  }
}

@MainActor
@Observable
public final class NumericChartDashboardStore {
  public private(set) var state: NumericChartDashboardFeature.State

  public var onConfigurationChange:
    (@MainActor @Sendable (NumericChartDashboardConfiguration) -> Void)?

  private let repositories: BrokerHistoryRepositoryProvider
  private let policy: NumericChartDashboardPolicy
  private let loadLimiter: NumericChartHistoryLoadLimiter
  private var stores: [NumericChartCardID: NumericChartStore] = [:]
  private var callbackTokens: [NumericChartCardID: UUID] = [:]
  private var lastSnapshot: BrokerTopicTreeSnapshot?
  private var lastExpectedBrokerID: UUID?

  public init(
    repositories: BrokerHistoryRepositoryProvider = .empty,
    policy: NumericChartDashboardPolicy = .default
  ) {
    self.repositories = repositories
    self.policy = policy
    self.loadLimiter = NumericChartHistoryLoadLimiter(
      maximumConcurrentLoads: policy.maximumConcurrentHistoryLoads
    )
    self.state = .init()
  }

  public var maximumCardCount: Int {
    policy.maximumCardCount
  }

  public var aggregateRawSampleCount: Int {
    stores.values.reduce(into: 0) {
      $0 += $1.state.samples.count
    }
  }

  public var aggregateDisplaySampleCount: Int {
    stores.values.reduce(into: 0) {
      $0 += $1.state.displaySamples.count
    }
  }

  public var aggregateHistoryMessageCountExamined: Int {
    stores.values.reduce(into: 0) {
      $0 += $1.state.historyMessageCountExamined
    }
  }

  public func cardStore(for id: NumericChartCardID) -> NumericChartStore? {
    stores[id]
  }

  public func restore(
    _ configuration: NumericChartDashboardConfiguration
  ) {
    let normalized = configuration.normalized(
      maximumCardCount: policy.maximumCardCount
    )
    for store in stores.values {
      store.onConfigurationChange = nil
    }
    stores.removeAll(keepingCapacity: true)
    callbackTokens.removeAll(keepingCapacity: true)
    state = .init(configuration: normalized)

    for card in normalized.cards {
      installStore(for: card)
    }
  }

  @discardableResult
  public func pin(
    _ series: NumericChartSeries,
    id: NumericChartCardID = NumericChartCardID()
  ) -> Bool {
    guard state.configuration.cards.count < policy.maximumCardCount,
      stores[id] == nil
    else {
      return false
    }
    let card = NumericChartCardConfiguration(
      id: id,
      chart: NumericChartConfiguration(series: series)
    )
    state.configuration.cards.append(card)
    installStore(for: card)
    onConfigurationChange?(state.configuration)
    return true
  }

  public func updateSnapshot(
    _ snapshot: BrokerTopicTreeSnapshot,
    expectedBrokerID: UUID?
  ) {
    lastSnapshot = snapshot
    lastExpectedBrokerID = expectedBrokerID
    for card in state.configuration.cards {
      stores[card.id]?.updateSnapshot(
        snapshot,
        expectedBrokerID: expectedBrokerID
      )
    }
  }

  public func send(_ intent: NumericChartDashboardFeature.Intent) {
    switch intent {
    case .setPresentationStyle(let id, let style):
      updateCard(id) {
        guard $0.presentationStyle != style else { return false }
        $0.presentationStyle = style
        return true
      }

    case .setColor(let id, let color):
      updateCard(id) {
        guard $0.color != color else { return false }
        $0.color = color
        return true
      }

    case .setGridSpan(let id, let span):
      updateCard(id) {
        guard $0.gridSpan != span else { return false }
        $0.gridSpan = span
        return true
      }

    case .move(let id, let direction):
      guard
        let source = state.configuration.cards.firstIndex(where: {
          $0.id == id
        })
      else {
        return
      }
      let destination: Int
      switch direction {
      case .earlier:
        destination = source - 1
      case .later:
        destination = source + 1
      }
      guard state.configuration.cards.indices.contains(destination) else {
        return
      }
      state.configuration.cards.swapAt(source, destination)
      onConfigurationChange?(state.configuration)

    case .remove(let id):
      guard
        let index = state.configuration.cards.firstIndex(where: {
          $0.id == id
        })
      else {
        return
      }
      callbackTokens[id] = nil
      if let store = stores.removeValue(forKey: id) {
        store.onConfigurationChange = nil
        store.restore(nil)
      }
      state.configuration.cards.remove(at: index)
      onConfigurationChange?(state.configuration)
    }
  }

  public func containsSeries(_ series: NumericChartSeries) -> Bool {
    state.configuration.cards.contains {
      NumericChartPinStateEvaluator.isPinned(
        candidate: series,
        pinnedSeries: $0.chart.series
      )
    }
  }

  private func installStore(for card: NumericChartCardConfiguration) {
    let token = UUID()
    let store = NumericChartStore(
      repositories: repositories,
      policy: policy.cardPolicy,
      loadLimiter: loadLimiter
    )
    callbackTokens[card.id] = token
    stores[card.id] = store
    store.onConfigurationChange = { [weak self] configuration in
      guard let self,
        callbackTokens[card.id] == token,
        let configuration,
        let index = state.configuration.cards.firstIndex(where: {
          $0.id == card.id
        })
      else {
        return
      }
      guard state.configuration.cards[index].chart != configuration else {
        return
      }
      state.configuration.cards[index].chart = configuration
      onConfigurationChange?(state.configuration)
    }
    store.restore(card.chart)
    if let lastSnapshot {
      store.updateSnapshot(
        lastSnapshot,
        expectedBrokerID: lastExpectedBrokerID
      )
    }
  }

  private func updateCard(
    _ id: NumericChartCardID,
    mutation: (inout NumericChartCardConfiguration) -> Bool
  ) {
    guard
      let index = state.configuration.cards.firstIndex(where: {
        $0.id == id
      }),
      mutation(&state.configuration.cards[index])
    else {
      return
    }
    onConfigurationChange?(state.configuration)
  }
}
