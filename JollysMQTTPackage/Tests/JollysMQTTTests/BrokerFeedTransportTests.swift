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

  @Test("A full publish queue rejects before any command can reach transport")
  func boundedPublishCommands() async throws {
    let queue = BrokerFeedPublishCommandQueue(capacity: 1)
    let first = BrokerPublishRequest.fixture(id: 1)
    let rejected = BrokerPublishRequest.fixture(id: 2)
    let firstResult = Task { await queue.submit(first) }
    await waitForPendingOperationCount(1, in: queue)

    #expect(await queue.submit(rejected) == .failure(.queueFull))
    var iterator = await queue.commands().makeAsyncIterator()
    #expect(try #require(await iterator.next()).request == first)
    await queue.close(reason: .cancelled)
    #expect(await firstResult.value == .failure(.cancelled))
  }

  @Test("Connection teardown resolves queued and in-flight operations exactly once")
  func teardownResolvesAllCommands() async throws {
    let queue = BrokerFeedPublishCommandQueue(capacity: 2)
    let first = BrokerPublishRequest.fixture(id: 1)
    let second = BrokerPublishRequest.fixture(id: 2)
    let firstResult = Task { await queue.submit(first) }
    let secondResult = Task { await queue.submit(second) }
    await waitForPendingOperationCount(2, in: queue)
    var iterator = await queue.commands().makeAsyncIterator()
    #expect(try #require(await iterator.next()).request == first)

    await queue.close(reason: .transportUnavailable)
    await queue.close(reason: .cancelled)

    #expect(await firstResult.value == .failure(.transportUnavailable))
    #expect(await secondResult.value == .failure(.transportUnavailable))
    #expect(await queue.pendingOperationCount() == 0)
  }

  @Test("A replacement connection queue cannot consume prior-generation commands")
  func connectionGenerationDoesNotLeakCommands() async throws {
    let oldQueue = BrokerFeedPublishCommandQueue(capacity: 2)
    let oldRequest = BrokerPublishRequest.fixture(id: 1)
    let oldResult = Task { await oldQueue.submit(oldRequest) }
    await waitForPendingOperationCount(1, in: oldQueue)
    await oldQueue.close(reason: .transportUnavailable)

    let newQueue = BrokerFeedPublishCommandQueue(capacity: 2)
    let newRequest = BrokerPublishRequest.fixture(id: 2)
    let newResult = Task { await newQueue.submit(newRequest) }
    await waitForPendingOperationCount(1, in: newQueue)
    var iterator = await newQueue.commands().makeAsyncIterator()

    #expect(try #require(await iterator.next()).request == newRequest)
    #expect(await oldResult.value == .failure(.transportUnavailable))
    let success = BrokerPublishSuccess(
      operationID: newRequest.operationID,
      completion: .transportAccepted,
      completedAtMicroseconds: 42
    )
    await newQueue.complete(success)
    #expect(await newResult.value == .success(success))
  }

  @Test(
    "Successful QoS completion is honest about transport acceptance and acknowledgement",
    arguments: [
      (
        JollysMQTTCore.MQTTQualityOfService.atMostOnce,
        BrokerPublishCompletion.transportAccepted
      ),
      (.atLeastOnce, .acknowledged),
      (.exactlyOnce, .acknowledged),
    ]
  )
  func qosCompletion(
    qos: JollysMQTTCore.MQTTQualityOfService,
    completion: BrokerPublishCompletion
  ) {
    #expect(BrokerPublishCompletion(successfulQoS: qos) == completion)
  }
}

private func waitForPendingOperationCount(
  _ count: Int,
  in queue: BrokerFeedPublishCommandQueue
) async {
  for _ in 0..<1_000 {
    if await queue.pendingOperationCount() == count {
      return
    }
    await Task.yield()
  }
  Issue.record("Publish submission did not reach the queue.")
}

extension BrokerPublishRequest {
  fileprivate static func fixture(id: UInt8) -> BrokerPublishRequest {
    BrokerPublishRequest(
      operationID: PublishOperationID(
        rawValue: UUID(
          uuidString: String(
            format: "00000000-0000-0000-0000-%012x",
            id
          )
        )!
      ),
      topic: "test/topic",
      payload: Data([id]),
      qos: .atMostOnce,
      retain: false
    )
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
