import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTT

@MainActor
@Suite("Publish feature")
struct PublishFeatureTests {
  @Test("Selection pre-fills the topic only until the user edits it")
  func selectionPrefillRespectsManualEdit() {
    var state = PublishFeature.State()

    _ = PublishFeature.reduce(
      state: &state,
      intent: .selectionChanged("factory/one")
    )
    _ = PublishFeature.reduce(
      state: &state,
      intent: .editTopic("manual/topic")
    )
    _ = PublishFeature.reduce(
      state: &state,
      intent: .selectionChanged("factory/two")
    )

    #expect(state.draft.topic == "manual/topic")
    #expect(state.topicWasManuallyEdited)
  }

  @Test("Invalid topic and mode input never invoke the publisher")
  func invalidDraftDoesNotPublish() async {
    let publisher = RecordingPublisher()
    let store = PublishStore(publisher: publisher)
    store.send(.editTopic("invalid/+"))
    store.send(.editPayload("hello"))

    store.publish()
    await store.waitForPublishForTesting()

    #expect(
      store.state.status == .rejected(.invalidDraft(.invalidTopic))
    )
    #expect(await publisher.requests().isEmpty)

    store.send(.editTopic("valid/topic"))
    store.send(.setInputMode(.hex))
    store.send(.editPayload("xyz"))
    store.publish()
    await store.waitForPublishForTesting()

    #expect(
      store.state.status == .rejected(.invalidDraft(.invalidHex))
    )
    #expect(await publisher.requests().isEmpty)
  }

  @Test("Only successful operations enter exact deduplicated bounded history")
  func onlySuccessEntersHistory() async {
    let publisher = RecordingPublisher(
      results: [
        .failure(.queueFull),
        .failure(.transportUnavailable),
        .success(.fixture(id: 3, completedAt: 30)),
        .success(.fixture(id: 4, completedAt: 40)),
        .success(.fixture(id: 5, completedAt: 50)),
      ]
    )
    let store = PublishStore(
      publisher: publisher,
      historyCapacity: 2,
      operationID: SequentialOperationIDs().next
    )
    store.send(.editTopic("factory/status"))
    store.send(.editPayload("one"))

    await store.publishAndWaitForTesting()
    await store.publishAndWaitForTesting()
    await store.publishAndWaitForTesting()
    store.send(.setQoS(.atLeastOnce))
    await store.publishAndWaitForTesting()
    store.send(.setQoS(.atMostOnce))
    await store.publishAndWaitForTesting()

    #expect(store.state.history.entries.count == 2)
    #expect(
      store.state.history.entries.map(\.draft.qos)
        == [.atMostOnce, .atLeastOnce]
    )
    #expect(
      store.state.history.entries.map(\.id)
        == [.fixture(5), .fixture(4)]
    )
  }

  @Test("Publish sends exact bytes, QoS, retain, and operation identity")
  func exactRequest() async throws {
    let publisher = RecordingPublisher(
      results: [.success(.fixture(id: 1, completedAt: 10))]
    )
    let operationID = PublishOperationID.fixture(1)
    let store = PublishStore(
      publisher: publisher,
      operationID: { operationID }
    )
    store.send(.editTopic("factory/value"))
    store.send(.setInputMode(.hex))
    store.send(.editPayload("00 ff"))
    store.send(.setQoS(.exactlyOnce))
    store.send(.setRetain(true))

    await store.publishAndWaitForTesting()

    let request = try #require(await publisher.requests().first)
    #expect(request.operationID == operationID)
    #expect(request.topic == "factory/value")
    #expect(request.payload == Data([0x00, 0xFF]))
    #expect(request.qos == .exactlyOnce)
    #expect(request.retain)
  }

  @Test("Editing the next draft cannot hide an acknowledged in-flight publish")
  func editDuringPublishPreservesCapturedSuccess() async throws {
    let publisher = SuspendedPublisher()
    let operationID = PublishOperationID.fixture(1)
    let store = PublishStore(
      publisher: publisher,
      operationID: { operationID }
    )
    store.send(.editTopic("factory/value"))
    store.send(.editPayload("submitted"))
    store.publish()
    let request = await publisher.waitForRequest()

    store.send(.editPayload("next draft"))
    #expect(store.state.status == .publishing(operationID))
    await publisher.complete(
      .success(
        BrokerPublishSuccess(
          operationID: request.operationID,
          completion: .acknowledged,
          completedAtMicroseconds: 10
        )
      )
    )
    await store.waitForPublishForTesting()

    let saved = try #require(store.state.history.entries.first)
    #expect(saved.draft.payloadSource == "submitted")
    #expect(store.state.draft.payloadSource == "next draft")
    #expect(
      store.state.status
        == .succeeded(
          BrokerPublishSuccess(
            operationID: operationID,
            completion: .acknowledged,
            completedAtMicroseconds: 10
          )
        )
    )
  }

  @Test("Restoring history restores every draft setting and protects its topic")
  func restoreHistory() {
    let restored = PublishDraft(
      topic: "saved/topic",
      payloadSource: #"{"answer":42}"#,
      inputMode: .json,
      qos: .atLeastOnce,
      retain: true
    )
    var state = PublishFeature.State(
      history: PublishDraftHistory(
        entries: [
          SuccessfulPublishDraft(
            id: .fixture(1),
            draft: restored,
            completedAtMicroseconds: 10
          )
        ]
      )
    )

    _ = PublishFeature.reduce(
      state: &state,
      intent: .restoreHistory(.fixture(1))
    )
    _ = PublishFeature.reduce(
      state: &state,
      intent: .selectionChanged("new/selection")
    )

    #expect(state.draft == restored)
    #expect(state.topicWasManuallyEdited)
  }

  @Test("Only completed success uses the success icon")
  func honestStatusIcons() {
    let operationID = PublishOperationID.fixture(1)
    let success = BrokerPublishSuccess.fixture(id: 1, completedAt: 10)

    #expect(PublishStatus.publishing(operationID).systemImage == "clock.arrow.circlepath")
    #expect(PublishStatus.succeeded(success).systemImage == "checkmark.circle")
    #expect(PublishStatus.rejected(.queueFull).systemImage == "exclamationmark.triangle")
  }

  @Test("Draft-history labels bound private topic and payload previews")
  func boundedHistoryLabel() {
    let draft = PublishDraft(
      topic: String(repeating: "t", count: 1_000),
      payloadSource: String(repeating: "p", count: 1_000)
    )

    #expect(draft.historyLabel.count == 80 + 1 + 3 + 32 + 1)
    #expect(draft.historyLabel.hasPrefix(String(repeating: "t", count: 80) + "…"))
    #expect(draft.historyLabel.hasSuffix(String(repeating: "p", count: 32) + "…"))
  }
}

private actor RecordingPublisher: BrokerPublishing {
  private var recordedRequests: [BrokerPublishRequest] = []
  private var results: [BrokerPublishResult]

  init(results: [BrokerPublishResult] = []) {
    self.results = results
  }

  func publish(_ request: BrokerPublishRequest) -> BrokerPublishResult {
    recordedRequests.append(request)
    guard !results.isEmpty else {
      return .failure(.transportUnavailable)
    }
    return results.removeFirst()
  }

  func requests() -> [BrokerPublishRequest] {
    recordedRequests
  }
}

private actor SuspendedPublisher: BrokerPublishing {
  private var request: BrokerPublishRequest?
  private var requestWaiters: [CheckedContinuation<BrokerPublishRequest, Never>] = []
  private var completion: CheckedContinuation<BrokerPublishResult, Never>?

  func publish(_ request: BrokerPublishRequest) async -> BrokerPublishResult {
    self.request = request
    let waiters = requestWaiters
    requestWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: request)
    }
    return await withCheckedContinuation { continuation in
      completion = continuation
    }
  }

  func waitForRequest() async -> BrokerPublishRequest {
    if let request {
      return request
    }
    return await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func complete(_ result: BrokerPublishResult) {
    completion?.resume(returning: result)
    completion = nil
  }
}

@MainActor
private final class SequentialOperationIDs {
  private var value: UInt8 = 0

  func next() -> PublishOperationID {
    value &+= 1
    return .fixture(value)
  }
}

extension PublishOperationID {
  fileprivate static func fixture(_ byte: UInt8) -> PublishOperationID {
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

extension BrokerPublishSuccess {
  fileprivate static func fixture(
    id: UInt8,
    completedAt: Int64
  ) -> BrokerPublishSuccess {
    BrokerPublishSuccess(
      operationID: .fixture(id),
      completion: .transportAccepted,
      completedAtMicroseconds: completedAt
    )
  }
}

extension PublishStore {
  fileprivate func publishAndWaitForTesting() async {
    publish()
    await waitForPublishForTesting()
  }
}
