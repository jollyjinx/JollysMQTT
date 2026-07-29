import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

public struct HistoryContext: Equatable, Sendable {
  public let brokerID: UUID
  public let historySourceID: String
  public let current: PayloadMessage

  public init(
    brokerID: UUID,
    historySourceID: String,
    current: PayloadMessage
  ) {
    self.brokerID = brokerID
    self.historySourceID = historySourceID
    self.current = current
  }

  fileprivate var scope: HistoryScope {
    HistoryScope(
      brokerID: brokerID,
      historySourceID: historySourceID,
      topic: current.topicID.fullTopic
    )
  }
}

private struct HistoryScope: Equatable, Sendable {
  let brokerID: UUID
  let historySourceID: String
  let topic: String
}

public struct HistoryRow: Equatable, Identifiable, Sendable {
  public var id: Int64 { message.durableOrder }
  public let message: StoredHistoryMessage
  public let elapsedToNewerMicroseconds: Int64?

  public init(
    message: StoredHistoryMessage,
    elapsedToNewerMicroseconds: Int64?
  ) {
    self.message = message
    self.elapsedToNewerMicroseconds = elapsedToNewerMicroseconds
  }
}

public struct HistoryComparisonRequest: Equatable, Sendable {
  public let requestID: UInt64
  public let selectionRevision: UInt64
  public let current: PayloadComparisonOperand
  public let baseline: PayloadComparisonOperand
}

public struct HistoryPagePosition: Equatable, Sendable {
  public let beforeDurableOrder: Int64?
  public let boundaryNewerTimestamp: Int64

  public init(
    beforeDurableOrder: Int64?,
    boundaryNewerTimestamp: Int64
  ) {
    self.beforeDurableOrder = beforeDurableOrder
    self.boundaryNewerTimestamp = boundaryNewerTimestamp
  }
}

private enum PendingHistoryPageNavigation: Equatable, Sendable {
  case reset
  case older(
    previous: HistoryPagePosition,
    target: HistoryPagePosition
  )
  case newer(target: HistoryPagePosition)
}

public enum HistoryCopyOutcome: Equatable, Sendable {
  case succeeded(Int64)
  case failed(Int64)
}

public enum HistoryFeature {
  public struct State: Equatable, Sendable {
    public fileprivate(set) var context: HistoryContext?
    public fileprivate(set) var rows: [HistoryRow]
    public fileprivate(set) var coverageGaps: [StoredHistoryCoverageGap]
    public fileprivate(set) var selectedBaselineID: Int64?
    public fileprivate(set) var defaultBaseline: PayloadComparisonOperand?
    public fileprivate(set) var comparison: PayloadComparison?
    public fileprivate(set) var nextCursor: Int64?
    public fileprivate(set) var currentPagePosition: HistoryPagePosition?
    public fileprivate(set) var newerPagePositions: [HistoryPagePosition]
    public fileprivate(set) var isLoading: Bool
    public fileprivate(set) var loadError: Bool
    public fileprivate(set) var copyOutcome: HistoryCopyOutcome?
    public let pageSize: Int
    fileprivate var pageRequestID: UInt64
    fileprivate var comparisonRequestID: UInt64
    fileprivate var selectionRevision: UInt64
    fileprivate var pendingPageNavigation: PendingHistoryPageNavigation?

    public init(pageSize: Int = 50) {
      precondition(pageSize >= 2)
      self.context = nil
      self.rows = []
      self.coverageGaps = []
      self.selectedBaselineID = nil
      self.defaultBaseline = nil
      self.comparison = nil
      self.nextCursor = nil
      self.currentPagePosition = nil
      self.newerPagePositions = []
      self.isLoading = false
      self.loadError = false
      self.copyOutcome = nil
      self.pageSize = pageSize
      self.pageRequestID = 0
      self.comparisonRequestID = 0
      self.selectionRevision = 0
      self.pendingPageNavigation = nil
    }

    public var effectiveBaselineID: PayloadComparisonOperandID? {
      if let selectedBaselineID {
        return .durable(selectedBaselineID)
      }
      return defaultBaseline?.id
    }

    public var canLoadNewer: Bool {
      !newerPagePositions.isEmpty
    }
  }

  public enum Intent: Equatable, Sendable {
    case contextChanged(HistoryContext?)
    case loadOlder
    case loadNewer
    case toggleBaseline(Int64)
    case copy(Int64)
    case dismissCopyOutcome
  }

  public enum Action: Equatable, Sendable {
    case pageLoaded(
      requestID: UInt64,
      request: HistoryPageRequest,
      page: HistoryPage
    )
    case pageFailed(requestID: UInt64)
    case comparisonFinished(
      requestID: UInt64,
      selectionRevision: UInt64,
      comparison: PayloadComparison
    )
  }

  public enum Effect: Equatable, Sendable {
    case loadPage(requestID: UInt64, request: HistoryPageRequest)
    case compare(HistoryComparisonRequest)
    case copy(durableOrder: Int64, payload: Data)
  }

  public static func reduce(
    state: inout State,
    intent: Intent
  ) -> Effect? {
    switch intent {
    case .contextChanged(let context):
      guard context != state.context else { return nil }
      if let previous = state.context,
        let context,
        previous.scope == context.scope
      {
        state.context = context
        state.comparisonRequestID &+= 1
        state.selectionRevision &+= 1
        state.comparison = nil
        state.defaultBaseline = PayloadComparisonOperand(previous.current)
        if state.currentPagePosition?.beforeDurableOrder == nil {
          state.currentPagePosition = HistoryPagePosition(
            beforeDurableOrder: nil,
            boundaryNewerTimestamp:
              context.current.receivedAtMicroseconds
          )
          state.rows = rows(
            messages: state.rows.map(\.message),
            boundaryNewerTimestamp:
              context.current.receivedAtMicroseconds
          )
        }
        return comparisonEffect(state: &state)
      }
      state.pageRequestID &+= 1
      state.comparisonRequestID &+= 1
      state.selectionRevision &+= 1
      state.context = context
      state.rows = []
      state.coverageGaps = []
      state.selectedBaselineID = nil
      state.defaultBaseline = nil
      state.comparison = nil
      state.nextCursor = nil
      state.currentPagePosition = nil
      state.newerPagePositions = []
      state.pendingPageNavigation = nil
      state.loadError = false
      state.copyOutcome = nil
      guard let context else {
        state.isLoading = false
        return nil
      }
      state.isLoading = true
      state.pendingPageNavigation = .reset
      return .loadPage(
        requestID: state.pageRequestID,
        request: HistoryPageRequest(
          historySourceID: context.historySourceID,
          topic: context.current.topicID.fullTopic,
          limit: state.pageSize
        )
      )

    case .loadOlder:
      guard let context = state.context,
        let nextCursor = state.nextCursor,
        !state.isLoading,
        let currentPosition = state.currentPagePosition,
        let boundary = state.rows.last?.message.receivedAtMicroseconds
      else {
        return nil
      }
      state.pageRequestID &+= 1
      state.isLoading = true
      state.loadError = false
      let target = HistoryPagePosition(
        beforeDurableOrder: nextCursor,
        boundaryNewerTimestamp: boundary
      )
      state.pendingPageNavigation = .older(
        previous: currentPosition,
        target: target
      )
      return .loadPage(
        requestID: state.pageRequestID,
        request: HistoryPageRequest(
          historySourceID: context.historySourceID,
          topic: context.current.topicID.fullTopic,
          beforeDurableOrder: nextCursor,
          limit: state.pageSize
        )
      )

    case .loadNewer:
      guard let context = state.context,
        let target = state.newerPagePositions.last,
        !state.isLoading
      else {
        return nil
      }
      state.pageRequestID &+= 1
      state.isLoading = true
      state.loadError = false
      state.pendingPageNavigation = .newer(target: target)
      return .loadPage(
        requestID: state.pageRequestID,
        request: HistoryPageRequest(
          historySourceID: context.historySourceID,
          topic: context.current.topicID.fullTopic,
          beforeDurableOrder: target.beforeDurableOrder,
          limit: state.pageSize
        )
      )

    case .toggleBaseline(let durableOrder):
      guard
        let baseline = state.rows.first(where: {
          $0.id == durableOrder
        })?.message,
        baseline.hasStoredPayload
      else {
        return nil
      }
      state.selectedBaselineID =
        state.selectedBaselineID == durableOrder ? nil : durableOrder
      state.selectionRevision &+= 1
      state.comparison = nil
      return comparisonEffect(state: &state, fallback: baseline)

    case .copy(let durableOrder):
      guard
        let message = state.rows.first(where: {
          $0.id == durableOrder
        })?.message,
        message.hasStoredPayload
      else {
        return nil
      }
      state.copyOutcome = nil
      return .copy(
        durableOrder: durableOrder,
        payload: message.payload
      )

    case .dismissCopyOutcome:
      state.copyOutcome = nil
      return nil
    }
  }

  public static func reduce(
    state: inout State,
    action: Action
  ) -> Effect? {
    switch action {
    case .pageLoaded(let requestID, let request, let page):
      guard requestID == state.pageRequestID,
        let context = state.context,
        request.historySourceID == context.historySourceID,
        request.topic == context.current.topicID.fullTopic
      else {
        return nil
      }
      state.isLoading = false
      state.loadError = false
      let boundaryNewerTimestamp: Int64
      switch state.pendingPageNavigation {
      case .reset:
        let position = HistoryPagePosition(
          beforeDurableOrder: nil,
          boundaryNewerTimestamp:
            context.current.receivedAtMicroseconds
        )
        state.currentPagePosition = position
        state.newerPagePositions = []
        boundaryNewerTimestamp = position.boundaryNewerTimestamp
      case .older(let previous, let target):
        state.newerPagePositions.append(previous)
        state.currentPagePosition = target
        boundaryNewerTimestamp = target.boundaryNewerTimestamp
      case .newer(let target):
        _ = state.newerPagePositions.popLast()
        let adjustedTarget =
          target.beforeDurableOrder == nil
          ? HistoryPagePosition(
            beforeDurableOrder: nil,
            boundaryNewerTimestamp:
              context.current.receivedAtMicroseconds
          )
          : target
        state.currentPagePosition = adjustedTarget
        boundaryNewerTimestamp =
          adjustedTarget.boundaryNewerTimestamp
      case .none:
        return nil
      }
      state.pendingPageNavigation = nil
      state.rows = rows(
        messages: page.messages,
        boundaryNewerTimestamp: boundaryNewerTimestamp
      )
      state.coverageGaps = page.coverageGaps
      state.nextCursor = page.nextCursor
      state.selectedBaselineID = nil
      state.selectionRevision &+= 1
      if request.beforeDurableOrder == nil {
        if let defaultBaseline = state.defaultBaseline,
          case .live = defaultBaseline.id
        {
          // A newer live delivery arrived while this page was loading.
        } else {
          state.defaultBaseline = page.messages.first {
            $0.hasStoredPayload
              && !matchesCurrent($0, current: context.current)
          }.flatMap(operand)
        }
      }
      state.comparison = nil
      return comparisonEffect(state: &state)

    case .pageFailed(let requestID):
      guard requestID == state.pageRequestID else { return nil }
      state.isLoading = false
      state.loadError = true
      state.pendingPageNavigation = nil
      return nil

    case .comparisonFinished(
      let requestID,
      let selectionRevision,
      let comparison
    ):
      guard requestID == state.comparisonRequestID,
        selectionRevision == state.selectionRevision,
        comparison.currentID
          == state.context.map({
            .live($0.current.id)
          }),
        comparison.baselineID == state.effectiveBaselineID
      else {
        return nil
      }
      state.comparison = comparison
      return nil
    }
  }

  private static func comparisonEffect(
    state: inout State,
    fallback: StoredHistoryMessage? = nil
  ) -> Effect? {
    guard let context = state.context else { return nil }
    let baseline: PayloadComparisonOperand? =
      state.selectedBaselineID.flatMap { selected in
        state.rows.first(where: { $0.id == selected })?.message
      }.flatMap(operand)
      ?? state.defaultBaseline
      ?? fallback.flatMap(operand)
    guard let baseline else { return nil }
    state.comparisonRequestID &+= 1
    return .compare(
      HistoryComparisonRequest(
        requestID: state.comparisonRequestID,
        selectionRevision: state.selectionRevision,
        current: PayloadComparisonOperand(context.current),
        baseline: baseline
      )
    )
  }

  private static func operand(
    _ message: StoredHistoryMessage
  ) -> PayloadComparisonOperand? {
    guard message.hasStoredPayload else { return nil }
    return PayloadComparisonOperand(
      id: .durable(message.durableOrder),
      direction: message.direction,
      payload: message.payload
    )
  }

  private static func matchesCurrent(
    _ stored: StoredHistoryMessage,
    current: PayloadMessage
  ) -> Bool {
    stored.direction == current.direction
      && stored.connectionEpoch == current.id.connectionEpoch.rawValue
      && stored.connectionOrdinal == current.id.ordinal
  }

  private static func rows(
    messages: [StoredHistoryMessage],
    boundaryNewerTimestamp: Int64
  ) -> [HistoryRow] {
    messages.enumerated().map { index, message in
      let newerTimestamp =
        index == 0
        ? boundaryNewerTimestamp
        : messages[index - 1].receivedAtMicroseconds
      return HistoryRow(
        message: message,
        elapsedToNewerMicroseconds: {
          let (elapsed, overflow) =
            newerTimestamp.subtractingReportingOverflow(
              message.receivedAtMicroseconds
            )
          return !overflow && elapsed >= 0 ? elapsed : nil
        }()
      )
    }
  }
}

public struct BrokerHistoryRepositoryProvider: Sendable {
  public static let empty = BrokerHistoryRepositoryProvider { _ in
    EmptyBrokerHistoryRepository()
  }

  private let operation: @Sendable (UUID) -> any BrokerHistoryReading

  public init(
    _ operation:
      @escaping @Sendable (UUID) -> any BrokerHistoryReading
  ) {
    self.operation = operation
  }

  public func repository(
    for brokerID: UUID
  ) -> any BrokerHistoryReading {
    operation(brokerID)
  }
}

private actor EmptyBrokerHistoryRepository: BrokerHistoryReading {
  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }
}

public struct BrokerHistoryMaintenanceProvider: Sendable {
  public static let empty = BrokerHistoryMaintenanceProvider { _ in
    EmptyBrokerHistoryMaintenance()
  }

  private let operation: @Sendable (UUID) -> any BrokerHistoryMaintaining

  public init(
    _ operation:
      @escaping @Sendable (UUID) -> any BrokerHistoryMaintaining
  ) {
    self.operation = operation
  }

  public func repository(
    for brokerID: UUID
  ) -> any BrokerHistoryMaintaining {
    operation(brokerID)
  }
}

private actor EmptyBrokerHistoryMaintenance:
  BrokerHistoryMaintaining
{
  func retentionPolicy() -> HistoryRetentionPolicy { .default }
  func maintenanceStatus() -> HistoryMaintenanceStatus { .notRun }
  func applyRetention() -> HistoryMaintenanceReport {
    HistoryMaintenanceReport(
      deletedForTopicLimit: 0,
      deletedForBrokerLimit: 0,
      deletedOrphanTopicCount: 0,
      finalMessageCount: 0,
      finalSQLiteBytes: 0
    )
  }
  func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) -> HistoryClearOutcome {
    HistoryClearOutcome(
      summary: HistoryClearSummary(
        deletedMessageCount: 0,
        deletedTopicCount: 0,
        deletedCoverageGapCount: 0,
        secureCleanupStatus: .completed
      )
    )
  }
  func clearBrokerHistory() -> HistoryClearOutcome {
    HistoryClearOutcome(
      summary: HistoryClearSummary(
        deletedMessageCount: 0,
        deletedTopicCount: 0,
        deletedCoverageGapCount: 0,
        secureCleanupStatus: .completed
      )
    )
  }
  func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) -> HistoryClearOutcome {
    HistoryClearOutcome(
      summary: HistoryClearSummary(
        deletedMessageCount: 0,
        deletedTopicCount: 0,
        deletedCoverageGapCount: 0,
        secureCleanupStatus: .completed
      )
    )
  }
  func retrySecureCleanup() {}
}

@MainActor
@Observable
public final class HistoryStore {
  public private(set) var state: HistoryFeature.State

  private let repositories: BrokerHistoryRepositoryProvider
  private let comparer: any PayloadComparing
  private let clipboard: any PayloadClipboardWriting
  private var pageTask: Task<Void, Never>?
  private var comparisonTask: Task<Void, Never>?

  public init(
    repositories: BrokerHistoryRepositoryProvider = .empty,
    comparer: any PayloadComparing = PayloadComparisonEngine(),
    clipboard: any PayloadClipboardWriting = ApplePayloadClipboard(),
    pageSize: Int = 50
  ) {
    self.repositories = repositories
    self.comparer = comparer
    self.clipboard = clipboard
    self.state = .init(pageSize: pageSize)
  }

  public func updateContext(_ context: HistoryContext?) {
    send(.contextChanged(context))
  }

  public func reload() {
    guard let context = state.context else { return }
    send(.contextChanged(nil))
    send(.contextChanged(context))
  }

  public func send(_ intent: HistoryFeature.Intent) {
    if case .contextChanged(let context) = intent {
      if state.context?.scope != context?.scope {
        pageTask?.cancel()
        pageTask = nil
      }
      if state.context != context {
        comparisonTask?.cancel()
        comparisonTask = nil
      }
    } else if case .toggleBaseline = intent {
      comparisonTask?.cancel()
      comparisonTask = nil
    }
    let effect = HistoryFeature.reduce(state: &state, intent: intent)
    perform(effect)
  }

  private func perform(_ effect: HistoryFeature.Effect?) {
    guard let effect else { return }
    switch effect {
    case .loadPage(let requestID, let request):
      guard let brokerID = state.context?.brokerID else { return }
      let repository = repositories.repository(for: brokerID)
      pageTask = Task { [weak self] in
        do {
          let page = try await repository.page(request)
          guard !Task.isCancelled, let self else { return }
          let next = HistoryFeature.reduce(
            state: &state,
            action: .pageLoaded(
              requestID: requestID,
              request: request,
              page: page
            )
          )
          perform(next)
        } catch is CancellationError {
          return
        } catch {
          guard !Task.isCancelled, let self else { return }
          _ = HistoryFeature.reduce(
            state: &state,
            action: .pageFailed(requestID: requestID)
          )
        }
      }

    case .compare(let request):
      let comparer = comparer
      comparisonTask = Task { [weak self] in
        let comparison = await comparer.compare(
          current: request.current,
          baseline: request.baseline
        )
        guard !Task.isCancelled, let self else { return }
        _ = HistoryFeature.reduce(
          state: &state,
          action: .comparisonFinished(
            requestID: request.requestID,
            selectionRevision: request.selectionRevision,
            comparison: comparison
          )
        )
      }

    case .copy(let durableOrder, let payload):
      do {
        try clipboard.write(.rawBytes(payload))
        state.copyOutcome = .succeeded(durableOrder)
      } catch {
        state.copyOutcome = .failed(durableOrder)
      }
    }
  }
}
