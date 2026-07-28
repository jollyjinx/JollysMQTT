import Foundation
import Testing

@testable import JollysMQTTCore

@Suite("Broker profile defaults and validation")
struct BrokerProfileTests {
  @Test("A new profile explicitly subscribes to public and system topics")
  func newProfileDefaults() {
    let profile = BrokerProfile.new(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)

    #expect(profile.transport == .tcp)
    #expect(profile.port == 1_883)
    #expect(profile.subscriptions.map(\.filter) == ["#", "$SYS/#"])
    #expect(profile.subscriptions.allSatisfy { $0.qos == .atMostOnce && $0.isEnabled })
    #expect(profile.hasBroadSubscriptionWarning)
  }

  @Test(
    "Invalid endpoints are rejected",
    arguments: [
      ("", 1_883),
      ("mqtt://broker.example", 1_883),
      ("broker example", 1_883),
      ("-broker.example", 1_883),
      (":", 1_883),
      (":::", 1_883),
      ("[:::]", 1_883),
      ("999.1.1.1", 1_883),
      ("broker.example", 0),
      ("broker.example", 65_536),
    ]
  )
  func invalidEndpoints(host: String, port: Int) {
    let profile = BrokerProfile.new(name: "Broker", host: host, port: port)
    #expect(
      profile.validationIssues.contains {
        $0.field == (port == 0 || port == 65_536 ? .port : .host)
      }
    )
  }

  @Test(
    "Publication topics reject wildcards and malformed MQTT strings",
    arguments: [
      "",
      "sensors/+",
      "sensors/#",
      "sensors/\0value",
      "sensors/\u{0001}",
      "sensors/\u{007F}",
      "sensors/" + String(UnicodeScalar(0xFDD0)!),
      "sensors/" + String(UnicodeScalar(0x1FFFF)!),
    ]
  )
  func invalidPublicationTopics(topic: String) {
    #expect(MQTTTopicValidator.isValidPublicationTopic(topic) == false)
  }

  @Test(
    "Subscription filters reject misplaced wildcards",
    arguments: [
      "",
      "sensors/#/temperature",
      "sensors/room+",
      "sensors/foo#",
      "sensors/\u{0001}",
      "sensors/" + String(UnicodeScalar(0xFDD0)!),
    ]
  )
  func invalidSubscriptionFilters(filter: String) {
    #expect(MQTTTopicValidator.isValidSubscriptionFilter(filter) == false)
  }

  @Test(
    "Incompatible session and explicit client identifier configurations are rejected",
    arguments: [
      (ClientIDPolicy.randomPerConnection, false, BrokerProfileValidationIssue.Field.session),
      (ClientIDPolicy.explicit(""), true, BrokerProfileValidationIssue.Field.clientID),
      (
        ClientIDPolicy.explicit("client\u{0001}"), true, BrokerProfileValidationIssue.Field.clientID
      ),
      (
        ClientIDPolicy.explicit("client" + String(UnicodeScalar(0xFDD0)!)),
        true,
        BrokerProfileValidationIssue.Field.clientID
      ),
    ]
  )
  func incompatibleSessionAndClientID(
    policy: ClientIDPolicy,
    cleanSession: Bool,
    expectedField: BrokerProfileValidationIssue.Field
  ) {
    let profile = BrokerProfile(
      id: UUID(),
      name: "Broker",
      host: "broker.example",
      port: 1_883,
      transport: .tcp,
      username: nil,
      clientIDPolicy: policy,
      cleanSession: cleanSession,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [SubscriptionDefinition(filter: "site/#", qos: .atMostOnce)]
    )

    #expect(profile.validationIssues.contains { $0.field == expectedField })
  }

  @Test(
    "Authentication principals must be well-formed MQTT UTF-8 strings",
    arguments: [
      "",
      " ",
      "operator\0admin",
      "operator\u{0001}",
      "operator" + String(UnicodeScalar(0xFDD0)!),
    ]
  )
  func invalidAuthenticationPrincipal(username: String) {
    let profile = BrokerProfile(
      id: UUID(),
      name: "Broker",
      host: "broker.example",
      port: 1_883,
      transport: .tls,
      username: username,
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [SubscriptionDefinition(filter: "site/#", qos: .atMostOnce)]
    )

    #expect(profile.validationIssues.contains { $0.field == .username })
  }

  @Test("Authentication principals cannot exceed the MQTT UTF-8 byte limit")
  func oversizedAuthenticationPrincipal() {
    let profile = BrokerProfile(
      id: UUID(),
      name: "Broker",
      host: "broker.example",
      port: 1_883,
      transport: .tls,
      username: String(repeating: "a", count: 65_536),
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [SubscriptionDefinition(filter: "site/#", qos: .atMostOnce)]
    )

    #expect(profile.validationIssues.contains { $0.field == .username })
  }
}
