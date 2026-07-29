import Foundation
import Testing

@testable import JollysMQTTCore

@Suite("Payload inspection")
struct PayloadInspectionTests {
  @Test("Classification prefers JSON, then strict UTF-8, then bytes")
  func classificationPrecedence() async throws {
    let inspector = PayloadInspector()

    let json = await inspector.inspect(
      .fixture(payload: Data(#"{"enabled":true,"value":42}"#.utf8))
    )
    let text = await inspector.inspect(
      .fixture(payload: Data("plain text".utf8))
    )
    let bytes = await inspector.inspect(
      .fixture(payload: Data([0x66, 0x6f, 0x80]))
    )

    guard case .json(let document) = json.presentation else {
      Issue.record("Expected JSON presentation")
      return
    }
    #expect(document.formattedText.contains(#""enabled" : true"#))
    #expect(document.formattedText.contains(#""value" : 42"#))
    #expect(text.presentation == .text(.init(text: "plain text")))
    guard case .bytes(let hex) = bytes.presentation else {
      Issue.record("Expected bytes presentation")
      return
    }
    #expect(hex.text.contains("66 6f 80"))
    #expect(!hex.isTruncated)
  }

  @Test("Metadata keeps exact delivery facts and payload size")
  func metadata() async {
    let message = PayloadMessage.fixture(
      topic: "factory//pump/",
      payload: Data([0x00, 0x01, 0x02])
    )
    let result = await PayloadInspector().inspect(message)

    #expect(result.message.topicID.fullTopic == "factory//pump/")
    #expect(result.message.receivedAtMicroseconds == 1_754_000_000_123_456)
    #expect(result.message.qos == .atLeastOnce)
    #expect(result.message.retained)
    #expect(result.message.direction == .received)
    #expect(result.message.payloadByteCount == 3)
  }

  @Test("JSON roots and numeric paths use stable escaped JSON Pointers")
  func jsonPathsAndTypes() async throws {
    let payload = Data(
      #"{"a/b":{"~key":[true,9007199254740993,1.25]},"flag":false}"#.utf8
    )
    let result = await PayloadInspector().inspect(.fixture(payload: payload))
    guard case .json(let document) = result.presentation else {
      Issue.record("Expected JSON")
      return
    }

    #expect(
      document.numericPaths.map(\.path.rawValue)
        == ["/a~1b/~0key/1", "/a~1b/~0key/2"]
    )
    #expect(
      document.numericPaths[0].value.foundationDescription
        == "9007199254740993"
    )
    #expect(document.numericPaths[1].value.decimalValue == Decimal(string: "1.25"))
    #expect(
      document.formattedValue(
        at: PayloadJSONPointer(rawValue: "/a~1b/~0key/1")
      ) == "9007199254740993"
    )

    let scalar = await PayloadInspector().inspect(
      .fixture(payload: Data("-12.5".utf8))
    )
    guard case .json(let scalarDocument) = scalar.presentation else {
      Issue.record("Expected JSON fragment")
      return
    }
    #expect(scalarDocument.numericPaths.map(\.path) == [.root])
  }

  @Test("JSON byte ceiling matches the accepted transport payload ceiling")
  func jsonByteBoundary() async {
    let limit = PayloadInspectionLimits().maximumJSONBytes
    let atLimit = Data(
      ("0" + String(repeating: " ", count: limit - 1)).utf8
    )
    let overLimit = Data(
      ("0" + String(repeating: " ", count: limit)).utf8
    )
    let inspector = PayloadInspector()

    let accepted = await inspector.inspect(.fixture(payload: atLimit))
    let bounded = await inspector.inspect(.fixture(payload: overLimit))

    guard case .json = accepted.presentation else {
      Issue.record("Expected an exactly-at-limit JSON fragment")
      return
    }
    guard case .text(let text) = bounded.presentation else {
      Issue.record("Expected bounded UTF-8 fallback")
      return
    }
    #expect(
      text.notice == .jsonByteLimitExceeded(limit: 1_048_576)
    )
    #expect(text.isPreviewTruncated)
    #expect(text.completeText == nil)
  }

  @Test("Depth and node bounds are visible instead of crashing or disappearing")
  func structuralBounds() async {
    let limits = PayloadInspectionLimits(
      maximumJSONBytes: 1_048_576,
      maximumJSONDepth: 4,
      maximumJSONNodeCount: 3
    )
    let inspector = PayloadInspector(limits: limits)

    let deep = await inspector.inspect(
      .fixture(payload: Data("[[[[[0]]]]]".utf8))
    )
    let wide = await inspector.inspect(
      .fixture(payload: Data("[0,1,2]".utf8))
    )

    guard case .text(let deepText) = deep.presentation,
      case .text(let wideText) = wide.presentation
    else {
      Issue.record("Expected bounded UTF-8 fallbacks")
      return
    }
    #expect(deepText.notice == .jsonDepthLimitExceeded(limit: 4))
    #expect(wideText.notice == .jsonNodeLimitExceeded(limit: 3))
  }

  @Test("Text previews and hex output are bounded without lossy classification")
  func boundedPresentations() async {
    let inspector = PayloadInspector(
      limits: .init(
        maximumTextPreviewBytes: 4,
        maximumHexBytes: 3
      )
    )
    let text = await inspector.inspect(
      .fixture(payload: Data("éclair".utf8))
    )
    let bytes = await inspector.inspect(
      .fixture(payload: Data([0x00, 0x80, 0x01, 0x02]))
    )

    guard case .text(let textPresentation) = text.presentation,
      case .bytes(let hex) = bytes.presentation
    else {
      Issue.record("Unexpected classifications")
      return
    }
    #expect(textPresentation.text == "écl")
    #expect(textPresentation.completeText == "éclair")
    #expect(textPresentation.isPreviewTruncated)
    #expect(hex.text.contains("00 80 01"))
    #expect(hex.presentedByteCount == 3)
    #expect(hex.totalByteCount == 4)
    #expect(hex.isTruncated)
  }

  @Test("Foundation-accepted non-UTF-8 JSON is marked as normalized raw text")
  func nonUTF8JSONRawSemantics() async {
    let string = #"{"value":1}"#
    let utf16 = string.data(using: .utf16LittleEndian)!
    let result = await PayloadInspector().inspect(.fixture(payload: utf16))

    guard case .json(let document) = result.presentation else {
      Issue.record("Expected Foundation to accept UTF-16 JSON")
      return
    }
    #expect(!document.rawTextIsOriginalUTF8)
    #expect(document.rawText.contains(#""value""#))
  }

  @Test("Snapshot selection suppresses a cached value after reconnect")
  func staleSnapshotSuppression() async {
    let brokerID = UUID()
    let firstEpoch = ConnectionEpochID()
    let ingestion = BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: "source",
      historyWriter: DisabledBrokerHistoryWriter()
    )
    await ingestion.ingest(
      BrokerInboundMessage(
        connectionEpoch: firstEpoch,
        ordinal: 1,
        topic: "private/value",
        payload: Data("secret old value".utf8),
        qos: .atMostOnce,
        retained: false,
        duplicate: false,
        receivedAtMicroseconds: 10
      )
    )
    let topicID = BrokerTopicID(
      brokerID: brokerID,
      fullTopic: "private/value"
    )
    let current = await ingestion.flush()

    guard case .current(let message) = current.payloadSelection(for: topicID)
    else {
      Issue.record("Expected current payload")
      return
    }
    #expect(message.payload == Data("secret old value".utf8))

    await ingestion.beginConnectionEpoch(ConnectionEpochID())
    let stale = await ingestion.flush()

    #expect(stale.payloadSelection(for: topicID) == .stale(topicID))
  }

  @Test("Structural row and accessibility previews do not retain huge labels")
  func boundedStructuralNodePreviews() async throws {
    let key = String(repeating: "k", count: 2_000)
    let value = String(repeating: "v", count: 20_000)
    let payload = try JSONSerialization.data(
      withJSONObject: [key: value],
      options: [.sortedKeys]
    )
    let inspector = PayloadInspector(
      limits: .init(maximumJSONNodePreviewCharacters: 16)
    )
    let result = await inspector.inspect(.fixture(payload: payload))
    guard case .json(let document) = result.presentation else {
      Issue.record("Expected JSON")
      return
    }
    let pointer = PayloadJSONPointer.root.appendingObjectKey(key)
    let node = try #require(document.nodes.first { $0.id == pointer })

    #expect(node.label.count == 16)
    #expect(node.labelIsTruncated)
    #expect(node.pathPreview.count == 16)
    #expect(node.pathPreviewIsTruncated)
    #expect(node.displayValue?.count == 16)
    #expect(node.displayValueIsTruncated)
    #expect(
      document.formattedValue(at: pointer)
        == String(reflecting: value)
    )
  }

  @Test(
    "Malformed UTF-8 is never decoded lossily",
    arguments: [
      Data([0xC0, 0xAF]),
      Data([0xED, 0xA0, 0x80]),
      Data([0xF4, 0x90, 0x80, 0x80]),
      Data([0xE2, 0x82]),
    ]
  )
  func malformedUTF8(payload: Data) async {
    let result = await PayloadInspector().inspect(.fixture(payload: payload))
    guard case .bytes = result.presentation else {
      Issue.record("Expected bytes for malformed UTF-8")
      return
    }
  }
}

extension PayloadMessage {
  fileprivate static func fixture(
    topic: String = "devices/pump",
    payload: Data,
    ordinal: UInt64 = 1
  ) -> Self {
    Self(
      id: PayloadMessageID(
        connectionEpoch: ConnectionEpochID(),
        ordinal: ordinal,
        direction: .received
      ),
      topicID: BrokerTopicID(
        brokerID: UUID(),
        fullTopic: topic
      ),
      receivedAtMicroseconds: 1_754_000_000_123_456,
      qos: .atLeastOnce,
      retained: true,
      payload: payload
    )
  }
}
