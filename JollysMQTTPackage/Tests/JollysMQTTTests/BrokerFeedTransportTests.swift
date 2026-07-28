import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import Testing

@testable import JollysMQTT

@Suite("Broker feed transport composition")
struct BrokerFeedTransportTests {
  @Test("Generated client IDs are deterministic and MQTT 3.1.1 portable")
  func stableClientID() {
    let installationID = UUID(
      uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    let profile = BrokerProfile.feedTransportTest(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    let first = MQTTBrokerFeedAttempt.clientID(
      for: profile,
      installationID: installationID
    )
    let second = MQTTBrokerFeedAttempt.clientID(
      for: profile,
      installationID: installationID
    )

    #expect(first == second)
    #expect(first.count == 23)
    #expect(first.hasPrefix("jm-"))
  }

  @Test("Random-per-connection IDs change and remain portable")
  func randomClientID() {
    let profile = BrokerProfile.feedTransportTest(
      clientIDPolicy: .randomPerConnection
    )
    let first = MQTTBrokerFeedAttempt.clientID(
      for: profile,
      installationID: UUID(),
      randomID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    let second = MQTTBrokerFeedAttempt.clientID(
      for: profile,
      installationID: UUID(),
      randomID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    #expect(first != second)
    #expect(first.count == 23)
    #expect(second.count == 23)
  }

  @Test("Explicit client IDs are preserved exactly")
  func explicitClientID() {
    let profile = BrokerProfile.feedTransportTest(
      clientIDPolicy: .explicit("plant-floor-console")
    )

    #expect(
      MQTTBrokerFeedAttempt.clientID(
        for: profile,
        installationID: UUID()
      ) == "plant-floor-console"
    )
  }

  @Test("Persistent reconnects retain one in-process session identity")
  func persistentSessionIdentity() async throws {
    let attempt = MQTTBrokerFeedAttempt(
      credentialResolver: UnusedCredentialResolver(),
      installationID: UUID()
    )
    let profile = BrokerProfile.feedTransportTest(cleanSession: false)

    let first = await attempt.sessionPolicy(for: profile)
    let second = await attempt.sessionPolicy(for: profile)
    let firstSession = try #require(first.persistentSession)
    let secondSession = try #require(second.persistentSession)

    #expect(firstSession === secondSession)
  }

  @Test("History identity is stable for equivalent endpoints and password rotation")
  func historySourceIdentity() {
    let id = UUID()
    let expanded = BrokerProfile.feedTransportTest(
      id: id,
      host: "[2001:0db8:0:0:0:0:0:1]",
      username: "operator"
    )
    let compressed = BrokerProfile.feedTransportTest(
      id: id,
      host: "2001:db8::1",
      username: "operator"
    )
    let otherPrincipal = BrokerProfile.feedTransportTest(
      id: id,
      host: "2001:db8::1",
      username: "viewer"
    )

    #expect(
      MQTTBrokerFeedAttempt.historySourceID(for: expanded)
        == MQTTBrokerFeedAttempt.historySourceID(for: compressed)
    )
    #expect(
      MQTTBrokerFeedAttempt.historySourceID(for: compressed)
        != MQTTBrokerFeedAttempt.historySourceID(for: otherPrincipal)
    )
  }

  @Test(
    "Every transport failure maps to the expected feed failure",
    arguments: [
      (MQTTTransportFailure.invalidConfiguration, BrokerFeedFailure.invalidConfiguration),
      (MQTTTransportFailure.authenticationRejected, .authenticationRejected),
      (MQTTTransportFailure.dnsResolutionFailed, .dnsResolutionFailed),
      (MQTTTransportFailure.networkUnavailable, .networkUnavailable),
      (MQTTTransportFailure.transportFailure, .transportUnavailable),
      (MQTTTransportFailure.brokerUnavailable, .brokerUnavailable),
      (MQTTTransportFailure.tlsTrustFailed, .trustRejected),
      (MQTTTransportFailure.subscriptionRejected, .subscriptionRejected),
      (MQTTTransportFailure.sessionAlreadyInUse, .sessionAlreadyInUse),
      (MQTTTransportFailure.timedOut, .transportUnavailable),
      (MQTTTransportFailure.connectionClosed, .transportUnavailable),
      (MQTTTransportFailure.protocolFailure, .protocolFailure),
    ]
  )
  func transportFailureMapping(
    transport: MQTTTransportFailure,
    expected: BrokerFeedFailure
  ) {
    #expect(transport.feedFailure == expected)
  }

  @Test("The publish command seam is bounded and terminally closable")
  func boundedPublishCommands() async {
    let queue = BrokerFeedPublishCommandQueue(capacity: 1)
    let command = BrokerFeedPublishCommand(
      topic: "test/topic",
      payload: Data(),
      qos: .atMostOnce,
      retain: false
    )

    #expect(await queue.enqueue(command) == .accepted)
    #expect(await queue.enqueue(command) == .queueFull)
    await queue.close()
    #expect(await queue.enqueue(command) == .closed)
  }
}

private struct UnusedCredentialResolver: ConnectionCredentialResolving {
  func withCredential<Result: Sendable>(
    for profileID: UUID,
    expectedRevision: UInt64,
    operation: @Sendable (TransientCredential) async throws -> Result
  ) async throws -> Result {
    throw CredentialRepositoryError.missing
  }
}

extension MQTTSessionPolicy {
  fileprivate var persistentSession: MQTTInProcessSession? {
    guard case .inProcessPersistent(let session) = self else { return nil }
    return session
  }
}

extension BrokerProfile {
  fileprivate static func feedTransportTest(
    id: UUID = UUID(),
    host: String = "broker.example",
    username: String? = nil,
    clientIDPolicy: ClientIDPolicy = .stableGenerated,
    cleanSession: Bool = true
  ) -> BrokerProfile {
    BrokerProfile(
      id: id,
      name: "Test",
      host: host,
      port: 1_883,
      transport: .tcp,
      username: username,
      clientIDPolicy: clientIDPolicy,
      cleanSession: cleanSession,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [
        SubscriptionDefinition(filter: "#", qos: .atMostOnce)
      ]
    )
  }
}
