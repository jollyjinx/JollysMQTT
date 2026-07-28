import Foundation
import Testing
@testable import JollysMQTTTransport

@Suite("Transport boundary")
struct TransportModuleTests {
    @Test("Transport exposes only the domain module as an internal layer")
    func moduleBoundaries() {
        #expect(TransportModule.dependencies == ["JollysMQTTCore"])
    }

    @Test("Production TLS uses Network.framework full verification and default roots")
    func productionTLSPolicy() {
        let client = MQTTTransportClient()

        #expect(MQTTTransportClient.usesAppleTransportServices)
        #expect(client.usesDefaultSystemTrustRoots)
    }

    @Test("Failures have redacted descriptions")
    func redactedFailures() {
        let description = MQTTTransportFailure.tlsTrustFailed.description

        #expect(description == "The broker certificate is not trusted.")
        #expect(!description.contains("host"))
        #expect(!description.contains("certificate path"))
    }

    @Test("A TCP failure on a TLS endpoint is not mislabeled as trust")
    func nonTrustTLSFailure() {
        let failure = MQTTTransportClient.map(
            POSIXError(.ECONNREFUSED),
            tlsEnabled: true
        )

        #expect(failure == .brokerUnavailable)
    }
}

@Suite(
    "mqtt-nio compatibility against isolated Mosquitto",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["JOLLYSMQTT_MQTT_INTEGRATION"] == "1")
)
struct MQTTTransportIntegrationTests {
    @Test("MQTT 3.1.1 wildcard receive and QoS 0, 1, and 2 publish")
    func publishAndReceiveEveryQoS() async throws {
        let fixture = try await MosquittoFixture.start()
        do {
            let client = MQTTTransportClient()
            let endpoint = fixture.plainEndpoint
            let clientID = "jolly-ticket2-qos"

            let messages = try await client.withConnection(
                to: endpoint,
                sessionPolicy: .clean(clientID: clientID)
            ) { connection in
                try await connection.withSubscription(
                    to: [
                        MQTTSubscriptionFilter(
                            topicFilter: "ticket2/#",
                            qos: .exactlyOnce
                        ),
                    ]
                ) { subscription in
                    for qos in MQTTQualityOfService.allCases {
                        try await connection.publish(
                            topic: "ticket2/qos/\(qos.rawValue)",
                            payload: Data("payload-\(qos.rawValue)".utf8),
                            qos: qos
                        )
                    }

                    var received: [MQTTReceivedMessage] = []
                    for try await message in subscription {
                        received.append(message)
                        if received.count == MQTTQualityOfService.allCases.count {
                            return received
                        }
                    }
                    return received
                }
            }

            #expect(messages.map(\.topic) == [
                "ticket2/qos/0",
                "ticket2/qos/1",
                "ticket2/qos/2",
            ])
            #expect(messages.map(\.qos) == [
                .atMostOnce,
                .atLeastOnce,
                .exactlyOnce,
            ])
            #expect(messages.map { String(decoding: $0.payload, as: UTF8.self) } == [
                "payload-0",
                "payload-1",
                "payload-2",
            ])

            try await fixture.waitForLog(containing: "Client \(clientID) [")
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    @Test("Clean and persistent in-process session ownership")
    func inProcessSession() async throws {
        let fixture = try await MosquittoFixture.start()
        do {
            let endpoint = fixture.plainEndpoint
            let client = MQTTTransportClient()
            let clientID = "jolly-ticket2-session"

            let cleanWasResumed = try await client.withConnection(
                to: endpoint,
                sessionPolicy: .clean(clientID: clientID)
            ) { connection in
                connection.resumedSession
            }
            #expect(cleanWasResumed == false)

            let session = MQTTInProcessSession(clientID: clientID)
            let firstPersistentWasResumed = try await client.withConnection(
                to: endpoint,
                sessionPolicy: .inProcessPersistent(session)
            ) { connection in
                connection.resumedSession
            }
            #expect(firstPersistentWasResumed == false)

            let secondPersistentWasResumed = try await client.withConnection(
                to: endpoint,
                sessionPolicy: .inProcessPersistent(session)
            ) { connection in
                connection.resumedSession
            }
            #expect(secondPersistentWasResumed)

            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    @Test("Trusted local CA proves NIOTS TLS wiring")
    func trustedTLSFixture() async throws {
        let fixture = try await MosquittoFixture.start()
        do {
            let rootDERPath = fixture.rootCertificateDER.path
            let client = MQTTTransportClient(
                trustPolicy: .testRootDER(path: rootDERPath)
            )

            try await client.withConnection(
                to: fixture.tlsEndpoint,
                sessionPolicy: .clean(clientID: "jolly-ticket2-trusted-tls")
            ) { _ in }

            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    @Test("Untrusted certificate is a typed redacted failure")
    func untrustedTLSFixture() async throws {
        let fixture = try await MosquittoFixture.start()
        let client = MQTTTransportClient(
            connectTimeout: .seconds(1),
            responseTimeout: .seconds(1)
        )
        let error = await #expect(throws: MQTTTransportFailure.self) {
            try await client.withConnection(
                to: fixture.tlsEndpoint,
                sessionPolicy: .clean(clientID: "jolly-ticket2-untrusted-tls")
            ) { _ in }
        }

        #expect(error == .tlsTrustFailed)
        #expect(error?.description == "The broker certificate is not trusted.")
        #expect(!(error?.description.contains(fixture.directory.path) ?? true))

        await fixture.stop()
    }

    @Test(
        "Cancellation closes an active subscription",
        .timeLimit(.minutes(1))
    )
    func cancelActiveSubscription() async throws {
        let fixture = try await MosquittoFixture.start()
        do {
            let clientID = "jolly-ticket2-cancel-subscription"
            let endpoint = fixture.plainEndpoint
            let gate = AsyncGate()
            let client = MQTTTransportClient()

            let connectionTask = Task {
                try await client.withConnection(
                    to: endpoint,
                    sessionPolicy: .clean(clientID: clientID)
                ) { connection in
                    try await connection.withSubscription(
                        to: [
                            MQTTSubscriptionFilter(
                                topicFilter: "ticket2/cancellation/#",
                                qos: .atLeastOnce
                            ),
                        ]
                    ) { subscription in
                        try await connection.publish(
                            topic: "ticket2/cancellation/ready",
                            payload: Data(),
                            qos: .atLeastOnce
                        )
                        for try await message in subscription
                        where message.topic == "ticket2/cancellation/ready" {
                            await gate.open()
                            try await Task.sleep(for: .seconds(60))
                        }
                    }
                }
            }

            await gate.wait()
            let started = ContinuousClock.now
            connectionTask.cancel()
            let result = await connectionTask.result
            let elapsed = started.duration(to: .now)

            switch result {
            case .failure(is CancellationError):
                break
            default:
                Issue.record("Expected CancellationError, got \(result)")
            }
            #expect(elapsed < .seconds(1))
            try await fixture.waitForLog(containing: "Client \(clientID) [")

            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    @Test(
        "Cancellation during connection closes the pending channel",
        .timeLimit(.minutes(1))
    )
    func cancelPendingConnection() async throws {
        let fixture = try await SilentTCPFixture.start()
        do {
            let client = MQTTTransportClient(
                trustPolicy: .systemDefault,
                connectTimeout: .milliseconds(250),
                responseTimeout: .milliseconds(250)
            )
            let endpoint = MQTTBrokerEndpoint(
                host: "127.0.0.1",
                port: fixture.port
            )

            let task = Task {
                try await client.withConnection(
                    to: endpoint,
                    sessionPolicy: .clean(clientID: "jolly-ticket2-cancel-connect")
                ) { _ in
                    Issue.record("The silent server must never complete MQTT connect")
                }
            }

            try await fixture.waitForState("accepted")
            let started = ContinuousClock.now
            task.cancel()
            let result = await task.result
            let elapsed = started.duration(to: .now)

            switch result {
            case .failure(is CancellationError):
                break
            default:
                Issue.record("Expected CancellationError, got \(result)")
            }
            try await fixture.waitForState("closed")
            #expect(elapsed < .seconds(1))

            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}
