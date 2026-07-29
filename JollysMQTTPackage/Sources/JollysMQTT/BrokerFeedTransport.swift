import CryptoKit
import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import Network

struct BrokerFeedPublishCommand: Sendable {
  let request: BrokerPublishRequest
}

private struct BrokerFeedLocalOverload: Error, Sendable {
  let connectionEpoch: ConnectionEpochID
  let gap: MQTTIngressCoverageGap
}

actor BrokerFeedPublishCommandQueue {
  private let stream: AsyncStream<BrokerFeedPublishCommand>
  private let continuation: AsyncStream<BrokerFeedPublishCommand>.Continuation
  private var completions: [PublishOperationID: CheckedContinuation<BrokerPublishResult, Never>] =
    [:]
  private var isClosed = false

  init(capacity: Int = 32) {
    precondition(capacity > 0)
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedPublishCommand.self,
      bufferingPolicy: .bufferingOldest(capacity)
    )
  }

  func submit(_ request: BrokerPublishRequest) async -> BrokerPublishResult {
    guard !isClosed else {
      return .failure(.notConnected)
    }
    // Caller cancellation does not revoke an MQTT operation once queued. The
    // connection session owns it until completion or structured teardown.
    return await withCheckedContinuation { completion in
      guard completions[request.operationID] == nil else {
        completion.resume(returning: .failure(.transportUnavailable))
        return
      }
      completions[request.operationID] = completion
      switch continuation.yield(BrokerFeedPublishCommand(request: request)) {
      case .enqueued:
        break
      case .dropped:
        resolve(
          operationID: request.operationID,
          with: .failure(.queueFull)
        )
      case .terminated:
        resolve(
          operationID: request.operationID,
          with: .failure(.notConnected)
        )
      @unknown default:
        resolve(
          operationID: request.operationID,
          with: .failure(.notConnected)
        )
      }
    }
  }

  func commands() -> AsyncStream<BrokerFeedPublishCommand> {
    stream
  }

  func complete(_ success: BrokerPublishSuccess) {
    resolve(operationID: success.operationID, with: .success(success))
  }

  func fail(
    operationID: PublishOperationID,
    reason: BrokerPublishFailure
  ) {
    resolve(operationID: operationID, with: .failure(reason))
  }

  func close(reason: BrokerPublishFailure = .cancelled) {
    guard !isClosed else { return }
    isClosed = true
    continuation.finish()
    let pending = completions.values
    completions.removeAll(keepingCapacity: false)
    for completion in pending {
      completion.resume(returning: .failure(reason))
    }
  }

  func pendingOperationCount() -> Int {
    completions.count
  }

  private func resolve(
    operationID: PublishOperationID,
    with result: BrokerPublishResult
  ) {
    completions.removeValue(forKey: operationID)?.resume(returning: result)
  }
}

actor MQTTBrokerFeedAttempt: BrokerFeedAttempting {
  private let client: MQTTTransportClient
  private let credentialResolver: any ConnectionCredentialResolving
  private let installationID: UUID
  private let ingressPolicy: MQTTIngressPolicy
  private let boundaryPolicy: MQTTInboundBoundaryPolicy
  private let ingestion: BrokerFeedIngestion?
  private let publishQueueCapacity: Int
  private var ownedWorkIsShutdown = false

  private var activeConnection: MQTTConnectionScope?
  private var activePublishCommands: BrokerFeedPublishCommandQueue?
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
    publishQueueCapacity: Int = 32
  ) {
    precondition(publishQueueCapacity > 0)
    self.client = client
    self.credentialResolver = credentialResolver
    self.installationID = installationID
    self.ingressPolicy = ingressPolicy
    self.boundaryPolicy = boundaryPolicy
    self.ingestion = ingestion
    self.publishQueueCapacity = publishQueueCapacity
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
    await activePublishCommands?.close(reason: .cancelled)
    activePublishCommands = nil
    await ingestion?.shutdown()
  }

  func publish(
    _ request: BrokerPublishRequest
  ) async -> BrokerPublishResult {
    guard !ownedWorkIsShutdown, let activePublishCommands else {
      return .failure(.notConnected)
    }
    return await activePublishCommands.submit(request)
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
    let publishCommands = BrokerFeedPublishCommandQueue(
      capacity: publishQueueCapacity
    )
    let commandStream = await publishCommands.commands()

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          let report = try await connection.consumeBoundedSubscription(
            to: filters,
            policy: self.ingressPolicy,
            boundaryPolicy: self.boundaryPolicy,
            onSubscribed: {
              await self.activatePublishCommands(publishCommands)
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
            do {
              try await connection.publish(
                topic: command.request.topic,
                payload: command.request.payload,
                qos: command.request.qos.transportQoS,
                retain: command.request.retain
              )
              let success = BrokerPublishSuccess(
                operationID: command.request.operationID,
                completion: BrokerPublishCompletion(
                  successfulQoS: command.request.qos
                ),
                completedAtMicroseconds: Int64(
                  Date().timeIntervalSince1970 * 1_000_000
                )
              )
              await self.ingestion?.recordSuccessfulPublish(
                command.request,
                completedAtMicroseconds: success.completedAtMicroseconds
              )
              await publishCommands.complete(success)
            } catch is CancellationError {
              await publishCommands.fail(
                operationID: command.request.operationID,
                reason: .cancelled
              )
              throw CancellationError()
            } catch {
              await publishCommands.fail(
                operationID: command.request.operationID,
                reason: .transportUnavailable
              )
            }
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
      await deactivatePublishCommands(
        publishCommands,
        reason: .transportUnavailable
      )
    } catch is CancellationError {
      await deactivatePublishCommands(
        publishCommands,
        reason: .cancelled
      )
      throw CancellationError()
    } catch {
      await deactivatePublishCommands(
        publishCommands,
        reason: .transportUnavailable
      )
      throw error
    }
  }

  private func activatePublishCommands(
    _ commands: BrokerFeedPublishCommandQueue
  ) {
    guard !ownedWorkIsShutdown else { return }
    activePublishCommands = commands
  }

  private func deactivatePublishCommands(
    _ commands: BrokerFeedPublishCommandQueue,
    reason: BrokerPublishFailure
  ) async {
    if activePublishCommands === commands {
      activePublishCommands = nil
    }
    await commands.close(reason: reason)
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
