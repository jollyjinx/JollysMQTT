import CryptoKit
import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import Network

struct BrokerFeedPublishCommand: Sendable {
  let topic: String
  let payload: Data
  let qos: JollysMQTTTransport.MQTTQualityOfService
  let retain: Bool
}

enum BrokerFeedPublishEnqueueResult: Equatable, Sendable {
  case accepted
  case queueFull
  case closed
}

private struct BrokerFeedLocalOverload: Error, Sendable {
  let connectionEpoch: ConnectionEpochID
  let gap: MQTTIngressCoverageGap
}

actor BrokerFeedPublishCommandQueue {
  private let stream: AsyncStream<BrokerFeedPublishCommand>
  private let continuation: AsyncStream<BrokerFeedPublishCommand>.Continuation

  init(capacity: Int = 32) {
    precondition(capacity > 0)
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedPublishCommand.self,
      bufferingPolicy: .bufferingOldest(capacity)
    )
  }

  func enqueue(
    _ command: BrokerFeedPublishCommand
  ) -> BrokerFeedPublishEnqueueResult {
    switch continuation.yield(command) {
    case .enqueued:
      .accepted
    case .dropped:
      .queueFull
    case .terminated:
      .closed
    @unknown default:
      .closed
    }
  }

  func commands() -> AsyncStream<BrokerFeedPublishCommand> {
    stream
  }

  func close() {
    continuation.finish()
  }
}

actor MQTTBrokerFeedAttempt: BrokerFeedAttempting {
  private let client: MQTTTransportClient
  private let credentialResolver: any ConnectionCredentialResolving
  private let installationID: UUID
  private let ingressPolicy: MQTTIngressPolicy
  private let boundaryPolicy: MQTTInboundBoundaryPolicy
  private let ingestion: BrokerFeedIngestion?
  private let publishCommands: BrokerFeedPublishCommandQueue
  private var ownedWorkIsShutdown = false

  private var activeConnection: MQTTConnectionScope?
  private var persistentSession: MQTTInProcessSession?
  private var persistentSessionClientID: String?

  init(
    client: MQTTTransportClient = MQTTTransportClient(),
    credentialResolver: any ConnectionCredentialResolving,
    installationID: UUID,
    ingressPolicy: MQTTIngressPolicy = MQTTIngressPolicy(
      capacity: 4_096,
      drainTimeout: .milliseconds(100)
    ),
    boundaryPolicy: MQTTInboundBoundaryPolicy = .init(),
    ingestion: BrokerFeedIngestion? = nil,
    publishCommands: BrokerFeedPublishCommandQueue =
      BrokerFeedPublishCommandQueue()
  ) {
    self.client = client
    self.credentialResolver = credentialResolver
    self.installationID = installationID
    self.ingressPolicy = ingressPolicy
    self.boundaryPolicy = boundaryPolicy
    self.ingestion = ingestion
    self.publishCommands = publishCommands
  }

  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws {
    guard !ownedWorkIsShutdown else {
      throw CancellationError()
    }
    let profile = configuration.profile
    guard profile.validationIssues.isEmpty else {
      throw BrokerFeedFailure.invalidConfiguration
    }

    if let username = profile.username {
      do {
        try await credentialResolver.withCredential(
          for: profile.id,
          expectedRevision: configuration.credentialRevision
        ) { credential in
          let authentication = try credential.withUTF8String { password in
            MQTTAuthentication(
              userName: username,
              password: password
            )
          }
          try await self.runTransport(
            profile: profile,
            authentication: authentication,
            events: events
          )
        }
      } catch let failure as BrokerFeedFailure {
        throw failure
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw BrokerFeedFailure.credentialUnavailable
      }
    } else {
      try await runTransport(
        profile: profile,
        authentication: nil,
        events: events
      )
    }
  }

  func closeActiveConnection() {
    activeConnection?.close()
  }

  func retryHistoryPersistence() async -> Bool {
    await ingestion?.retryHistoryPersistence(
      recoveredAtMicroseconds: Int64(
        Date().timeIntervalSince1970 * 1_000_000
      )
    ) ?? false
  }

  func shutdownOwnedWork() async {
    guard !ownedWorkIsShutdown else { return }
    ownedWorkIsShutdown = true
    await publishCommands.close()
    await ingestion?.shutdown()
  }

  func topicSnapshots() async -> AsyncStream<BrokerTopicTreeSnapshot> {
    if let ingestion {
      return await ingestion.snapshots()
    }
    let (stream, continuation) = AsyncStream.makeStream(
      of: BrokerTopicTreeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation.yield(.empty)
    continuation.finish()
    return stream
  }

  private func runTransport(
    profile: BrokerProfile,
    authentication: MQTTAuthentication?,
    events: BrokerFeedAttemptEvents
  ) async throws {
    await events.connecting()
    let security: MQTTBrokerEndpoint.Security
    switch profile.transport {
    case .tcp:
      security = .plainTCP
    case .tls:
      security = .systemTrustTLS(serverName: profile.host)
    }
    let endpoint = MQTTBrokerEndpoint(
      host: profile.host,
      port: profile.port,
      security: security
    )
    let sessionPolicy = sessionPolicy(for: profile)
    let filters: [JollysMQTTTransport.MQTTSubscriptionFilter] =
      profile.subscriptions.compactMap { subscription in
        guard subscription.isEnabled else { return nil }
        return JollysMQTTTransport.MQTTSubscriptionFilter(
          topicFilter: subscription.filter,
          qos: subscription.qos.transportQoS
        )
      }

    do {
      try await client.withConnection(
        to: endpoint,
        sessionPolicy: sessionPolicy,
        authentication: authentication,
        keepAliveInterval: .seconds(profile.keepAliveSeconds)
      ) { connection in
        await self.setActiveConnection(connection)
        do {
          try await self.runConnectionWorkers(
            connection: connection,
            filters: filters,
            events: events
          )
          await self.clearActiveConnection()
        } catch {
          await self.clearActiveConnection()
          throw error
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let overload as BrokerFeedLocalOverload {
      _ = await ingestion?.recordLocalOverloadCoverageGap(
        connectionEpoch: overload.connectionEpoch,
        detectedAtMicroseconds:
          overload.gap.detectedAtMicroseconds
          ?? Int64(
            Date().timeIntervalSince1970 * 1_000_000
          ),
        minimumMissingMessageCount:
          overload.gap.minimumMissingMessageCount
      )
      throw BrokerFeedFailure.localOverload
    } catch let failure as BrokerFeedFailure {
      throw failure
    } catch let failure as MQTTTransportFailure {
      throw failure.feedFailure
    } catch {
      throw BrokerFeedFailure.transportUnavailable
    }
  }

  private func runConnectionWorkers(
    connection: MQTTConnectionScope,
    filters: [MQTTSubscriptionFilter],
    events: BrokerFeedAttemptEvents
  ) async throws {
    await ingestion?.beginConnectionEpoch(connection.connectionEpoch)
    await events.subscribing()
    let commandStream = await publishCommands.commands()

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        let report = try await connection.consumeBoundedSubscription(
          to: filters,
          policy: self.ingressPolicy,
          boundaryPolicy: self.boundaryPolicy,
          onSubscribed: {
            await events.connected()
          },
          process: { message in
            await self.ingestion?.ingest(
              BrokerInboundMessage(
                connectionEpoch: message.connectionEpoch,
                ordinal: message.ordinal,
                topic: message.topic,
                payload: message.payload,
                qos: message.qos.coreQoS,
                retained: message.retained,
                duplicate: message.duplicate,
                receivedAtMicroseconds: message.receivedAtMicroseconds
              )
            )
          }
        )
        if report.termination == .localOverload {
          if let gap = report.coverageGap {
            throw BrokerFeedLocalOverload(
              connectionEpoch: connection.connectionEpoch,
              gap: gap
            )
          }
          throw BrokerFeedFailure.localOverload
        }
        throw BrokerFeedFailure.transportUnavailable
      }
      group.addTask {
        for await command in commandStream {
          try Task.checkCancellation()
          try await connection.publish(
            topic: command.topic,
            payload: command.payload,
            qos: command.qos,
            retain: command.retain
          )
        }
        try Task.checkCancellation()
      }

      do {
        _ = try await group.next()
        group.cancelAll()
        while (try await group.next()) != nil {}
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private func setActiveConnection(_ connection: MQTTConnectionScope) {
    activeConnection = connection
  }

  private func clearActiveConnection() {
    activeConnection = nil
  }

  func sessionPolicy(
    for profile: BrokerProfile
  ) -> MQTTSessionPolicy {
    let clientID = Self.clientID(
      for: profile,
      installationID: installationID
    )
    guard !profile.cleanSession else {
      return .clean(clientID: clientID)
    }

    if let persistentSession,
      persistentSessionClientID == clientID
    {
      return .inProcessPersistent(persistentSession)
    }
    let session = MQTTInProcessSession(clientID: clientID)
    persistentSession = session
    persistentSessionClientID = clientID
    return .inProcessPersistent(session)
  }

  static func clientID(
    for profile: BrokerProfile,
    installationID: UUID,
    randomID: @autoclosure () -> UUID = UUID()
  ) -> String {
    switch profile.clientIDPolicy {
    case .stableGenerated:
      var source = Data()
      withUnsafeBytes(of: installationID.uuid) { source.append(contentsOf: $0) }
      withUnsafeBytes(of: profile.id.uuid) { source.append(contentsOf: $0) }
      let suffix = SHA256.hash(data: source).prefix(10).map {
        String(format: "%02x", $0)
      }.joined()
      return "jm-\(suffix)"
    case .randomPerConnection:
      let suffix = randomID().uuidString
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
        .prefix(20)
      return "jm-\(suffix)"
    case .explicit(let value):
      return value
    }
  }

  static func historySourceID(for profile: BrokerProfile) -> String {
    let source = [
      canonicalHistoryHost(profile.host),
      String(profile.port),
      profile.transport.rawValue,
      profile.username ?? "",
      "mqtt-3.1.1",
    ].joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(source.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private static func canonicalHistoryHost(_ host: String) -> String {
    let numeric =
      host.first == "[" && host.last == "]"
      ? String(host.dropFirst().dropLast())
      : host
    if let address = IPv4Address(numeric) {
      return "ipv4:"
        + address.rawValue.map { String(format: "%02x", $0) }.joined()
    }
    if let address = IPv6Address(numeric) {
      return "ipv6:"
        + address.rawValue.map { String(format: "%02x", $0) }.joined()
    }
    return "dns:\(host.lowercased())"
  }
}

extension JollysMQTTCore.MQTTQualityOfService {
  fileprivate var transportQoS: JollysMQTTTransport.MQTTQualityOfService {
    switch self {
    case .atMostOnce:
      .atMostOnce
    case .atLeastOnce:
      .atLeastOnce
    case .exactlyOnce:
      .exactlyOnce
    }
  }
}

extension JollysMQTTTransport.MQTTQualityOfService {
  fileprivate var coreQoS: JollysMQTTCore.MQTTQualityOfService {
    switch self {
    case .atMostOnce:
      .atMostOnce
    case .atLeastOnce:
      .atLeastOnce
    case .exactlyOnce:
      .exactlyOnce
    }
  }
}

extension MQTTTransportFailure {
  var feedFailure: BrokerFeedFailure {
    switch self {
    case .invalidConfiguration:
      .invalidConfiguration
    case .authenticationRejected:
      .authenticationRejected
    case .dnsResolutionFailed:
      .dnsResolutionFailed
    case .networkUnavailable:
      .networkUnavailable
    case .transportFailure, .timedOut, .connectionClosed:
      .transportUnavailable
    case .brokerUnavailable:
      .brokerUnavailable
    case .tlsTrustFailed:
      .trustRejected
    case .subscriptionRejected:
      .subscriptionRejected
    case .sessionAlreadyInUse:
      .sessionAlreadyInUse
    case .protocolFailure:
      .protocolFailure
    case .payloadTooLarge:
      .payloadTooLarge
    }
  }
}
