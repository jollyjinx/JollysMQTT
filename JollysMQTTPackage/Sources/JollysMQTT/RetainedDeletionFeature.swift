import Foundation
import JollysMQTTCore
import Observation

public struct RetainedDeletionContext: Equatable, Sendable {
  public let brokerID: UUID
  public let connectionEpoch: ConnectionEpochID
  public let selectedTopic: String?
  public let selectedHasCurrentValue: Bool

  public init(
    brokerID: UUID,
    connectionEpoch: ConnectionEpochID,
    selectedTopic: String?,
    selectedHasCurrentValue: Bool
  ) {
    self.brokerID = brokerID
    self.connectionEpoch = connectionEpoch
    self.selectedTopic = selectedTopic
    self.selectedHasCurrentValue = selectedHasCurrentValue
  }
}

public enum RetainedDeletionScope: Equatable, Sendable {
  case single(topic: String)
  case subtree(rootTopic: String)
  case retryableRemainder(rootTopic: String)
}

public enum RetainedDeletionAccessibilityTarget: Equatable, Sendable {
  case exactTopic(String)
  case exactCount(Int)
}

public struct RetainedDeletionConfirmation: Equatable, Sendable {
  public let brokerID: UUID
  public let connectionEpoch: ConnectionEpochID
  public let scope: RetainedDeletionScope
  public let topics: [String]

  public var topicCount: Int { topics.count }
  public let isDestructive = true

  public var accessibilityTarget: RetainedDeletionAccessibilityTarget {
    switch scope {
    case .single(let topic):
      .exactTopic(topic)
    case .subtree, .retryableRemainder:
      .exactCount(topicCount)
    }
  }

  public init(
    brokerID: UUID,
    connectionEpoch: ConnectionEpochID,
    scope: RetainedDeletionScope,
    topics: [String]
  ) {
    self.brokerID = brokerID
    self.connectionEpoch = connectionEpoch
    self.scope = scope
    self.topics = Self.normalized(topics)
  }

  fileprivate static func normalized(_ topics: [String]) -> [String] {
    var topicsByUTF8: [[UInt8]: String] = [:]
    for topic in topics {
      topicsByUTF8[Array(topic.utf8)] = topic
    }
    return
      topicsByUTF8
      .sorted { lhs, rhs in
        lhs.key.lexicographicallyPrecedes(rhs.key)
      }
      .map(\.value)
  }
}

public enum RetainedDeletionTopicStatus: Equatable, Sendable {
  case pending
  case publishing
  case succeeded(BrokerPublishSuccess)
  case failed(BrokerPublishFailure)
}

public struct RetainedDeletionTopicOperation:
  Equatable,
  Identifiable,
  Sendable
{
  public var id: PublishOperationID { operationID }
  public let topic: String
  public let operationID: PublishOperationID
  public fileprivate(set) var status: RetainedDeletionTopicStatus
}

public enum RetainedDeletionOperationPhase: Equatable, Sendable {
  case running
  case cancelling
  case finished
  case cancelled
}

public struct RetainedDeletionOperation: Equatable, Sendable {
  public let brokerID: UUID
  public let connectionEpoch: ConnectionEpochID
  public let scope: RetainedDeletionScope
  public fileprivate(set) var topics: [RetainedDeletionTopicOperation]
  public fileprivate(set) var phase: RetainedDeletionOperationPhase
  fileprivate var nextPendingIndex: Int
  fileprivate var currentTopicIndex: Int?
  public fileprivate(set) var completedTopicCount: Int

  public var completedTopics: [String] {
    topics.compactMap {
      if case .succeeded = $0.status { $0.topic } else { nil }
    }
  }

  public var currentTopic: String? {
    currentTopicIndex.map { topics[$0].topic }
  }

  public var retryableTopics: [String] {
    topics.compactMap {
      switch $0.status {
      case .pending, .failed:
        $0.topic
      case .publishing, .succeeded:
        nil
      }
    }
  }

  public var isActive: Bool {
    phase == .running || phase == .cancelling
  }

  fileprivate mutating func record(
    operationID: PublishOperationID,
    result: BrokerPublishResult
  ) -> Bool {
    guard isActive,
      let index = currentTopicIndex,
      topics[index].operationID == operationID,
      topics[index].status == .publishing
    else {
      return false
    }
    currentTopicIndex = nil
    switch result {
    case .success(let success):
      if success.operationID == operationID,
        success.completion == .acknowledged
      {
        topics[index].status = .succeeded(success)
        completedTopicCount += 1
      } else {
        topics[index].status = .failed(.transportUnavailable)
      }
    case .failure(let failure):
      topics[index].status = .failed(failure)
    }
    return true
  }

  fileprivate mutating func nextRequest() -> BrokerPublishRequest? {
    guard phase == .running else { return nil }
    var index = nextPendingIndex
    while index < topics.count,
      topics[index].status != .pending
    {
      index += 1
    }
    guard index < topics.count else { return nil }
    topics[index].status = .publishing
    nextPendingIndex = index + 1
    currentTopicIndex = index
    let topic = topics[index]
    return BrokerPublishRequest(
      operationID: topic.operationID,
      topic: topic.topic,
      payload: Data(),
      qos: .atLeastOnce,
      retain: true,
      expectedBrokerID: brokerID,
      expectedConnectionEpoch: connectionEpoch
    )
  }
}

public enum RetainedDeletionFeature {
  public struct State: Equatable, Sendable {
    public fileprivate(set) var context: RetainedDeletionContext?
    public fileprivate(set) var confirmation: RetainedDeletionConfirmation?
    public fileprivate(set) var operation: RetainedDeletionOperation?
    public fileprivate(set) var reconfirmationUnavailable: Bool
    public fileprivate(set) var targetEnumerationEmpty: Bool

    public init(
      context: RetainedDeletionContext? = nil,
      confirmation: RetainedDeletionConfirmation? = nil,
      operation: RetainedDeletionOperation? = nil,
      reconfirmationUnavailable: Bool = false,
      targetEnumerationEmpty: Bool = false
    ) {
      self.context = context
      self.confirmation = confirmation
      self.operation = operation
      self.reconfirmationUnavailable = reconfirmationUnavailable
      self.targetEnumerationEmpty = targetEnumerationEmpty
    }

    public var canDeleteSingle: Bool {
      context?.selectedHasCurrentValue == true
    }

    public var canDeleteSubtree: Bool {
      context?.selectedTopic != nil
    }

    public var canRetryCurrentAuthorization: Bool {
      guard let context, let operation, !operation.retryableTopics.isEmpty else {
        return false
      }
      return context.brokerID == operation.brokerID
        && context.connectionEpoch == operation.connectionEpoch
    }

    public var canReconfirmRetryableRemainder: Bool {
      guard let context, let operation,
        context.brokerID == operation.brokerID,
        context.connectionEpoch != operation.connectionEpoch
      else {
        return false
      }
      return !operation.retryableTopics.isEmpty
    }
  }

  public enum Intent: Equatable, Sendable {
    case contextChanged(RetainedDeletionContext?)
    case requestSingleDeletion(topics: [String])
    case requestSubtreeDeletion(topics: [String])
    case dismissConfirmation
    case confirm(operationIDs: [PublishOperationID])
    case cancel
    case retry(operationIDs: [PublishOperationID])
    case reconfirmRetryableRemainder(currentTopics: [String])
    case dismissReport
  }

  public enum Action: Equatable, Sendable {
    case publishFinished(
      operationID: PublishOperationID,
      result: BrokerPublishResult
    )
  }

  public enum Effect: Equatable, Sendable {
    case publish(BrokerPublishRequest)
  }

  public static func reduce(
    state: inout State,
    intent: Intent
  ) -> Effect? {
    switch intent {
    case .contextChanged(let context):
      let previousAuthorization = state.context.map {
        ($0.brokerID, $0.connectionEpoch)
      }
      let nextAuthorization = context.map {
        ($0.brokerID, $0.connectionEpoch)
      }
      let authorizationChanged =
        previousAuthorization?.0 != nextAuthorization?.0
        || previousAuthorization?.1 != nextAuthorization?.1
      let selectionChanged =
        state.context?.selectedTopic != context?.selectedTopic
      state.context = context
      if authorizationChanged {
        state.confirmation = nil
        if state.operation?.isActive == true {
          state.operation?.phase = .cancelling
        }
      }
      if selectionChanged {
        state.confirmation = nil
      }
      if authorizationChanged || selectionChanged {
        state.reconfirmationUnavailable = false
        state.targetEnumerationEmpty = false
      }
      return nil

    case .requestSingleDeletion(let topics):
      state.targetEnumerationEmpty = false
      guard state.operation?.isActive != true,
        let context = state.context,
        let selectedTopic = context.selectedTopic,
        context.selectedHasCurrentValue
      else {
        return nil
      }
      let exactTopic = topics.first {
        Array($0.utf8) == Array(selectedTopic.utf8)
      }
      guard exactTopic != nil,
        MQTTTopicValidator.isValidPublicationTopic(selectedTopic)
      else {
        state.targetEnumerationEmpty = true
        return nil
      }
      state.confirmation = RetainedDeletionConfirmation(
        brokerID: context.brokerID,
        connectionEpoch: context.connectionEpoch,
        scope: .single(topic: selectedTopic),
        topics: [selectedTopic]
      )
      return nil

    case .requestSubtreeDeletion(let topics):
      state.targetEnumerationEmpty = false
      guard state.operation?.isActive != true,
        let context = state.context,
        let selectedTopic = context.selectedTopic
      else {
        return nil
      }
      let scopedTopics = validDeletionTopics(
        topics,
        rootTopic: selectedTopic
      )
      guard !scopedTopics.isEmpty else {
        state.targetEnumerationEmpty = true
        return nil
      }
      state.confirmation = RetainedDeletionConfirmation(
        brokerID: context.brokerID,
        connectionEpoch: context.connectionEpoch,
        scope: .subtree(rootTopic: selectedTopic),
        topics: scopedTopics
      )
      return nil

    case .dismissConfirmation:
      state.confirmation = nil
      return nil

    case .confirm(let operationIDs):
      guard let confirmation = state.confirmation,
        !confirmation.topics.isEmpty,
        confirmationTopicsAreAuthorized(confirmation),
        operationIDs.count == confirmation.topics.count,
        Set(operationIDs).count == operationIDs.count
      else {
        return nil
      }
      state.confirmation = nil
      state.operation = RetainedDeletionOperation(
        brokerID: confirmation.brokerID,
        connectionEpoch: confirmation.connectionEpoch,
        scope: confirmation.scope,
        topics: zip(confirmation.topics, operationIDs).map {
          RetainedDeletionTopicOperation(
            topic: $0,
            operationID: $1,
            status: .pending
          )
        },
        phase: .running,
        nextPendingIndex: 0,
        currentTopicIndex: nil,
        completedTopicCount: 0
      )
      return startNextPublish(state: &state)

    case .cancel:
      guard state.operation?.phase == .running else { return nil }
      state.operation?.phase = .cancelling
      return nil

    case .retry(let operationIDs):
      guard let previous = state.operation,
        !previous.isActive
      else {
        return nil
      }
      let retryable = previous.retryableTopics
      guard !retryable.isEmpty,
        retryable.count == operationIDs.count,
        Set(operationIDs).count == operationIDs.count,
        state.context?.brokerID == previous.brokerID,
        state.context?.connectionEpoch == previous.connectionEpoch
      else {
        return nil
      }
      var retryIDIterator = operationIDs.makeIterator()
      state.operation = RetainedDeletionOperation(
        brokerID: previous.brokerID,
        connectionEpoch: previous.connectionEpoch,
        scope: previous.scope,
        topics: previous.topics.compactMap { topic in
          if case .succeeded = topic.status {
            return topic
          }
          guard let retryID = retryIDIterator.next() else { return nil }
          return RetainedDeletionTopicOperation(
            topic: topic.topic,
            operationID: retryID,
            status: .pending
          )
        },
        phase: .running,
        nextPendingIndex: 0,
        currentTopicIndex: nil,
        completedTopicCount: previous.completedTopicCount
      )
      return startNextPublish(state: &state)

    case .reconfirmRetryableRemainder(let currentTopics):
      state.reconfirmationUnavailable = false
      guard let context = state.context,
        let operation = state.operation,
        !operation.isActive,
        context.brokerID == operation.brokerID,
        context.connectionEpoch != operation.connectionEpoch
      else {
        return nil
      }
      let retryableBytes = Set(
        operation.retryableTopics.map { Array($0.utf8) }
      )
      let currentRetryable = currentTopics.filter {
        retryableBytes.contains(Array($0.utf8))
      }
      let scopedRetryable = validDeletionTopics(
        currentRetryable,
        rootTopic: rootTopic(for: operation.scope)
      )
      guard !scopedRetryable.isEmpty else {
        state.reconfirmationUnavailable = true
        return nil
      }
      let rootTopic = rootTopic(for: operation.scope)
      state.confirmation = RetainedDeletionConfirmation(
        brokerID: context.brokerID,
        connectionEpoch: context.connectionEpoch,
        scope: .retryableRemainder(rootTopic: rootTopic),
        topics: scopedRetryable
      )
      return nil

    case .dismissReport:
      guard state.operation?.isActive != true else { return nil }
      state.operation = nil
      state.reconfirmationUnavailable = false
      state.targetEnumerationEmpty = false
      return nil
    }
  }

  public static func reduce(
    state: inout State,
    action: Action
  ) -> Effect? {
    switch action {
    case .publishFinished(let operationID, let result):
      guard
        state.operation?.record(
          operationID: operationID,
          result: result
        ) == true
      else {
        return nil
      }
      if state.operation?.phase == .cancelling {
        state.operation?.phase = .cancelled
        return nil
      }
      if let effect = startNextPublish(state: &state) {
        return effect
      }
      state.operation?.phase = .finished
      return nil
    }
  }

  private static func startNextPublish(state: inout State) -> Effect? {
    guard let request = state.operation?.nextRequest() else { return nil }
    return .publish(request)
  }

  private static func rootTopic(
    for scope: RetainedDeletionScope
  ) -> String {
    switch scope {
    case .single(let topic):
      topic
    case .subtree(let root), .retryableRemainder(let root):
      root
    }
  }

  private static func validDeletionTopics(
    _ topics: [String],
    rootTopic: String
  ) -> [String] {
    let rootBytes = Array(rootTopic.utf8)
    return RetainedDeletionConfirmation.normalized(topics).filter { topic in
      guard MQTTTopicValidator.isValidPublicationTopic(topic) else {
        return false
      }
      let bytes = Array(topic.utf8)
      if bytes == rootBytes { return true }
      return bytes.count > rootBytes.count
        && bytes.starts(with: rootBytes)
        && bytes[rootBytes.count] == 0x2F
    }
  }

  private static func confirmationTopicsAreAuthorized(
    _ confirmation: RetainedDeletionConfirmation
  ) -> Bool {
    switch confirmation.scope {
    case .single(let topic):
      return confirmation.topics == [topic]
        && MQTTTopicValidator.isValidPublicationTopic(topic)
    case .subtree(let root), .retryableRemainder(let root):
      return validDeletionTopics(
        confirmation.topics,
        rootTopic: root
      ) == confirmation.topics
    }
  }
}

@MainActor
@Observable
public final class RetainedDeletionStore {
  public private(set) var state = RetainedDeletionFeature.State()

  private let publisher: any BrokerPublishing
  private let operationID: @MainActor @Sendable () -> PublishOperationID
  private let targetResolver:
    @MainActor @Sendable (
      BrokerTopicTreeSnapshot,
      BrokerTopicID
    ) -> [String]
  private var latestSnapshot = BrokerTopicTreeSnapshot.empty
  private var publishTask: Task<Void, Never>?

  public init(
    publisher: any BrokerPublishing,
    operationID:
      @escaping @MainActor @Sendable () -> PublishOperationID = {
        PublishOperationID()
      },
    targetResolver:
      @escaping @MainActor @Sendable (
        BrokerTopicTreeSnapshot,
        BrokerTopicID
      ) -> [String] = { snapshot, selection in
        snapshot.locallyKnownCurrentValueTopics(in: selection)
      }
  ) {
    self.publisher = publisher
    self.operationID = operationID
    self.targetResolver = targetResolver
  }

  public func send(_ intent: RetainedDeletionFeature.Intent) {
    run(RetainedDeletionFeature.reduce(state: &state, intent: intent))
  }

  public func confirm() {
    let count = state.confirmation?.topicCount ?? 0
    send(.confirm(operationIDs: makeOperationIDs(count: count)))
  }

  public func retry() {
    let count = state.operation?.retryableTopics.count ?? 0
    send(.retry(operationIDs: makeOperationIDs(count: count)))
  }

  public func requestSingleDeletion() {
    guard let context = state.context else { return }
    send(
      .requestSingleDeletion(
        topics: currentTopics(context: context)
      )
    )
  }

  public func requestSubtreeDeletion() {
    guard let context = state.context else { return }
    send(
      .requestSubtreeDeletion(
        topics: currentTopics(context: context)
      )
    )
  }

  public func reconfirmRetryableRemainder() {
    guard let context = state.context,
      let operation = state.operation
    else { return }
    let rootTopic: String
    switch operation.scope {
    case .single(let topic):
      rootTopic = topic
    case .subtree(let root), .retryableRemainder(let root):
      rootTopic = root
    }
    send(
      .reconfirmRetryableRemainder(
        currentTopics: targetResolver(
          latestSnapshot,
          BrokerTopicID(
            brokerID: context.brokerID,
            fullTopic: rootTopic
          )
        )
      )
    )
  }

  func updateContext(
    _ context: RetainedDeletionContext?,
    snapshot: BrokerTopicTreeSnapshot
  ) {
    latestSnapshot = snapshot
    send(.contextChanged(context))
  }

  func waitForOperationForTesting() async {
    while let task = publishTask {
      await task.value
    }
  }

  private func makeOperationIDs(count: Int) -> [PublishOperationID] {
    (0..<count).map { _ in operationID() }
  }

  private func currentTopics(
    context: RetainedDeletionContext
  ) -> [String] {
    guard let selectedTopic = context.selectedTopic else { return [] }
    return targetResolver(
      latestSnapshot,
      BrokerTopicID(
        brokerID: context.brokerID,
        fullTopic: selectedTopic
      )
    )
  }

  private func run(_ effect: RetainedDeletionFeature.Effect?) {
    guard let effect else { return }
    switch effect {
    case .publish(let request):
      let publisher = publisher
      publishTask = Task { [weak self] in
        let result = await publisher.publish(request)
        guard let self else { return }
        let next = RetainedDeletionFeature.reduce(
          state: &state,
          action: .publishFinished(
            operationID: request.operationID,
            result: result
          )
        )
        publishTask = nil
        run(next)
      }
    }
  }
}
