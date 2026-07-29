import Foundation

public enum HistoryRetentionPolicyValidationError:
  Error,
  Equatable,
  Sendable
{
  case topicMessageLimit(Int)
  case brokerByteLimit(Int64)
  case payloadByteLimit(Int)
  case payloadExceedsBrokerSlack(
    payloadByteLimit: Int,
    brokerByteLimit: Int64
  )
  case messagePruneBatchLimit(Int)
  case vacuumPageLimit(Int)
}

public struct HistoryRetentionPolicy:
  Codable,
  Equatable,
  Sendable
{
  public static let maximumAppendMessageCount = 500
  public static let topicMessageLimitBounds = 1...1_000_000
  public static let brokerByteLimitBounds: ClosedRange<Int64> =
    (16 * 1_024 * 1_024)...(4 * 1_024 * 1_024 * 1_024 * 1_024)
  public static let payloadByteLimitBounds = 1...(64 * 1_024 * 1_024)
  public static let messagePruneBatchLimitBounds = 1...5_000
  public static let vacuumPageLimitBounds = 1...8_192

  public static let `default` = HistoryRetentionPolicy(
    uncheckedTopicMessageLimit: 1_000,
    brokerByteLimit: 250 * 1_024 * 1_024,
    payloadByteLimit: 1_048_576,
    messagePruneBatchLimit: 5_000,
    vacuumPageLimit: 8_192
  )

  public let topicMessageLimit: Int
  public let brokerByteLimit: Int64
  public let payloadByteLimit: Int
  public let messagePruneBatchLimit: Int
  public let vacuumPageLimit: Int

  public init(
    topicMessageLimit: Int,
    brokerByteLimit: Int64,
    payloadByteLimit: Int,
    messagePruneBatchLimit: Int,
    vacuumPageLimit: Int
  ) throws {
    guard Self.topicMessageLimitBounds.contains(topicMessageLimit) else {
      throw HistoryRetentionPolicyValidationError.topicMessageLimit(
        topicMessageLimit
      )
    }
    guard Self.brokerByteLimitBounds.contains(brokerByteLimit) else {
      throw HistoryRetentionPolicyValidationError.brokerByteLimit(
        brokerByteLimit
      )
    }
    guard Self.payloadByteLimitBounds.contains(payloadByteLimit) else {
      throw HistoryRetentionPolicyValidationError.payloadByteLimit(
        payloadByteLimit
      )
    }
    guard
      Self.messagePruneBatchLimitBounds.contains(messagePruneBatchLimit)
    else {
      throw HistoryRetentionPolicyValidationError.messagePruneBatchLimit(
        messagePruneBatchLimit
      )
    }
    guard Self.vacuumPageLimitBounds.contains(vacuumPageLimit) else {
      throw HistoryRetentionPolicyValidationError.vacuumPageLimit(
        vacuumPageLimit
      )
    }
    guard Int64(payloadByteLimit) <= brokerByteLimit / 10 else {
      throw HistoryRetentionPolicyValidationError.payloadExceedsBrokerSlack(
        payloadByteLimit: payloadByteLimit,
        brokerByteLimit: brokerByteLimit
      )
    }
    self.init(
      uncheckedTopicMessageLimit: topicMessageLimit,
      brokerByteLimit: brokerByteLimit,
      payloadByteLimit: payloadByteLimit,
      messagePruneBatchLimit: messagePruneBatchLimit,
      vacuumPageLimit: vacuumPageLimit
    )
  }

  public var brokerPruneHighWaterBytes: Int64 {
    brokerByteLimit * 3 / 5
  }

  public var brokerPruneTargetBytes: Int64 {
    brokerByteLimit / 2
  }

  public var maximumAppendPayloadBytes: Int64 {
    brokerByteLimit / 10
  }

  private init(
    uncheckedTopicMessageLimit topicMessageLimit: Int,
    brokerByteLimit: Int64,
    payloadByteLimit: Int,
    messagePruneBatchLimit: Int,
    vacuumPageLimit: Int
  ) {
    self.topicMessageLimit = topicMessageLimit
    self.brokerByteLimit = brokerByteLimit
    self.payloadByteLimit = payloadByteLimit
    self.messagePruneBatchLimit = messagePruneBatchLimit
    self.vacuumPageLimit = vacuumPageLimit
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      topicMessageLimit: values.decode(
        Int.self,
        forKey: .topicMessageLimit
      ),
      brokerByteLimit: values.decode(
        Int64.self,
        forKey: .brokerByteLimit
      ),
      payloadByteLimit: values.decode(
        Int.self,
        forKey: .payloadByteLimit
      ),
      messagePruneBatchLimit: values.decode(
        Int.self,
        forKey: .messagePruneBatchLimit
      ),
      vacuumPageLimit: values.decode(
        Int.self,
        forKey: .vacuumPageLimit
      )
    )
  }
}
