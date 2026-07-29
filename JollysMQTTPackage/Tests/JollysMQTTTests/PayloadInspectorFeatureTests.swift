import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTT

@Suite("Payload inspector feature")
@MainActor
struct PayloadInspectorFeatureTests {
  @Test("Parsing is lazy and stale selections never expose cached payloads")
  func lazyAndStaleSuppression() async {
    let inspector = ControlledPayloadInspector()
    let clipboard = RecordingPayloadClipboard()
    let store = PayloadInspectorStore(
      inspector: inspector,
      clipboard: clipboard
    )
    let staleID = BrokerTopicID(
      brokerID: UUID(),
      fullTopic: "cached/private"
    )

    #expect(await inspector.requestCount == 0)
    store.send(.selectionChanged(.stale(staleID)))
    #expect(await inspector.requestCount == 0)
    #expect(store.state.unavailableReason == .stale)
    #expect(store.state.inspection == nil)
    #expect(store.state.canCopy(.topic))
    #expect(!store.state.canCopy(.rawBytes))

    let message = PayloadMessage.testFixture(
      topicID: staleID,
      payload: Data("current".utf8)
    )
    store.send(.selectionChanged(.current(message)))
    await inspector.waitForRequestCount(1)

    #expect(store.state.isInspecting)
    #expect(store.state.inspection == nil)
  }

  @Test("A completed parse from an old selection cannot replace the new payload")
  func staleAsyncResultRejection() async {
    let inspector = ControlledPayloadInspector()
    let store = PayloadInspectorStore(
      inspector: inspector,
      clipboard: RecordingPayloadClipboard()
    )
    let first = PayloadMessage.testFixture(
      payload: Data("first".utf8),
      ordinal: 1
    )
    let second = PayloadMessage.testFixture(
      payload: Data("second".utf8),
      ordinal: 2
    )

    store.send(.selectionChanged(.current(first)))
    await inspector.waitForRequestCount(1)
    store.send(.selectionChanged(.current(second)))
    await inspector.waitForRequestCount(2)

    await inspector.complete(
      messageID: first.id,
      presentation: .text(.init(text: "first"))
    )
    await Task.yield()
    #expect(store.state.inspection == nil)
    #expect(store.state.isInspecting)

    await inspector.complete(
      messageID: second.id,
      presentation: .text(.init(text: "second"))
    )
    await waitUntil { !store.state.isInspecting }
    #expect(store.state.inspection?.message.id == second.id)
    #expect(
      store.state.inspection?.presentation
        == .text(.init(text: "second"))
    )
  }

  @Test("Leaving current content cancels its selected-only parse")
  func selectionRemovalCancelsParse() async {
    let inspector = ControlledPayloadInspector()
    let store = PayloadInspectorStore(
      inspector: inspector,
      clipboard: RecordingPayloadClipboard()
    )
    let message = PayloadMessage.testFixture(
      payload: Data("pending".utf8)
    )

    store.send(.selectionChanged(.current(message)))
    await inspector.waitForRequestCount(1)
    store.send(.selectionChanged(.stale(message.topicID)))
    await inspector.waitForCancellation(of: message.id)

    #expect(store.state.unavailableReason == .stale)
    #expect(store.state.inspection == nil)
    #expect(!store.state.isInspecting)
  }

  @Test("Every copy variant sends exact uncapped content through the adapter")
  func exactCopyVariants() async throws {
    let clipboard = RecordingPayloadClipboard()
    let store = PayloadInspectorStore(
      inspector: PayloadInspector(
        limits: .init(maximumTextPreviewBytes: 4)
      ),
      clipboard: clipboard
    )
    let rawJSON = #"{"long":"abcdefgh","a/b":12}"#
    let message = PayloadMessage.testFixture(
      topic: "factory//pump/",
      payload: Data(rawJSON.utf8)
    )

    store.send(.selectionChanged(.current(message)))
    await waitUntil { store.state.inspection != nil }
    guard case .json(let document) = store.state.inspection?.presentation else {
      Issue.record("Expected JSON")
      return
    }

    store.send(.copy(.topic))
    store.send(.copy(.rawBytes))
    store.send(.copy(.displayText))
    store.send(.copy(.formattedJSON))
    store.send(
      .selectJSONValue(PayloadJSONPointer(rawValue: "/a~1b"))
    )
    store.send(.copy(.selectedJSONValue))

    #expect(
      clipboard.contents
        == [
          .text("factory//pump/"),
          .rawBytes(Data(rawJSON.utf8)),
          .text(rawJSON),
          .text(document.formattedText),
          .text("12"),
        ]
    )
    #expect(
      store.state.copyOutcome == .succeeded(.selectedJSONValue)
    )
  }

  @Test("Copy Display Text uses complete text, not its bounded preview")
  func completeTextCopy() async {
    let clipboard = RecordingPayloadClipboard()
    let store = PayloadInspectorStore(
      inspector: PayloadInspector(
        limits: .init(maximumTextPreviewBytes: 4)
      ),
      clipboard: clipboard
    )
    let complete = "éclair is complete"
    store.send(
      .selectionChanged(
        .current(.testFixture(payload: Data(complete.utf8)))
      )
    )
    await waitUntil { store.state.inspection != nil }

    guard case .text(let text) = store.state.inspection?.presentation else {
      Issue.record("Expected text")
      return
    }
    #expect(text.isPreviewTruncated)
    #expect(text.text != text.completeText)

    store.send(.copy(.displayText))
    #expect(clipboard.contents == [.text(complete)])
  }

  @Test("Clipboard failures and adaptive layout remain explicit state")
  func copyFailureAndLayout() async {
    let clipboard = RecordingPayloadClipboard()
    clipboard.shouldFail = true
    let store = PayloadInspectorStore(
      inspector: PayloadInspector(),
      clipboard: clipboard,
      layout: .wide
    )
    store.send(
      .selectionChanged(
        .current(.testFixture(payload: Data("text".utf8)))
      )
    )
    await waitUntil { store.state.inspection != nil }

    store.send(.setLayout(.compact))
    store.send(.setCompactSection(.topics))
    store.send(.copy(.topic))

    #expect(store.state.layout == .compact)
    #expect(store.state.compactSection == .topics)
    #expect(store.state.copyOutcome == .failed(.topic))
    store.send(.dismissCopyOutcome)
    #expect(store.state.copyOutcome == nil)
  }

  @Test("Filtering a selected row does not discard its current inspector payload")
  func filteredSelectionRemainsInspectable() async {
    let brokerID = UUID()
    let ingestion = BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: "source",
      historyWriter: DisabledBrokerHistoryWriter()
    )
    await ingestion.ingest(
      BrokerInboundMessage(
        connectionEpoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "factory/temperature",
        payload: Data("21.5".utf8),
        qos: .atMostOnce,
        retained: false,
        duplicate: false,
        receivedAtMicroseconds: 1
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State(
      selectedTopic: "factory/temperature",
      expectedBrokerID: brokerID
    )
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )
    guard case .current(let before) = state.payloadSelection else {
      Issue.record("Expected current selected payload")
      return
    }

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .setSearchText("does not match")
    )

    #expect(state.rows.isEmpty)
    #expect(state.payloadSelection == .current(before))
  }
}

private actor ControlledPayloadInspector: PayloadInspecting {
  struct Request {
    let message: PayloadMessage
    let continuation: CheckedContinuation<PayloadInspection, Never>
  }

  private var requests: [Request] = []
  private var cancellations: Set<PayloadMessageID> = []

  var requestCount: Int { requests.count }

  func inspect(_ message: PayloadMessage) async -> PayloadInspection {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        requests.append(.init(message: message, continuation: continuation))
      }
    } onCancel: {
      Task {
        await self.recordCancellation(of: message.id)
      }
    }
  }

  func waitForRequestCount(_ count: Int) async {
    while requests.count < count {
      await Task.yield()
    }
  }

  func complete(
    messageID: PayloadMessageID,
    presentation: PayloadPresentation
  ) {
    guard
      let index = requests.firstIndex(where: {
        $0.message.id == messageID
      })
    else {
      return
    }
    let request = requests.remove(at: index)
    request.continuation.resume(
      returning: PayloadInspection(
        message: request.message,
        presentation: presentation
      )
    )
  }

  func waitForCancellation(of id: PayloadMessageID) async {
    while !cancellations.contains(id) {
      await Task.yield()
    }
  }

  private func recordCancellation(of id: PayloadMessageID) {
    cancellations.insert(id)
  }
}

@MainActor
private final class RecordingPayloadClipboard: PayloadClipboardWriting {
  var contents: [PayloadClipboardContent] = []
  var shouldFail = false

  func write(_ content: PayloadClipboardContent) throws {
    if shouldFail {
      throw ClipboardTestFailure()
    }
    contents.append(content)
  }
}

private struct ClipboardTestFailure: Error {}

extension PayloadMessage {
  fileprivate static func testFixture(
    topicID: BrokerTopicID? = nil,
    topic: String = "devices/value",
    payload: Data,
    ordinal: UInt64 = 1
  ) -> Self {
    let resolvedID =
      topicID
      ?? BrokerTopicID(brokerID: UUID(), fullTopic: topic)
    return Self(
      id: PayloadMessageID(
        connectionEpoch: ConnectionEpochID(),
        ordinal: ordinal,
        direction: .received
      ),
      topicID: resolvedID,
      receivedAtMicroseconds: 1_754_000_000_123_456,
      qos: .exactlyOnce,
      retained: true,
      payload: payload
    )
  }
}

@MainActor
private func waitUntil(
  _ predicate: @escaping @MainActor () -> Bool
) async {
  while !predicate() {
    await Task.yield()
  }
}
