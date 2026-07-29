import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTT

@MainActor
@Suite("Retained deletion feature")
struct RetainedDeletionFeatureTests {
  @Test("Single deletion snapshots one exact topic into a destructive confirmation")
  func singleConfirmation() throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        RetainedDeletionContext(
          brokerID: brokerID,
          connectionEpoch: epoch,
          selectedTopic: "factory/line/status",
          selectedHasCurrentValue: true
        )
      )
    )

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSingleDeletion(
        topics: [
          "factory/line/status/child",
          "factory/line/status",
        ]
      )
    )

    let confirmation = try #require(state.confirmation)
    #expect(confirmation.scope == .single(topic: "factory/line/status"))
    #expect(confirmation.topics == ["factory/line/status"])
    #expect(confirmation.topicCount == 1)
    #expect(confirmation.isDestructive)
    #expect(
      confirmation.accessibilityTarget
        == .exactTopic("factory/line/status")
    )
  }

  @Test("Confirmation independently deduplicates and UTF-8 orders exact topics")
  func confirmationNormalization() {
    let confirmation = RetainedDeletionConfirmation(
      brokerID: UUID(),
      connectionEpoch: ConnectionEpochID(),
      scope: .subtree(rootTopic: "root"),
      topics: [
        "root/é",
        "root/a",
        "root/é",
        "root/ä",
      ]
    )

    #expect(
      confirmation.topics
        == ["root/a", "root/ä", "root/é"]
    )
  }

  @Test("Equivalent live context preserves an empty-target explanation")
  func equivalentContextPreservesEmptyTargetExplanation() {
    let context = RetainedDeletionContext(
      brokerID: UUID(),
      connectionEpoch: ConnectionEpochID(),
      selectedTopic: "root",
      selectedHasCurrentValue: false
    )
    var state = RetainedDeletionFeature.State(
      context: context,
      targetEnumerationEmpty: true
    )

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        RetainedDeletionContext(
          brokerID: context.brokerID,
          connectionEpoch: context.connectionEpoch,
          selectedTopic: context.selectedTopic,
          selectedHasCurrentValue: true
        )
      )
    )

    #expect(state.targetEnumerationEmpty)
    #expect(!state.reconfirmationUnavailable)

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        RetainedDeletionContext(
          brokerID: context.brokerID,
          connectionEpoch: context.connectionEpoch,
          selectedTopic: "other",
          selectedHasCurrentValue: false
        )
      )
    )
    #expect(!state.targetEnumerationEmpty)
  }

  @Test("Equivalent live context preserves a reconnect explanation")
  func equivalentContextPreservesReconnectExplanation() {
    let context = RetainedDeletionContext(
      brokerID: UUID(),
      connectionEpoch: ConnectionEpochID(),
      selectedTopic: "root",
      selectedHasCurrentValue: false
    )
    var state = RetainedDeletionFeature.State(
      context: context,
      reconfirmationUnavailable: true
    )

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(context)
    )

    #expect(state.reconfirmationUnavailable)
    #expect(!state.targetEnumerationEmpty)

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        RetainedDeletionContext(
          brokerID: context.brokerID,
          connectionEpoch: ConnectionEpochID(),
          selectedTopic: context.selectedTopic,
          selectedHasCurrentValue: false
        )
      )
    )
    #expect(!state.reconfirmationUnavailable)
  }

  @Test("Injected recursive targets cannot escape the selected MQTT subtree")
  func recursiveScopeIsRevalidated() throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: epoch,
          topics: []
        )
      )
    )

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: [
          "root/a",
          "rootish/not-a-child",
          "root/+",
          "root/a",
        ]
      )
    )

    #expect(try #require(state.confirmation).topics == ["root/a"])
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .dismissConfirmation
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: ["rootish/not-a-child"]
      )
    )
    #expect(state.confirmation == nil)
    #expect(state.targetEnumerationEmpty)
  }

  @Test(
    "Recursive deletion confirms an exact snapshot and advances only matching successes"
  )
  func partialFailureIsRetryable() throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: epoch,
          topics: ["root/a", "root/b", "root/c"]
        )
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: ["root/a", "root/b", "root/c"]
      )
    )
    let confirmation = try #require(state.confirmation)
    #expect(confirmation.topicCount == 3)
    #expect(confirmation.scope == .subtree(rootTopic: "root"))
    #expect(confirmation.isDestructive)
    #expect(confirmation.accessibilityTarget == .exactCount(3))

    let ids = [
      PublishOperationID.retainedFixture(1),
      .retainedFixture(2),
      .retainedFixture(3),
    ]
    let first = try #require(
      RetainedDeletionFeature.reduce(
        state: &state,
        intent: .confirm(operationIDs: ids)
      )
    )
    #expect(
      first
        == .publish(
          .retainedDeletionFixture(
            id: 1,
            topic: "root/a",
            brokerID: brokerID,
            epoch: epoch
          )
        )
    )
    #expect(state.operation?.completedTopics.isEmpty == true)

    let second = try #require(
      RetainedDeletionFeature.reduce(
        state: &state,
        action: .publishFinished(
          operationID: ids[0],
          result: .success(
            .retainedDeletionFixture(id: 1)
          )
        )
      )
    )
    #expect(
      second
        == .publish(
          .retainedDeletionFixture(
            id: 2,
            topic: "root/b",
            brokerID: brokerID,
            epoch: epoch
          )
        )
    )
    #expect(state.operation?.completedTopics == ["root/a"])

    let third = try #require(
      RetainedDeletionFeature.reduce(
        state: &state,
        action: .publishFinished(
          operationID: ids[1],
          result: .failure(.queueFull)
        )
      )
    )
    #expect(
      third
        == .publish(
          .retainedDeletionFixture(
            id: 3,
            topic: "root/c",
            brokerID: brokerID,
            epoch: epoch
          )
        )
    )
    #expect(state.operation?.completedTopics == ["root/a"])
    #expect(state.operation?.retryableTopics == ["root/b"])

    #expect(
      RetainedDeletionFeature.reduce(
        state: &state,
        action: .publishFinished(
          operationID: ids[2],
          result: .success(.retainedDeletionFixture(id: 3))
        )
      ) == nil
    )
    #expect(state.operation?.phase == .finished)
    #expect(state.operation?.completedTopicCount == 2)
    #expect(state.operation?.completedTopics == ["root/a", "root/c"])
    #expect(state.operation?.retryableTopics == ["root/b"])
  }

  @Test("Cancellation lets the current result settle and never starts the next topic")
  func deterministicCancellation() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let ids = [
      PublishOperationID.retainedFixture(1),
      .retainedFixture(2),
    ]
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: epoch,
          topics: ["root/a", "root/b"]
        )
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: ["root/a", "root/b"]
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .confirm(operationIDs: ids)
    )

    _ = RetainedDeletionFeature.reduce(state: &state, intent: .cancel)
    let next = RetainedDeletionFeature.reduce(
      state: &state,
      action: .publishFinished(
        operationID: ids[0],
        result: .success(.retainedDeletionFixture(id: 1))
      )
    )

    #expect(next == nil)
    #expect(state.operation?.phase == .cancelled)
    #expect(state.operation?.completedTopics == ["root/a"])
    #expect(state.operation?.retryableTopics == ["root/b"])
  }

  @Test("A broker or epoch change invalidates confirmation and stops an active plan")
  func authorizationContextChange() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let context = RetainedDeletionContext.fixture(
      brokerID: brokerID,
      epoch: epoch,
      topics: ["root/a", "root/b"]
    )
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(context)
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: ["root/a", "root/b"]
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: ConnectionEpochID(),
          topics: ["root/a", "root/b"]
        )
      )
    )
    #expect(state.confirmation == nil)

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(context)
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: ["root/a", "root/b"]
      )
    )
    let firstID = PublishOperationID.retainedFixture(1)
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .confirm(
        operationIDs: [firstID, .retainedFixture(2)]
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(nil)
    )
    #expect(state.operation?.phase == .cancelling)

    let next = RetainedDeletionFeature.reduce(
      state: &state,
      action: .publishFinished(
        operationID: firstID,
        result: .failure(.connectionChanged)
      )
    )
    #expect(next == nil)
    #expect(state.operation?.phase == .cancelled)
    #expect(state.operation?.retryableTopics == ["root/a", "root/b"])
  }

  @Test("Retry preserves completed topics and replaces only retryable identities")
  func retryRemainder() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: epoch,
          topics: ["root/a", "root/b"]
        )
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: ["root/a", "root/b"]
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .confirm(
        operationIDs: [.retainedFixture(1), .retainedFixture(2)]
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      action: .publishFinished(
        operationID: .retainedFixture(1),
        result: .success(.retainedDeletionFixture(id: 1))
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      action: .publishFinished(
        operationID: .retainedFixture(2),
        result: .failure(.transportUnavailable)
      )
    )

    let retry = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .retry(operationIDs: [.retainedFixture(3)])
    )

    #expect(
      retry
        == .publish(
          .retainedDeletionFixture(
            id: 3,
            topic: "root/b",
            brokerID: brokerID,
            epoch: epoch
          )
        )
    )
    #expect(state.operation?.completedTopics == ["root/a"])
    #expect(
      state.operation?.topics.map(\.operationID)
        == [.retainedFixture(1), .retainedFixture(3)]
    )
  }

  @Test("Reconnect requires a new exact-count confirmation for current remainder")
  func reconnectReconfirmation() throws {
    let brokerID = UUID()
    let oldEpoch = ConnectionEpochID()
    let newEpoch = ConnectionEpochID()
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: oldEpoch,
          topics: ["root/a", "root/b"]
        )
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSubtreeDeletion(
        topics: ["root/a", "root/b"]
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .confirm(
        operationIDs: [.retainedFixture(1), .retainedFixture(2)]
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      action: .publishFinished(
        operationID: .retainedFixture(1),
        result: .success(.retainedDeletionFixture(id: 1))
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      action: .publishFinished(
        operationID: .retainedFixture(2),
        result: .failure(.connectionChanged)
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: newEpoch,
          topics: ["root/b", "root/new"]
        )
      )
    )

    #expect(
      RetainedDeletionFeature.reduce(
        state: &state,
        intent: .retry(operationIDs: [.retainedFixture(3)])
      ) == nil
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .reconfirmRetryableRemainder(
        currentTopics: ["root/new"]
      )
    )
    #expect(state.confirmation == nil)
    #expect(state.reconfirmationUnavailable)
    #expect(
      RetainedDeletionFeature.reduce(
        state: &state,
        intent: .reconfirmRetryableRemainder(
          currentTopics: ["root/new", "root/b", "root/b"]
        )
      ) == nil
    )
    let confirmation = try #require(state.confirmation)
    #expect(!state.reconfirmationUnavailable)
    #expect(confirmation.connectionEpoch == newEpoch)
    #expect(confirmation.topics == ["root/b"])
    #expect(
      confirmation.scope
        == .retryableRemainder(rootTopic: "root")
    )

    let effect = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .confirm(operationIDs: [.retainedFixture(4)])
    )
    #expect(
      effect
        == .publish(
          .retainedDeletionFixture(
            id: 4,
            topic: "root/b",
            brokerID: brokerID,
            epoch: newEpoch
          )
        )
    )
  }

  @Test("A QoS 1 delete cannot advance on an inconsistent QoS 0 completion")
  func transportAcceptanceIsNotAcknowledgement() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let operationID = PublishOperationID.retainedFixture(1)
    var state = RetainedDeletionFeature.State()
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .contextChanged(
        .fixture(
          brokerID: brokerID,
          epoch: epoch,
          topics: ["root"]
        )
      )
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .requestSingleDeletion(topics: ["root"])
    )
    _ = RetainedDeletionFeature.reduce(
      state: &state,
      intent: .confirm(operationIDs: [operationID])
    )

    _ = RetainedDeletionFeature.reduce(
      state: &state,
      action: .publishFinished(
        operationID: operationID,
        result: .success(
          BrokerPublishSuccess(
            operationID: operationID,
            completion: .transportAccepted,
            completedAtMicroseconds: 1
          )
        )
      )
    )

    #expect(state.operation?.completedTopics.isEmpty == true)
    #expect(state.operation?.retryableTopics == ["root"])
    #expect(state.operation?.phase == .finished)
  }

  @Test("Live context updates never enumerate recursive targets")
  func targetEnumerationIsLazy() {
    let counter = RetainedTargetQueryCounter()
    let brokerID = UUID()
    let store = RetainedDeletionStore(
      publisher: RetainedDeletionUnusedPublisher(),
      targetResolver: { _, selection in
        counter.count += 1
        return [selection.fullTopic]
      }
    )
    for _ in 0..<20 {
      store.updateContext(
        RetainedDeletionContext(
          brokerID: brokerID,
          connectionEpoch: ConnectionEpochID(),
          selectedTopic: "root",
          selectedHasCurrentValue: true
        ),
        snapshot: .empty
      )
    }

    #expect(counter.count == 0)
    store.requestSubtreeDeletion()
    #expect(counter.count == 1)
    #expect(store.state.confirmation?.topics == ["root"])
  }

  @Test("Store cancellation settles the in-flight publish without submitting another")
  func storeCancellationIsSequential() async throws {
    let publisher = RetainedDeletionSuspendedPublisher()
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let ids = RetainedSequentialOperationIDs()
    let store = RetainedDeletionStore(
      publisher: publisher,
      operationID: ids.next,
      targetResolver: { _, _ in ["root/a", "root/b"] }
    )
    store.updateContext(
      RetainedDeletionContext(
        brokerID: brokerID,
        connectionEpoch: epoch,
        selectedTopic: "root",
        selectedHasCurrentValue: false
      ),
      snapshot: .empty
    )
    store.requestSubtreeDeletion()
    store.confirm()
    let first = try #require(
      await publisher.waitForRequestCount(1).first
    )

    store.send(.cancel)
    await publisher.complete(
      operationID: first.operationID,
      result: .success(
        BrokerPublishSuccess(
          operationID: first.operationID,
          completion: .acknowledged,
          completedAtMicroseconds: 1
        )
      )
    )
    await store.waitForOperationForTesting()

    #expect(await publisher.requests().count == 1)
    #expect(store.state.operation?.phase == .cancelled)
    #expect(store.state.operation?.completedTopics == ["root/a"])
    #expect(store.state.operation?.retryableTopics == ["root/b"])
  }
}

extension RetainedDeletionContext {
  fileprivate static func fixture(
    brokerID: UUID,
    epoch: ConnectionEpochID,
    topics: [String]
  ) -> RetainedDeletionContext {
    RetainedDeletionContext(
      brokerID: brokerID,
      connectionEpoch: epoch,
      selectedTopic: "root",
      selectedHasCurrentValue: topics.contains("root")
    )
  }
}

extension PublishOperationID {
  fileprivate static func retainedFixture(_ byte: UInt8) -> PublishOperationID {
    PublishOperationID(
      rawValue: UUID(
        uuidString: String(
          format: "00000000-0000-0000-0000-%012x",
          byte
        )
      )!
    )
  }
}

extension BrokerPublishRequest {
  fileprivate static func retainedDeletionFixture(
    id: UInt8,
    topic: String,
    brokerID: UUID,
    epoch: ConnectionEpochID
  ) -> BrokerPublishRequest {
    BrokerPublishRequest(
      operationID: .retainedFixture(id),
      topic: topic,
      payload: Data(),
      qos: .atLeastOnce,
      retain: true,
      expectedBrokerID: brokerID,
      expectedConnectionEpoch: epoch
    )
  }
}

extension BrokerPublishSuccess {
  fileprivate static func retainedDeletionFixture(
    id: UInt8
  ) -> BrokerPublishSuccess {
    BrokerPublishSuccess(
      operationID: .retainedFixture(id),
      completion: .acknowledged,
      completedAtMicroseconds: Int64(id)
    )
  }
}

@MainActor
private final class RetainedTargetQueryCounter {
  var count = 0
}

private actor RetainedDeletionUnusedPublisher: BrokerPublishing {
  func publish(_ request: BrokerPublishRequest) -> BrokerPublishResult {
    .failure(.transportUnavailable)
  }
}

@MainActor
private final class RetainedSequentialOperationIDs {
  private var nextValue: UInt8 = 0

  func next() -> PublishOperationID {
    nextValue &+= 1
    return .retainedFixture(nextValue)
  }
}

private actor RetainedDeletionSuspendedPublisher: BrokerPublishing {
  private var recordedRequests: [BrokerPublishRequest] = []
  private var requestWaiters: [(Int, CheckedContinuation<[BrokerPublishRequest], Never>)] = []
  private var completions: [PublishOperationID: CheckedContinuation<BrokerPublishResult, Never>] =
    [:]

  func publish(_ request: BrokerPublishRequest) async -> BrokerPublishResult {
    recordedRequests.append(request)
    resumeRequestWaiters()
    return await withCheckedContinuation { continuation in
      completions[request.operationID] = continuation
    }
  }

  func waitForRequestCount(_ count: Int) async -> [BrokerPublishRequest] {
    if recordedRequests.count >= count {
      return recordedRequests
    }
    return await withCheckedContinuation { continuation in
      requestWaiters.append((count, continuation))
    }
  }

  func complete(
    operationID: PublishOperationID,
    result: BrokerPublishResult
  ) {
    completions.removeValue(forKey: operationID)?.resume(returning: result)
  }

  func requests() -> [BrokerPublishRequest] {
    recordedRequests
  }

  private func resumeRequestWaiters() {
    var remaining: [(Int, CheckedContinuation<[BrokerPublishRequest], Never>)] = []
    for (count, waiter) in requestWaiters {
      if recordedRequests.count >= count {
        waiter.resume(returning: recordedRequests)
      } else {
        remaining.append((count, waiter))
      }
    }
    requestWaiters = remaining
  }
}
