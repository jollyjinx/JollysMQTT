import Foundation
import MQTTNIO
import NIOCore
import NIOTransportServices
import Network
import Security
import Synchronization

public struct MQTTBrokerEndpoint: Equatable, Sendable {
    public enum Security: Equatable, Sendable {
        case plainTCP
        case systemTrustTLS(serverName: String? = nil)
    }

    public let host: String
    public let port: Int
    public let security: Security

    public init(host: String, port: Int, security: Security = .plainTCP) {
        self.host = host
        self.port = port
        self.security = security
    }
}

public enum MQTTQualityOfService: UInt8, CaseIterable, Sendable {
    case atMostOnce = 0
    case atLeastOnce = 1
    case exactlyOnce = 2
}

public struct MQTTSubscriptionFilter: Equatable, Sendable {
    public let topicFilter: String
    public let qos: MQTTQualityOfService

    public init(topicFilter: String, qos: MQTTQualityOfService) {
        self.topicFilter = topicFilter
        self.qos = qos
    }
}

public struct MQTTReceivedMessage: Equatable, Sendable {
    public let topic: String
    public let payload: Data
    public let qos: MQTTQualityOfService
    public let retained: Bool
    public let duplicate: Bool

    public init(
        topic: String,
        payload: Data,
        qos: MQTTQualityOfService,
        retained: Bool,
        duplicate: Bool
    ) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retained = retained
        self.duplicate = duplicate
    }
}

public enum MQTTTransportFailure: Error, Equatable, Sendable {
    case invalidConfiguration
    case authenticationRejected
    case brokerUnavailable
    case tlsTrustFailed
    case subscriptionRejected
    case sessionAlreadyInUse
    case timedOut
    case connectionClosed
    case protocolFailure
}

extension MQTTTransportFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration: "Invalid MQTT connection configuration."
        case .authenticationRejected: "The MQTT broker rejected authentication."
        case .brokerUnavailable: "The MQTT broker is unavailable."
        case .tlsTrustFailed: "The broker certificate is not trusted."
        case .subscriptionRejected: "The MQTT broker rejected a subscription."
        case .sessionAlreadyInUse: "The MQTT session is already connected."
        case .timedOut: "The MQTT operation timed out."
        case .connectionClosed: "The MQTT connection closed."
        case .protocolFailure: "The MQTT protocol operation failed."
        }
    }
}

/// Process-local MQTT 3.1.1 session state.
///
/// This value is intentionally not serializable. Keeping it alive permits a
/// broker session to resume across reconnects in this process only.
public final class MQTTInProcessSession: Sendable {
    let base: MQTTSession

    public init(clientID: String) {
        self.base = MQTTSession(clientID: clientID)
    }
}

public enum MQTTSessionPolicy: Sendable {
    case clean(clientID: String)
    case inProcessPersistent(MQTTInProcessSession)
}

public struct MQTTMessageSequence: AsyncSequence, Sendable {
    public typealias Element = MQTTReceivedMessage

    let base: MQTTSubscription

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        var base: MQTTSubscription.AsyncIterator

        public mutating func next() async throws -> MQTTReceivedMessage? {
            guard let message = try await base.next() else {
                return nil
            }

            return MQTTReceivedMessage(
                topic: message.topicName,
                payload: Data(
                    message.payload.readableBytesView
                ),
                qos: MQTTQualityOfService(message.qos),
                retained: message.retain,
                duplicate: message.dup
            )
        }
    }
}

public struct MQTTConnectionScope: Sendable {
    let connection: MQTTConnection
    fileprivate let cancellationBridge: ConnectionCancellationBridge

    public let resumedSession: Bool

    fileprivate init(
        connection: MQTTConnection,
        resumedSession: Bool,
        cancellationBridge: ConnectionCancellationBridge
    ) {
        self.connection = connection
        self.resumedSession = resumedSession
        self.cancellationBridge = cancellationBridge
    }

    public func publish(
        topic: String,
        payload: Data,
        qos: MQTTQualityOfService,
        retain: Bool = false
    ) async throws {
        do {
            try await connection.publish(
                to: topic,
                payload: ByteBuffer(bytes: payload),
                qos: qos.mqttNIO,
                retain: retain
            )
        } catch {
            throw MQTTTransportClient.map(error, tlsEnabled: false)
        }
    }

    public func withSubscription<Value>(
        to filters: [MQTTSubscriptionFilter],
        operation: (MQTTMessageSequence) async throws -> Value
    ) async throws -> Value {
        let registration = cancellationBridge.beginSubscription()
        defer { registration.finish() }

        do {
            return try await connection.subscribe(
                to: filters.map {
                    MQTTSubscribeInfo(
                        topicFilter: $0.topicFilter,
                        qos: $0.qos.mqttNIO
                    )
                }
            ) { subscription in
                registration.didBecomeActive()
                return try await operation(
                    MQTTMessageSequence(base: subscription)
                )
            }
        } catch is CancellationError {
            connection.close()
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                connection.close()
                throw CancellationError()
            }
            throw MQTTTransportClient.map(error, tlsEnabled: false)
        }
    }

    public func close() {
        connection.close()
    }
}

public struct MQTTTransportClient: Sendable {
    enum TLSTrustPolicy: Equatable, Sendable {
        case systemDefault
        case testRootDER(path: String)
    }

    struct TestHooks: Sendable {
        var connectionAttemptStarted: @Sendable () async -> Void = {}
    }

    let trustPolicy: TLSTrustPolicy
    let connectTimeout: Duration
    let responseTimeout: Duration
    let testHooks: TestHooks

    public init(
        connectTimeout: Duration = .seconds(10),
        responseTimeout: Duration = .seconds(10)
    ) {
        self.init(
            trustPolicy: .systemDefault,
            connectTimeout: connectTimeout,
            responseTimeout: responseTimeout
        )
    }

    init(
        trustPolicy: TLSTrustPolicy,
        connectTimeout: Duration = .seconds(10),
        responseTimeout: Duration = .seconds(10),
        testHooks: TestHooks = .init()
    ) {
        self.trustPolicy = trustPolicy
        self.connectTimeout = connectTimeout
        self.responseTimeout = responseTimeout
        self.testHooks = testHooks
    }

    static var usesAppleTransportServices: Bool {
        true
    }

    var usesDefaultSystemTrustRoots: Bool {
        trustPolicy == .systemDefault
    }

    public func withConnection<Value>(
        to endpoint: MQTTBrokerEndpoint,
        sessionPolicy: MQTTSessionPolicy,
        operation: (MQTTConnectionScope) async throws -> Value
    ) async throws -> Value {
        let cancellationBridge = ConnectionCancellationBridge()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await testHooks.connectionAttemptStarted()
            try Task.checkCancellation()

            do {
                switch sessionPolicy {
                case .clean(let clientID):
                    return try await MQTTConnection.withConnection(
                        address: .hostname(endpoint.host, port: endpoint.port),
                        configuration: try configuration(for: endpoint),
                        identifier: clientID,
                        eventLoop: NIOTSEventLoopGroup.singleton.any()
                    ) { connection in
                        cancellationBridge.register(connection)
                        defer { cancellationBridge.clear(connection) }
                        return try await operation(
                            MQTTConnectionScope(
                                connection: connection,
                                resumedSession: false,
                                cancellationBridge: cancellationBridge
                            )
                        )
                    }

                case .inProcessPersistent(let session):
                    return try await MQTTConnection.withConnection(
                        address: .hostname(endpoint.host, port: endpoint.port),
                        configuration: try configuration(for: endpoint),
                        session: session.base,
                        eventLoop: NIOTSEventLoopGroup.singleton.any()
                    ) { connection, resumedSession in
                        cancellationBridge.register(connection)
                        defer { cancellationBridge.clear(connection) }
                        return try await operation(
                            MQTTConnectionScope(
                                connection: connection,
                                resumedSession: resumedSession,
                                cancellationBridge: cancellationBridge
                            )
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw Self.map(
                    error,
                    tlsEnabled: endpoint.security.isTLS
                )
            }
        } onCancel: {
            cancellationBridge.cancel()
        }
    }

    private func configuration(
        for endpoint: MQTTBrokerEndpoint
    ) throws -> MQTTConnectionConfiguration {
        let transport: MQTTConnectionConfiguration.Transport
        switch endpoint.security {
        case .plainTCP:
            transport = .tcp()

        case .systemTrustTLS(let serverName):
            let tlsConfiguration: TSTLSConfiguration
            switch trustPolicy {
            case .systemDefault:
                tlsConfiguration = TSTLSConfiguration(
                    trustRoots: nil,
                    certificateVerification: .fullVerification
                )
            case .testRootDER(let path):
                let certificateData = try Data(
                    contentsOf: URL(fileURLWithPath: path)
                )
                guard let certificate = SecCertificateCreateWithData(
                    nil,
                    certificateData as CFData
                ) else {
                    throw MQTTTransportFailure.invalidConfiguration
                }
                tlsConfiguration = TSTLSConfiguration(
                    trustRoots: [certificate],
                    certificateVerification: .fullVerification
                )
            }
            transport = .tcp(
                tls: .enable(
                    .ts(tlsConfiguration),
                    tlsServerName: serverName
                )
            )
        }

        return MQTTConnectionConfiguration(
            versionConfiguration: .v3_1_1(),
            connectTimeout: connectTimeout,
            timeout: responseTimeout,
            transport: transport
        )
    }

    static func map(
        _ error: any Error,
        tlsEnabled: Bool
    ) -> MQTTTransportFailure {
        if tlsEnabled, isTLSTrustFailure(error) {
            return .tlsTrustFailed
        }

        guard let mqttError = error as? MQTTError else {
            return .brokerUnavailable
        }

        switch mqttError {
        case .connectionError(.badUserNameOrPassword),
             .connectionError(.notAuthorized):
            return .authenticationRejected
        case .connectionError(.serverUnavailable):
            return .brokerUnavailable
        case .timeout:
            return .timedOut
        case .connectionClosed, .serverClosedConnection:
            return .connectionClosed
        case .alreadyConnectedWithSession:
            return .sessionAlreadyInUse
        case .invalidTopicFilter:
            return .subscriptionRejected
        case .wrongTLSConfig:
            return .invalidConfiguration
        default:
            return .protocolFailure
        }
    }

    private static func isTLSTrustFailure(_ error: any Error) -> Bool {
        // mqtt-nio alpha.2/NIOTS currently surfaces a failed TLS trust handshake
        // as a channel close/connect timeout rather than preserving NWError.
        // Restrict this compatibility mapping to TLS setup; ordinary TCP/DNS
        // failures remain broker-availability failures.
        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .connectTimeout:
                return true
            default:
                break
            }
        }

        if let networkError = error as? NWError,
           case .tls(let status) = networkError {
            return [
                errSSLBadCert,
                errSSLNoRootCert,
                errSSLUnknownRootCert,
                errSSLXCertChainInvalid,
                errSSLHostNameMismatch,
                errSecNotTrusted,
            ].contains(status)
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain,
           [
               errSSLBadCert,
               errSSLNoRootCert,
               errSSLUnknownRootCert,
               errSSLXCertChainInvalid,
               errSSLHostNameMismatch,
               errSecNotTrusted,
           ].contains(OSStatus(nsError.code)) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isTLSTrustFailure(underlying)
        }
        return false
    }
}

private final class ConnectionCancellationBridge: Sendable {
    fileprivate enum SubscriptionPhase {
        case starting
        case active
    }

    private struct State {
        var isCancelled = false
        var connection: MQTTConnection?
        var nextSubscriptionID = 0
        var subscriptions: [Int: SubscriptionPhase] = [:]
    }

    private let state = Mutex(State())

    func register(_ connection: MQTTConnection) {
        let mustClose = state.withLock { state in
            state.connection = connection
            return state.isCancelled
        }
        if mustClose {
            connection.close()
        }
    }

    func clear(_ connection: MQTTConnection) {
        state.withLock { state in
            if state.connection === connection {
                state.connection = nil
            }
        }
    }

    func cancel() {
        let connection = state.withLock { state in
            state.isCancelled = true
            let hasActiveSubscription = state.subscriptions.values.contains {
                $0 == .active
            }
            return hasActiveSubscription == false
                ? state.connection
                : nil
        }
        connection?.close()
    }

    func beginSubscription() -> SubscriptionCancellationRegistration {
        let id = state.withLock { state in
            let id = state.nextSubscriptionID
            state.nextSubscriptionID += 1
            state.subscriptions[id] = .starting
            return id
        }
        return SubscriptionCancellationRegistration(bridge: self, id: id)
    }

    fileprivate func subscriptionDidBecomeActive(id: Int) {
        state.withLock { state in
            if state.subscriptions[id] == .starting {
                state.subscriptions[id] = .active
            }
        }
    }

    fileprivate func endSubscription(id: Int) {
        state.withLock { state in
            state.subscriptions[id] = nil
        }
    }
}

private final class SubscriptionCancellationRegistration: Sendable {
    private let bridge: ConnectionCancellationBridge
    private let id: Int

    init(bridge: ConnectionCancellationBridge, id: Int) {
        self.bridge = bridge
        self.id = id
    }

    func didBecomeActive() {
        bridge.subscriptionDidBecomeActive(id: id)
    }

    func finish() {
        bridge.endSubscription(id: id)
    }
}

private extension MQTTBrokerEndpoint.Security {
    var isTLS: Bool {
        if case .systemTrustTLS = self {
            return true
        }
        return false
    }
}

private extension MQTTQualityOfService {
    init(_ value: MQTTQoS) {
        self = switch value {
        case .atMostOnce: .atMostOnce
        case .atLeastOnce: .atLeastOnce
        case .exactlyOnce: .exactlyOnce
        }
    }

    var mqttNIO: MQTTQoS {
        switch self {
        case .atMostOnce: .atMostOnce
        case .atLeastOnce: .atLeastOnce
        case .exactlyOnce: .exactlyOnce
        }
    }
}
