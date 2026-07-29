import Foundation

public enum BrokerFeedDiagnosticCategory:
  String,
  Equatable,
  Sendable
{
  case dns
  case tcp
  case tls
  case connack
  case suback
  case localOverload
  case storage
  case cancellation
  case configuration
  case credentials
  case protocolFailure
}

public enum BrokerFeedDiagnosticCode:
  String,
  Equatable,
  Sendable
{
  case nameResolutionFailed
  case networkUnavailable
  case connectionFailed
  case brokerUnavailable
  case authenticationRejected
  case trustRejected
  case invalidConfiguration
  case subscriptionRejected
  case localIngressOverload
  case credentialUnavailable
  case sessionAlreadyInUse
  case fixedClientIDConflict
  case protocolFailure
  case payloadTooLarge
  case historyPersistenceFailed
  case cancelled
}

public struct BrokerFeedDiagnostic:
  Equatable,
  Sendable,
  CustomStringConvertible
{
  public let category: BrokerFeedDiagnosticCategory
  public let code: BrokerFeedDiagnosticCode

  public init(
    category: BrokerFeedDiagnosticCategory,
    code: BrokerFeedDiagnosticCode
  ) {
    self.category = category
    self.code = code
  }

  public static let storageFailure = BrokerFeedDiagnostic(
    category: .storage,
    code: .historyPersistenceFailed
  )
  public static let cancellation = BrokerFeedDiagnostic(
    category: .cancellation,
    code: .cancelled
  )

  public var description: String {
    "\(category.rawValue):\(code.rawValue)"
  }
}

public enum BrokerFeedFailure: Error, Equatable, Sendable {
  case dnsResolutionFailed
  case networkUnavailable
  case transportUnavailable
  case brokerUnavailable
  case authenticationRejected
  case trustRejected
  case invalidConfiguration
  case subscriptionRejected
  case localOverload
  case credentialUnavailable
  case sessionAlreadyInUse
  case fixedClientIDConflict
  case protocolFailure
  case payloadTooLarge

  public var allowsAutomaticRetry: Bool {
    switch self {
    case .dnsResolutionFailed,
      .networkUnavailable,
      .transportUnavailable,
      .brokerUnavailable:
      true
    case .authenticationRejected,
      .trustRejected,
      .invalidConfiguration,
      .subscriptionRejected,
      .localOverload,
      .credentialUnavailable,
      .sessionAlreadyInUse,
      .fixedClientIDConflict,
      .protocolFailure,
      .payloadTooLarge:
      false
    }
  }

  public var diagnostic: BrokerFeedDiagnostic {
    switch self {
    case .dnsResolutionFailed:
      BrokerFeedDiagnostic(
        category: .dns,
        code: .nameResolutionFailed
      )
    case .networkUnavailable:
      BrokerFeedDiagnostic(
        category: .tcp,
        code: .networkUnavailable
      )
    case .transportUnavailable:
      BrokerFeedDiagnostic(
        category: .tcp,
        code: .connectionFailed
      )
    case .brokerUnavailable:
      BrokerFeedDiagnostic(
        category: .connack,
        code: .brokerUnavailable
      )
    case .authenticationRejected:
      BrokerFeedDiagnostic(
        category: .connack,
        code: .authenticationRejected
      )
    case .trustRejected:
      BrokerFeedDiagnostic(
        category: .tls,
        code: .trustRejected
      )
    case .invalidConfiguration:
      BrokerFeedDiagnostic(
        category: .configuration,
        code: .invalidConfiguration
      )
    case .subscriptionRejected:
      BrokerFeedDiagnostic(
        category: .suback,
        code: .subscriptionRejected
      )
    case .localOverload:
      BrokerFeedDiagnostic(
        category: .localOverload,
        code: .localIngressOverload
      )
    case .credentialUnavailable:
      BrokerFeedDiagnostic(
        category: .credentials,
        code: .credentialUnavailable
      )
    case .sessionAlreadyInUse:
      BrokerFeedDiagnostic(
        category: .protocolFailure,
        code: .sessionAlreadyInUse
      )
    case .fixedClientIDConflict:
      BrokerFeedDiagnostic(
        category: .configuration,
        code: .fixedClientIDConflict
      )
    case .protocolFailure:
      BrokerFeedDiagnostic(
        category: .protocolFailure,
        code: .protocolFailure
      )
    case .payloadTooLarge:
      BrokerFeedDiagnostic(
        category: .configuration,
        code: .payloadTooLarge
      )
    }
  }
}

public enum BrokerFeedPhase: Equatable, Sendable {
  case idle
  case resolving
  case connecting
  case subscribing
  case connected
  case waitingToReconnect
  case disconnecting
  case suspended
  case failed
  case overloaded
}

public struct BrokerFeedRetrySchedule: Equatable, Sendable {
  public let token: UInt64
  public let attempt: Int
  public let delaySeconds: Double
  public let retryAt: Date

  public init(
    token: UInt64,
    attempt: Int,
    delaySeconds: Double,
    retryAt: Date
  ) {
    self.token = token
    self.attempt = attempt
    self.delaySeconds = delaySeconds
    self.retryAt = retryAt
  }
}

public struct BrokerFeedSnapshot: Equatable, Sendable {
  public let phase: BrokerFeedPhase
  public let lastFailure: BrokerFeedFailure?
  public let retry: BrokerFeedRetrySchedule?
  public let generation: BrokerFeedGenerationState
  public let sharedResources: BrokerFeedSharedResourceIdentity?
  public let diagnostic: BrokerFeedDiagnostic?

  public init(
    phase: BrokerFeedPhase,
    lastFailure: BrokerFeedFailure? = nil,
    retry: BrokerFeedRetrySchedule? = nil,
    generation: BrokerFeedGenerationState = .current,
    sharedResources: BrokerFeedSharedResourceIdentity? = nil,
    diagnostic: BrokerFeedDiagnostic? = nil
  ) {
    self.phase = phase
    self.lastFailure = lastFailure
    self.retry = retry
    self.generation = generation
    self.sharedResources = sharedResources
    self.diagnostic = diagnostic ?? lastFailure?.diagnostic
  }

  public static let idle = BrokerFeedSnapshot(phase: .idle)
}

public struct BrokerFeedSharedResourceIdentity: Equatable, Sendable {
  public let connection: UUID
  public let client: UUID
  public let subscriptionSet: UUID
  public let topicIndex: UUID
  public let historyWriter: UUID

  public init(
    connection: UUID = UUID(),
    client: UUID = UUID(),
    subscriptionSet: UUID = UUID(),
    topicIndex: UUID = UUID(),
    historyWriter: UUID = UUID()
  ) {
    self.connection = connection
    self.client = client
    self.subscriptionSet = subscriptionSet
    self.topicIndex = topicIndex
    self.historyWriter = historyWriter
  }
}

public enum BrokerFeedGenerationBlocker: Equatable, Sendable {
  case fixedClientIDConflict
}

public enum BrokerFeedGenerationState: Equatable, Sendable {
  case current
  case stale(
    pendingRevision: UInt64,
    blocker: BrokerFeedGenerationBlocker?
  )
}

public struct BrokerFeedGenerationWarning: Equatable, Sendable {
  public let pendingRevision: UInt64
  public let blocker: BrokerFeedGenerationBlocker?

  public init(
    pendingRevision: UInt64,
    blocker: BrokerFeedGenerationBlocker?
  ) {
    self.pendingRevision = pendingRevision
    self.blocker = blocker
  }
}

public struct BrokerReconnectBackoff: Equatable, Sendable {
  public let initialDelaySeconds: Int
  public let maximumDelaySeconds: Int
  public let jitterFraction: Double

  public init(
    initialDelaySeconds: Int,
    maximumDelaySeconds: Int,
    jitterFraction: Double = 0.2
  ) {
    precondition(initialDelaySeconds > 0)
    precondition(maximumDelaySeconds >= initialDelaySeconds)
    precondition((0...1).contains(jitterFraction))
    self.initialDelaySeconds = initialDelaySeconds
    self.maximumDelaySeconds = maximumDelaySeconds
    self.jitterFraction = jitterFraction
  }

  public func delaySeconds(
    attempt: Int,
    unitJitter: Double
  ) -> Double {
    precondition(attempt > 0)
    let exponent = min(attempt - 1, 62)
    let multiplier = Double(UInt64(1) << UInt64(exponent))
    let base = min(
      Double(maximumDelaySeconds),
      Double(initialDelaySeconds) * multiplier
    )
    let normalized = min(max(unitJitter, 0), 1)
    let jitter = (normalized * 2 - 1) * jitterFraction
    return min(
      Double(maximumDelaySeconds),
      max(0, base * (1 + jitter))
    )
  }
}

public struct BrokerFeedConfiguration: Equatable, Sendable {
  public let profile: BrokerProfile
  public let credentialRevision: UInt64

  public init(
    profile: BrokerProfile,
    credentialRevision: UInt64
  ) {
    self.profile = profile
    self.credentialRevision = credentialRevision
  }
}

public struct BrokerFeedAttemptEvents: Sendable {
  private let connectingOperation: @Sendable () async -> Void
  private let subscribingOperation: @Sendable () async -> Void
  private let connectedOperation: @Sendable () async -> Void

  public init(
    connecting: @escaping @Sendable () async -> Void,
    subscribing: @escaping @Sendable () async -> Void,
    connected: @escaping @Sendable () async -> Void
  ) {
    self.connectingOperation = connecting
    self.subscribingOperation = subscribing
    self.connectedOperation = connected
  }

  public func connecting() async {
    await connectingOperation()
  }

  public func subscribing() async {
    await subscribingOperation()
  }

  public func connected() async {
    await connectedOperation()
  }
}

public protocol BrokerFeedAttempting: Sendable {
  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws

  func closeActiveConnection() async throws
  func retryHistoryPersistence() async -> Bool
  func shutdownOwnedWork() async throws
  func topicSnapshots() async -> AsyncStream<BrokerTopicTreeSnapshot>
  func publish(_ request: BrokerPublishRequest) async -> BrokerPublishResult
}

extension BrokerFeedAttempting {
  public func retryHistoryPersistence() async -> Bool { false }

  public func shutdownOwnedWork() async throws {}

  public func topicSnapshots() -> AsyncStream<BrokerTopicTreeSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: BrokerTopicTreeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation.yield(.empty)
    continuation.finish()
    return stream
  }

  public func publish(
    _ request: BrokerPublishRequest
  ) -> BrokerPublishResult {
    .failure(.notConnected)
  }
}

public struct BrokerFeedClock: Sendable {
  private let nowOperation: @Sendable () -> Date
  private let sleepOperation: @Sendable (Double) async throws -> Void

  public init(
    now: @escaping @Sendable () -> Date,
    sleep: @escaping @Sendable (Double) async throws -> Void
  ) {
    self.nowOperation = now
    self.sleepOperation = sleep
  }

  public func now() -> Date {
    nowOperation()
  }

  public func sleep(seconds: Double) async throws {
    try await sleepOperation(seconds)
  }

  public static let continuous = BrokerFeedClock(
    now: Date.init,
    sleep: { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  )
}

public struct BrokerFeedJitter: Sendable {
  private let operation: @Sendable () -> Double

  public init(_ operation: @escaping @Sendable () -> Double) {
    self.operation = operation
  }

  public func nextUnitValue() -> Double {
    operation()
  }

  public static let system = BrokerFeedJitter {
    Double.random(in: 0...1)
  }
}

public protocol BrokerFeedLeaseControlling: BrokerPublishing, Sendable {
  func snapshots() async -> AsyncStream<BrokerFeedSnapshot>
  func topicSnapshots() async -> AsyncStream<BrokerTopicTreeSnapshot>
  func connect(_ configuration: BrokerFeedConfiguration) async
  func retry() async
  func retryHistoryPersistence() async
  func cancel() async
  func setSceneActive(_ isActive: Bool) async
  func reconnectAllToApply() async
  func release() async
}

extension BrokerFeedLeaseControlling {
  public func retryHistoryPersistence() async {}

  public func reconnectAllToApply() async {}

  public func publish(
    _ request: BrokerPublishRequest
  ) -> BrokerPublishResult {
    .failure(.notConnected)
  }

  public func topicSnapshots() -> AsyncStream<BrokerTopicTreeSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: BrokerTopicTreeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation.yield(.empty)
    continuation.finish()
    return stream
  }
}

public actor BrokerFeed: BrokerFeedLeaseControlling {
  private let attempt: any BrokerFeedAttempting
  private let clock: BrokerFeedClock
  private let jitter: BrokerFeedJitter
  private let stream: AsyncStream<BrokerFeedSnapshot>
  private let continuation: AsyncStream<BrokerFeedSnapshot>.Continuation

  private var current = BrokerFeedSnapshot.idle
  private var configuration: BrokerFeedConfiguration?
  private var parentTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var sceneIsActive = true
  private var resumeAllowed = false
  private var connectedToken: UInt64?
  private var ownedWorkIsShutdown = false
  private var isReleased = false

  public init(
    attempt: any BrokerFeedAttempting,
    clock: BrokerFeedClock = .continuous,
    jitter: BrokerFeedJitter = .system
  ) {
    self.attempt = attempt
    self.clock = clock
    self.jitter = jitter
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedSnapshot.self,
      bufferingPolicy: .bufferingOldest(64)
    )
    continuation.yield(.idle)
  }

  public func snapshots() -> AsyncStream<BrokerFeedSnapshot> {
    stream
  }

  public func topicSnapshots() async -> AsyncStream<BrokerTopicTreeSnapshot> {
    await attempt.topicSnapshots()
  }

  public func snapshot() -> BrokerFeedSnapshot {
    current
  }

  public func connect(_ configuration: BrokerFeedConfiguration) async {
    guard !isReleased else { return }
    await stop(finalPhase: nil, clearConfiguration: false)
    self.configuration = configuration
    resumeAllowed = true
    guard sceneIsActive else {
      publish(BrokerFeedSnapshot(phase: .suspended))
      return
    }
    launch()
  }

  public func retry() async {
    guard !isReleased else { return }
    guard configuration != nil else { return }
    await stop(finalPhase: nil, clearConfiguration: false)
    resumeAllowed = true
    guard sceneIsActive else {
      publish(BrokerFeedSnapshot(phase: .suspended))
      return
    }
    launch()
  }

  public func retryHistoryPersistence() async {
    _ = await attempt.retryHistoryPersistence()
  }

  public func publish(
    _ request: BrokerPublishRequest
  ) async -> BrokerPublishResult {
    guard !isReleased, current.phase == .connected else {
      return .failure(.notConnected)
    }
    return await attempt.publish(request)
  }

  public func cancel() async {
    guard !isReleased else { return }
    resumeAllowed = false
    await stop(finalPhase: .idle, clearConfiguration: false)
  }

  public func setSceneActive(_ isActive: Bool) async {
    guard !isReleased else { return }
    guard sceneIsActive != isActive else { return }
    sceneIsActive = isActive
    if isActive {
      guard configuration != nil,
        resumeAllowed,
        current.phase == .suspended
      else { return }
      await stop(finalPhase: nil, clearConfiguration: false)
      launch()
    } else {
      guard parentTask != nil else { return }
      await stop(finalPhase: .suspended, clearConfiguration: false)
    }
  }

  public func release() async {
    guard !isReleased else { return }
    isReleased = true
    resumeAllowed = false
    await stop(finalPhase: .idle, clearConfiguration: true)
    guard !ownedWorkIsShutdown else { return }
    ownedWorkIsShutdown = true
    do {
      try await attempt.shutdownOwnedWork()
    } catch {
      // Terminal cleanup remains idempotent; connection teardown already ran.
    }
    continuation.finish()
  }

  private func launch() {
    guard let configuration, parentTask == nil else { return }
    generation &+= 1
    let token = generation
    parentTask = Task { [weak self] in
      await self?.run(configuration: configuration, token: token)
    }
  }

  private func run(
    configuration: BrokerFeedConfiguration,
    token: UInt64
  ) async {
    var retryAttempt = 0
    while isCurrent(token), sceneIsActive {
      connectedToken = nil
      publishIfCurrent(
        BrokerFeedSnapshot(
          phase: .resolving,
          lastFailure: current.lastFailure
        ),
        token: token
      )
      do {
        try Task.checkCancellation()
        let events = BrokerFeedAttemptEvents(
          connecting: { [weak self] in
            await self?.transition(.connecting, token: token)
          },
          subscribing: { [weak self] in
            await self?.transition(.subscribing, token: token)
          },
          connected: { [weak self] in
            await self?.transition(.connected, token: token)
          }
        )
        try await attempt.runAttempt(
          configuration: configuration,
          events: events
        )
        try Task.checkCancellation()
        throw BrokerFeedFailure.transportUnavailable
      } catch is CancellationError {
        return
      } catch let failure as BrokerFeedFailure {
        guard isCurrent(token) else { return }
        if connectedToken == token {
          retryAttempt = 0
          connectedToken = nil
        }
        guard failure.allowsAutomaticRetry,
          let backoff = reconnectBackoff(for: configuration.profile)
        else {
          let phase: BrokerFeedPhase =
            failure == .localOverload ? .overloaded : .failed
          publish(
            BrokerFeedSnapshot(
              phase: phase,
              lastFailure: failure
            )
          )
          resumeAllowed = false
          parentTask = nil
          return
        }

        retryAttempt += 1
        let delay = backoff.delaySeconds(
          attempt: retryAttempt,
          unitJitter: jitter.nextUnitValue()
        )
        let retry = BrokerFeedRetrySchedule(
          token: token,
          attempt: retryAttempt,
          delaySeconds: delay,
          retryAt: clock.now().addingTimeInterval(delay)
        )
        publish(
          BrokerFeedSnapshot(
            phase: .waitingToReconnect,
            lastFailure: failure,
            retry: retry
          )
        )
        do {
          try await clock.sleep(seconds: delay)
          try Task.checkCancellation()
        } catch {
          return
        }
      } catch {
        guard isCurrent(token) else { return }
        publish(
          BrokerFeedSnapshot(
            phase: .failed,
            lastFailure: .protocolFailure
          )
        )
        resumeAllowed = false
        parentTask = nil
        return
      }
    }
  }

  private func transition(
    _ phase: BrokerFeedPhase,
    token: UInt64
  ) {
    guard isCurrent(token) else { return }
    if phase == .connected {
      connectedToken = token
    }
    publish(
      BrokerFeedSnapshot(
        phase: phase,
        lastFailure: phase == .connected ? nil : current.lastFailure
      )
    )
  }

  private func publishIfCurrent(
    _ snapshot: BrokerFeedSnapshot,
    token: UInt64
  ) {
    guard isCurrent(token) else { return }
    publish(snapshot)
  }

  private func isCurrent(_ token: UInt64) -> Bool {
    token == generation && parentTask != nil
  }

  private func publish(_ snapshot: BrokerFeedSnapshot) {
    current = snapshot
    continuation.yield(snapshot)
  }

  private func stop(
    finalPhase: BrokerFeedPhase?,
    clearConfiguration: Bool
  ) async {
    let task = parentTask
    let preservedFailure = current.lastFailure
    parentTask = nil
    generation &+= 1

    if task != nil {
      publish(
        BrokerFeedSnapshot(
          phase: .disconnecting,
          diagnostic: .cancellation
        )
      )
    }
    task?.cancel()
    if task != nil {
      do {
        try await attempt.closeActiveConnection()
      } catch {
        // Task cancellation and every remaining cleanup step still run.
      }
    }
    await task?.value

    if clearConfiguration {
      configuration = nil
      connectedToken = nil
    }
    if let finalPhase {
      publish(
        BrokerFeedSnapshot(
          phase: finalPhase,
          lastFailure: finalPhase == .suspended ? preservedFailure : nil
        )
      )
    }
  }

  private func reconnectBackoff(
    for profile: BrokerProfile
  ) -> BrokerReconnectBackoff? {
    switch profile.reconnectPolicy {
    case .disabled:
      nil
    case .exponential(let initial, let maximum):
      BrokerReconnectBackoff(
        initialDelaySeconds: initial,
        maximumDelaySeconds: maximum
      )
    }
  }
}

public enum ConnectionFeature {
  public struct State: Equatable, Sendable {
    public var snapshot: BrokerFeedSnapshot
    public var deferredPendingRevision: UInt64?

    public init(
      snapshot: BrokerFeedSnapshot = .idle,
      deferredPendingRevision: UInt64? = nil
    ) {
      self.snapshot = snapshot
      self.deferredPendingRevision = deferredPendingRevision
    }

    public var generationWarning: BrokerFeedGenerationWarning? {
      guard
        case .stale(let pendingRevision, let blocker) =
          snapshot.generation,
        deferredPendingRevision != pendingRevision
      else { return nil }
      return BrokerFeedGenerationWarning(
        pendingRevision: pendingRevision,
        blocker: blocker
      )
    }
  }

  public enum Intent: Equatable, Sendable {
    case retry
    case retryHistoryPersistence
    case cancel
    case applyLater
    case reconnectAllToApply
  }

  public enum Action: Equatable, Sendable {
    case snapshotReceived(BrokerFeedSnapshot)
  }

  public enum Effect: Equatable, Sendable {
    case none
    case retry
    case retryHistoryPersistence
    case cancel
    case reconnectAllToApply
  }

  public static func reduce(
    state: inout State,
    intent: Intent
  ) -> Effect {
    switch intent {
    case .retry:
      return .retry
    case .retryHistoryPersistence:
      return .retryHistoryPersistence
    case .cancel:
      return .cancel
    case .applyLater:
      if case .stale(let pendingRevision, _) = state.snapshot.generation {
        state.deferredPendingRevision = pendingRevision
      }
      return .none
    case .reconnectAllToApply:
      return .reconnectAllToApply
    }
  }

  public static func reduce(
    state: inout State,
    action: Action
  ) {
    switch action {
    case .snapshotReceived(let snapshot):
      state.snapshot = snapshot
      if snapshot.generation == .current {
        state.deferredPendingRevision = nil
      }
    }
  }
}
