import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum BrokerTransport: String, Codable, CaseIterable, Hashable, Sendable {
  case tcp
  case tls
}

public enum MQTTQualityOfService: Int, Codable, CaseIterable, Hashable, Sendable {
  case atMostOnce = 0
  case atLeastOnce = 1
  case exactlyOnce = 2
}

public enum ClientIDPolicy: Codable, Hashable, Sendable {
  case stableGenerated
  case randomPerConnection
  case explicit(String)
}

public enum ReconnectPolicy: Codable, Hashable, Sendable {
  case disabled
  case exponential(initialDelaySeconds: Int, maximumDelaySeconds: Int)

  public static let standard = ReconnectPolicy.exponential(
    initialDelaySeconds: 1,
    maximumDelaySeconds: 60
  )
}

public struct SubscriptionDefinition: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let filter: String
  public let qos: MQTTQualityOfService
  public let isEnabled: Bool

  public init(
    id: UUID = UUID(),
    filter: String,
    qos: MQTTQualityOfService,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.filter = filter
    self.qos = qos
    self.isEnabled = isEnabled
  }
}

public struct BrokerProfile: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let host: String
  public let port: Int
  public let transport: BrokerTransport
  public let username: String?
  public let clientIDPolicy: ClientIDPolicy
  public let cleanSession: Bool
  public let keepAliveSeconds: Int
  public let reconnectPolicy: ReconnectPolicy
  public let subscriptions: [SubscriptionDefinition]

  public init(
    id: UUID,
    name: String,
    host: String,
    port: Int,
    transport: BrokerTransport,
    username: String?,
    clientIDPolicy: ClientIDPolicy,
    cleanSession: Bool,
    keepAliveSeconds: Int,
    reconnectPolicy: ReconnectPolicy,
    subscriptions: [SubscriptionDefinition]
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.transport = transport
    self.username = username
    self.clientIDPolicy = clientIDPolicy
    self.cleanSession = cleanSession
    self.keepAliveSeconds = keepAliveSeconds
    self.reconnectPolicy = reconnectPolicy
    self.subscriptions = subscriptions
  }

  public static func new(
    id: UUID = UUID(),
    name: String = "",
    host: String = "",
    port: Int = 1_883
  ) -> Self {
    Self(
      id: id,
      name: name,
      host: host,
      port: port,
      transport: .tcp,
      username: nil,
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [
        SubscriptionDefinition(filter: "#", qos: .atMostOnce),
        SubscriptionDefinition(filter: "$SYS/#", qos: .atMostOnce),
      ]
    )
  }

  public var endpointSummary: String {
    "\(transport.rawValue)://\(host):\(port)"
  }

  public var hasBroadSubscriptionWarning: Bool {
    subscriptions.contains {
      $0.isEnabled && ($0.filter == "#" || $0.filter == "$SYS/#")
    }
  }

  public var validationIssues: [BrokerProfileValidationIssue] {
    BrokerProfileValidator.validate(self)
  }
}

public struct BrokerProfileValidationIssue: Error, Codable, Hashable, Sendable {
  public enum Field: String, Codable, Hashable, Sendable {
    case name
    case host
    case port
    case username
    case clientID
    case session
    case keepAlive
    case reconnect
    case subscriptions
  }

  public enum Reason: String, Codable, Hashable, Sendable {
    case required
    case invalid
    case outOfRange
    case incompatible
    case duplicate
  }

  public let field: Field
  public let reason: Reason

  public init(field: Field, reason: Reason) {
    self.field = field
    self.reason = reason
  }
}

public enum BrokerProfileValidator {
  public static func validate(_ profile: BrokerProfile) -> [BrokerProfileValidationIssue] {
    var issues: [BrokerProfileValidationIssue] = []

    if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.init(field: .name, reason: .required))
    }
    if !MQTTTopicValidator.isValidHost(profile.host) {
      issues.append(.init(field: .host, reason: .invalid))
    }
    if !(1...65_535).contains(profile.port) {
      issues.append(.init(field: .port, reason: .outOfRange))
    }
    if let username = profile.username,
      username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !MQTTTopicValidator.isValidUTF8MQTTString(username)
    {
      issues.append(.init(field: .username, reason: .invalid))
    }
    switch profile.clientIDPolicy {
    case .explicit(let value) where !MQTTTopicValidator.isValidClientID(value):
      issues.append(.init(field: .clientID, reason: .invalid))
    case .randomPerConnection where !profile.cleanSession:
      issues.append(.init(field: .session, reason: .incompatible))
    default:
      break
    }
    if !(1...65_535).contains(profile.keepAliveSeconds) {
      issues.append(.init(field: .keepAlive, reason: .outOfRange))
    }
    if case .exponential(let initial, let maximum) = profile.reconnectPolicy,
      initial < 1 || maximum < initial || maximum > 86_400
    {
      issues.append(.init(field: .reconnect, reason: .outOfRange))
    }

    let enabled = profile.subscriptions.filter(\.isEnabled)
    if enabled.isEmpty {
      issues.append(.init(field: .subscriptions, reason: .required))
    }
    if enabled.contains(where: { !MQTTTopicValidator.isValidSubscriptionFilter($0.filter) }) {
      issues.append(.init(field: .subscriptions, reason: .invalid))
    }
    if Set(enabled.map(\.filter)).count != enabled.count {
      issues.append(.init(field: .subscriptions, reason: .duplicate))
    }

    return issues
  }
}

public enum MQTTTopicValidator {
  public static func isValidPublicationTopic(_ topic: String) -> Bool {
    isValidUTF8MQTTString(topic)
      && !topic.contains("+")
      && !topic.contains("#")
  }

  public static func isValidSubscriptionFilter(_ filter: String) -> Bool {
    guard isValidUTF8MQTTString(filter) else { return false }

    let levels = filter.split(separator: "/", omittingEmptySubsequences: false)
    for (index, level) in levels.enumerated() {
      if level.contains("#") && !(level == "#" && index == levels.indices.last) {
        return false
      }
      if level.contains("+") && level != "+" {
        return false
      }
    }
    return true
  }

  static func isValidHost(_ host: String) -> Bool {
    let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value == host, !value.isEmpty, value.utf8.count <= 253 else { return false }
    guard !value.contains("://"),
      !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }),
      !value.contains("/"),
      !value.contains("?"),
      !value.contains("#")
    else { return false }

    if value.first == "[", value.last == "]" {
      return isValidIPAddress(String(value.dropFirst().dropLast()), family: AF_INET6)
    }
    if value.contains(":") {
      return isValidIPAddress(value, family: AF_INET6)
    }

    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
      return isValidIPAddress(value, family: AF_INET)
    }
    return labels.allSatisfy { label in
      !label.isEmpty
        && label.utf8.count <= 63
        && label.first != "-"
        && label.last != "-"
        && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
  }

  static func isValidClientID(_ value: String) -> Bool {
    let byteCount = value.utf8.count
    return (1...128).contains(byteCount)
      && isValidUTF8MQTTString(value)
  }

  static func isValidUTF8MQTTString(_ value: String) -> Bool {
    let count = value.utf8.count
    return (1...65_535).contains(count)
      && value.unicodeScalars.allSatisfy(isPermittedMQTTScalar)
  }

  private static func isPermittedMQTTScalar(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    guard value != 0,
      !(0x0001...0x001F).contains(value),
      !(0x007F...0x009F).contains(value),
      !(0xFDD0...0xFDEF).contains(value)
    else { return false }

    let trailing = value & 0xFFFF
    return trailing != 0xFFFE && trailing != 0xFFFF
  }

  private static func isValidIPAddress(_ value: String, family: Int32) -> Bool {
    #if canImport(Darwin) || canImport(Glibc)
      if family == AF_INET {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
      }
      var address = in6_addr()
      return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    #else
      return false
    #endif
  }
}
