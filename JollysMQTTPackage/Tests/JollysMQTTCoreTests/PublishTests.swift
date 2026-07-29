import Foundation
import JollysMQTTCore
import Testing

@Suite("Publish domain")
struct PublishTests {
  @Test(
    "Text, JSON, and hex drafts produce the exact intended bytes",
    arguments: [
      (
        PublishInputMode.text,
        "Hello, MQTT",
        Data("Hello, MQTT".utf8)
      ),
      (
        PublishInputMode.json,
        #"{"value":1.25}"#,
        Data(#"{"value":1.25}"#.utf8)
      ),
      (
        PublishInputMode.hex,
        "00 ff 10\n7A",
        Data([0x00, 0xFF, 0x10, 0x7A])
      ),
    ]
  )
  func inputModeProducesPayload(
    mode: PublishInputMode,
    source: String,
    expected: Data
  ) throws {
    let draft = PublishDraft(
      topic: "factory/line/status",
      payloadSource: source,
      inputMode: mode
    )

    #expect(try draft.validatedRequestPayload() == expected)
  }

  @Test(
    "Invalid topics and input are rejected before a request exists",
    arguments: [
      (
        PublishDraft(topic: "factory/+", payloadSource: "ok"),
        PublishDraftValidationError.invalidTopic
      ),
      (
        PublishDraft(
          topic: "factory/status",
          payloadSource: #"{"unterminated":"#,
          inputMode: .json
        ),
        .invalidJSON
      ),
      (
        PublishDraft(
          topic: "factory/status",
          payloadSource: "0g",
          inputMode: .hex
        ),
        .invalidHex
      ),
      (
        PublishDraft(
          topic: "factory/status",
          payloadSource: "0",
          inputMode: .hex
        ),
        .invalidHex
      ),
    ]
  )
  func invalidDraftIsRejected(
    draft: PublishDraft,
    expected: PublishDraftValidationError
  ) {
    #expect(throws: expected) {
      try draft.validatedRequestPayload()
    }
  }

  @Test("Payload byte limits apply after mode decoding")
  func decodedPayloadLimit() {
    let draft = PublishDraft(
      topic: "factory/status",
      payloadSource: "00 01 02",
      inputMode: .hex
    )

    #expect(
      throws:
        PublishDraftValidationError.payloadTooLarge(
          byteCount: 3,
          maximumByteCount: 2
        )
    ) {
      try draft.validatedRequestPayload(maximumByteCount: 2)
    }
  }

  @Test("Retained zero-byte publishes require the destructive-action flow")
  func retainedDeletionRequiresConfirmation() {
    let draft = PublishDraft(
      topic: "factory/status",
      payloadSource: "",
      retain: true
    )

    #expect(
      throws: PublishDraftValidationError.retainedDeletionRequiresConfirmation
    ) {
      try draft.validatedRequestPayload()
    }
  }

  @Test("Successful draft history is exact, newest-first, deduplicated, and bounded")
  func successfulHistoryIsBounded() {
    let first = PublishDraft(
      topic: "factory/status",
      payloadSource: "on",
      qos: .atMostOnce
    )
    let distinctQoS = PublishDraft(
      topic: first.topic,
      payloadSource: first.payloadSource,
      qos: .atLeastOnce
    )
    let third = PublishDraft(topic: "factory/mode", payloadSource: "auto")
    var history = PublishDraftHistory(capacity: 2)

    history = history.recording(.fixture(id: 1, draft: first))
    history = history.recording(.fixture(id: 2, draft: distinctQoS))
    history = history.recording(.fixture(id: 3, draft: first))
    history = history.recording(.fixture(id: 4, draft: third))

    #expect(history.entries.map(\.draft) == [third, first])
    #expect(history.entries.map(\.id) == [.fixture(4), .fixture(3)])
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

extension SuccessfulPublishDraft {
  fileprivate static func fixture(
    id: UInt8,
    draft: PublishDraft
  ) -> SuccessfulPublishDraft {
    SuccessfulPublishDraft(
      id: .fixture(id),
      draft: draft,
      completedAtMicroseconds: Int64(id)
    )
  }
}
