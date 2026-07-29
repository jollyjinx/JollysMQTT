import Foundation
import Testing

@testable import JollysMQTTCore

@Suite("Payload comparison")
struct PayloadComparisonTests {
  @Test("JSON comparison reports structural changes by stable pointer")
  func jsonStructuralChanges() async throws {
    let baseline = message(
      ordinal: 1,
      payload: Data(
        #"{"same":1,"changed":1,"removed":"old"}"#.utf8
      )
    )
    let current = message(
      ordinal: 2,
      payload: Data(
        #"{"same":1,"changed":2,"added":true}"#.utf8
      )
    )

    let comparison = await PayloadComparisonEngine().compare(
      current: PayloadComparisonOperand(current),
      baseline: PayloadComparisonOperand(baseline)
    )

    guard case .json(let json) = comparison.presentation else {
      Issue.record("Expected structural JSON comparison")
      return
    }
    #expect(
      json.differences.map(\.path.rawValue)
        == ["/added", "/changed", "/removed"]
    )
    #expect(
      json.differences.map(\.change)
        == [.added, .changed, .removed]
    )
    #expect(!json.isTruncated)
  }

  @Test("A live inbound payload can compare with a durable published row")
  func durablePublishedBaselineIdentity() async {
    let current = message(
      ordinal: 2,
      payload: Data("current".utf8)
    )
    let baseline = PayloadComparisonOperand(
      id: .durable(42),
      direction: .published,
      payload: Data("published".utf8)
    )

    let comparison = await PayloadComparisonEngine().compare(
      current: PayloadComparisonOperand(current),
      baseline: baseline
    )

    #expect(comparison.currentID == .live(current.id))
    #expect(comparison.baselineID == .durable(42))
  }

  @Test("UTF-8 text comparison reports line additions and removals")
  func textLineChanges() async {
    let baseline = message(
      ordinal: 1,
      payload: Data("alpha\nold\nsame".utf8)
    )
    let current = message(
      ordinal: 2,
      payload: Data("alpha\nnew\nsame\nadded".utf8)
    )

    let comparison = await PayloadComparisonEngine().compare(
      current: PayloadComparisonOperand(current),
      baseline: PayloadComparisonOperand(baseline)
    )

    guard case .text(let text) = comparison.presentation else {
      Issue.record("Expected text line comparison")
      return
    }
    #expect(text.lines.map(\.change) == [.removed, .added, .added])
    #expect(text.lines.map(\.text) == ["old", "new", "added"])
    #expect(!text.isTruncated)
  }

  @Test("Invalid UTF-8 remains a bounded byte comparison")
  func invalidUTF8ByteSummary() async {
    let baseline = message(
      ordinal: 1,
      payload: Data([0xFF, 0x00, 0x01, 0x02])
    )
    let current = message(
      ordinal: 2,
      payload: Data([0xFF, 0x80, 0x01, 0x03, 0x04])
    )
    let engine = PayloadComparisonEngine(
      limits: .init(maximumHexBytes: 3)
    )

    let comparison = await engine.compare(
      current: PayloadComparisonOperand(current),
      baseline: PayloadComparisonOperand(baseline)
    )

    guard case .bytes(let bytes) = comparison.presentation else {
      Issue.record("Expected raw byte comparison")
      return
    }
    #expect(bytes.baselineHex == "ff 00 01")
    #expect(bytes.currentHex == "ff 80 01")
    #expect(bytes.baselineByteCount == 4)
    #expect(bytes.currentByteCount == 5)
    #expect(bytes.comparedByteCount == 3)
    #expect(bytes.differingByteCount == 1)
    #expect(bytes.isTruncated)
  }

  @Test("Adversarial JSON output is bounded by count and preview size")
  func boundedJSONOutput() async throws {
    let baselineObject = Dictionary(
      uniqueKeysWithValues: (0..<100).map {
        ("key-\($0)", String(repeating: "a", count: 10_000))
      }
    )
    let currentObject = Dictionary(
      uniqueKeysWithValues: (0..<100).map {
        ("key-\($0)", String(repeating: "b", count: 10_000))
      }
    )
    let baseline = message(
      ordinal: 1,
      payload: try JSONSerialization.data(
        withJSONObject: baselineObject,
        options: [.sortedKeys]
      )
    )
    let current = message(
      ordinal: 2,
      payload: try JSONSerialization.data(
        withJSONObject: currentObject,
        options: [.sortedKeys]
      )
    )
    let engine = PayloadComparisonEngine(
      limits: .init(
        maximumDifferences: 3,
        maximumValuePreviewCharacters: 4
      )
    )

    let comparison = await engine.compare(
      current: PayloadComparisonOperand(current),
      baseline: PayloadComparisonOperand(baseline)
    )

    guard case .json(let json) = comparison.presentation else {
      Issue.record("Expected JSON comparison")
      return
    }
    #expect(json.differences.count == 3)
    #expect(json.isTruncated)
    #expect(
      json.differences.allSatisfy {
        ($0.baselinePreview?.count ?? 0) <= 4
          && ($0.currentPreview?.count ?? 0) <= 4
      }
    )
  }

  private func message(
    ordinal: UInt64,
    payload: Data
  ) -> PayloadMessage {
    PayloadMessage(
      id: PayloadMessageID(
        connectionEpoch: ConnectionEpochID(),
        ordinal: ordinal,
        direction: .received
      ),
      topicID: BrokerTopicID(
        brokerID: UUID(),
        fullTopic: "devices/pump"
      ),
      receivedAtMicroseconds: Int64(ordinal),
      qos: .atLeastOnce,
      retained: false,
      payload: payload
    )
  }
}
