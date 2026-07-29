import Foundation

public enum PublishInputMode: String, Codable, CaseIterable, Sendable {
  case text
  case json
  case hex
}

public enum PublishDraftValidationError: Error, Equatable, Sendable {
  case invalidTopic
  case invalidJSON
  case invalidHex
  case retainedDeletionRequiresConfirmation
  case payloadTooLarge(byteCount: Int, maximumByteCount: Int)
}

public struct PublishDraft: Codable, Equatable, Sendable {
  public let topic: String
  public let payloadSource: String
  public let inputMode: PublishInputMode
  public let qos: MQTTQualityOfService
  public let retain: Bool

  public init(
    topic: String = "",
    payloadSource: String = "",
    inputMode: PublishInputMode = .text,
    qos: MQTTQualityOfService = .atMostOnce,
    retain: Bool = false
  ) {
    self.topic = topic
    self.payloadSource = payloadSource
    self.inputMode = inputMode
    self.qos = qos
    self.retain = retain
  }

  public func validatedRequestPayload(
    maximumByteCount: Int = 1_048_576
  ) throws -> Data {
    precondition(maximumByteCount >= 0)
    guard MQTTTopicValidator.isValidPublicationTopic(topic) else {
      throw PublishDraftValidationError.invalidTopic
    }

    let payload: Data
    switch inputMode {
    case .text:
      payload = Data(payloadSource.utf8)
    case .json:
      payload = Data(payloadSource.utf8)
      do {
        _ = try JSONSerialization.jsonObject(
          with: payload,
          options: [.fragmentsAllowed]
        )
      } catch {
        throw PublishDraftValidationError.invalidJSON
      }
    case .hex:
      payload = try Self.decodeHex(payloadSource)
    }

    guard payload.count <= maximumByteCount else {
      throw PublishDraftValidationError.payloadTooLarge(
        byteCount: payload.count,
        maximumByteCount: maximumByteCount
      )
    }
    guard !retain || !payload.isEmpty else {
      throw PublishDraftValidationError.retainedDeletionRequiresConfirmation
    }
    return payload
  }

  public func formattedJSON() throws -> String {
    guard inputMode == .json else {
      throw PublishDraftValidationError.invalidJSON
    }
    let payload = Data(payloadSource.utf8)
    do {
      let value = try JSONSerialization.jsonObject(
        with: payload,
        options: [.fragmentsAllowed]
      )
      let formatted = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
      )
      return String(decoding: formatted, as: UTF8.self)
    } catch {
      throw PublishDraftValidationError.invalidJSON
    }
  }

  private static func decodeHex(_ source: String) throws -> Data {
    var nibbles: [UInt8] = []
    nibbles.reserveCapacity(source.utf8.count)
    for scalar in source.unicodeScalars {
      switch scalar.value {
      case 0x30...0x39:
        nibbles.append(UInt8(scalar.value - 0x30))
      case 0x41...0x46:
        nibbles.append(UInt8(scalar.value - 0x41 + 10))
      case 0x61...0x66:
        nibbles.append(UInt8(scalar.value - 0x61 + 10))
      case 0x09, 0x0A, 0x0D, 0x20:
        continue
      default:
        throw PublishDraftValidationError.invalidHex
      }
    }
    guard nibbles.count.isMultiple(of: 2) else {
      throw PublishDraftValidationError.invalidHex
    }
    var payload = Data()
    payload.reserveCapacity(nibbles.count / 2)
    for index in stride(from: 0, to: nibbles.count, by: 2) {
      payload.append(nibbles[index] << 4 | nibbles[index + 1])
    }
    return payload
  }
}

public struct PublishOperationID: Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

public struct BrokerPublishRequest: Equatable, Sendable {
  public let operationID: PublishOperationID
  public let topic: String
  public let payload: Data
  public let qos: MQTTQualityOfService
  public let retain: Bool
  public let expectedBrokerID: UUID?
  public let expectedConnectionEpoch: ConnectionEpochID?

  public init(
    operationID: PublishOperationID,
    topic: String,
    payload: Data,
    qos: MQTTQualityOfService,
    retain: Bool,
    expectedBrokerID: UUID? = nil,
    expectedConnectionEpoch: ConnectionEpochID? = nil
  ) {
    self.operationID = operationID
    self.topic = topic
    self.payload = payload
    self.qos = qos
    self.retain = retain
    self.expectedBrokerID = expectedBrokerID
    self.expectedConnectionEpoch = expectedConnectionEpoch
  }
}

public enum BrokerPublishCompletion: Equatable, Sendable {
  case transportAccepted
  case acknowledged

  public init(successfulQoS qos: MQTTQualityOfService) {
    self =
      qos == .atMostOnce
      ? .transportAccepted
      : .acknowledged
  }
}

public struct BrokerPublishSuccess: Equatable, Sendable {
  public let operationID: PublishOperationID
  public let completion: BrokerPublishCompletion
  public let completedAtMicroseconds: Int64

  public init(
    operationID: PublishOperationID,
    completion: BrokerPublishCompletion,
    completedAtMicroseconds: Int64
  ) {
    self.operationID = operationID
    self.completion = completion
    self.completedAtMicroseconds = completedAtMicroseconds
  }
}

public enum BrokerPublishFailure: Error, Equatable, Sendable {
  case invalidDraft(PublishDraftValidationError)
  case notConnected
  case queueFull
  case transportUnavailable
  case cancelled
  case connectionChanged
}

public typealias BrokerPublishResult =
  Result<BrokerPublishSuccess, BrokerPublishFailure>

public protocol BrokerPublishing: Sendable {
  func publish(_ request: BrokerPublishRequest) async -> BrokerPublishResult
}

public struct SuccessfulPublishDraft: Codable, Equatable, Identifiable, Sendable {
  public let id: PublishOperationID
  public let draft: PublishDraft
  public let completedAtMicroseconds: Int64

  public init(
    id: PublishOperationID,
    draft: PublishDraft,
    completedAtMicroseconds: Int64
  ) {
    self.id = id
    self.draft = draft
    self.completedAtMicroseconds = completedAtMicroseconds
  }
}

public struct PublishDraftHistory: Codable, Equatable, Sendable {
  public let capacity: Int
  public let entries: [SuccessfulPublishDraft]

  public init(capacity: Int = 20, entries: [SuccessfulPublishDraft] = []) {
    precondition(capacity > 0)
    self.capacity = capacity
    var normalizedEntries: [SuccessfulPublishDraft] = []
    for entry in entries.reversed() {
      normalizedEntries.removeAll { $0.draft == entry.draft }
      normalizedEntries.insert(entry, at: 0)
      if normalizedEntries.count > capacity {
        normalizedEntries.removeLast(normalizedEntries.count - capacity)
      }
    }
    self.entries = normalizedEntries
  }

  public func recording(
    _ entry: SuccessfulPublishDraft
  ) -> PublishDraftHistory {
    PublishDraftHistory(
      capacity: capacity,
      entries: [entry] + entries
    )
  }
}
