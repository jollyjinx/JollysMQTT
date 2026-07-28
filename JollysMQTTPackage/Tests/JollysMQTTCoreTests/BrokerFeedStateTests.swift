import Foundation
import JollysMQTTCore
import Testing

@Suite("Broker feed state")
struct BrokerFeedStateTests {
  @Test("Transient DNS failures may retry automatically")
  func transientDNSFailureRetries() {
    #expect(BrokerFeedFailure.dnsResolutionFailed.allowsAutomaticRetry)
  }

  @Test(
    "Exponential backoff applies jitter and the configured cap",
    arguments: [
      BackoffExpectation(attempt: 1, jitter: 0, delay: 8),
      BackoffExpectation(attempt: 1, jitter: 1, delay: 12),
      BackoffExpectation(attempt: 2, jitter: 0.5, delay: 20),
      BackoffExpectation(attempt: 3, jitter: 0.5, delay: 40),
      BackoffExpectation(attempt: 4, jitter: 1, delay: 40),
    ]
  )
  func backoffPolicy(expectation: BackoffExpectation) {
    let policy = BrokerReconnectBackoff(
      initialDelaySeconds: 10,
      maximumDelaySeconds: 40
    )

    #expect(
      policy.delaySeconds(
        attempt: expectation.attempt,
        unitJitter: expectation.jitter
      ) == expectation.delay
    )
  }

  @Test("A retry schedule uses the injected clock and jitter")
  func retryScheduleUsesInjectedDependencies() async {
    let attempt = ScriptedAttempt(outcomes: [.failure(.dnsResolutionFailed)])
    let sleeper = ManualBrokerFeedSleeper()
    let now = Date(timeIntervalSince1970: 1_000)
    let feed = BrokerFeed(
      attempt: attempt,
      clock: .init(now: { now }, sleep: sleeper.sleep),
      jitter: .init { 0 }
    )

    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await sleeper.waitForRequestCount(1)

    let retry = await feed.snapshot().retry
    #expect(retry?.attempt == 1)
    #expect(retry?.delaySeconds == 0.8)
    #expect(retry?.retryAt == now.addingTimeInterval(0.8))
    await feed.release()
  }

  @Test("Connection reducer retains typed state and emits Retry and Cancel")
  func connectionReducer() {
    let retry = BrokerFeedRetrySchedule(
      token: 7,
      attempt: 2,
      delaySeconds: 4,
      retryAt: Date(timeIntervalSince1970: 1_004)
    )
    let snapshot = BrokerFeedSnapshot(
      phase: .waitingToReconnect,
      lastFailure: .networkUnavailable,
      retry: retry
    )
    var state = ConnectionFeature.State()

    ConnectionFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )
    let retryEffect = ConnectionFeature.reduce(state: &state, intent: .retry)
    let cancelEffect = ConnectionFeature.reduce(state: &state, intent: .cancel)

    #expect(state.snapshot == snapshot)
    #expect(retryEffect == .retry)
    #expect(cancelEffect == .cancel)
  }

  @Test("Apply Later dismisses only one workspace and one pending revision")
  func applyLaterIsWorkspaceAndRevisionLocal() {
    let firstPending = BrokerFeedSnapshot(
      phase: .connected,
      generation: .stale(pendingRevision: 4, blocker: nil)
    )
    var firstWorkspace = ConnectionFeature.State(snapshot: firstPending)
    var otherWorkspace = ConnectionFeature.State(snapshot: firstPending)

    let effect = ConnectionFeature.reduce(
      state: &firstWorkspace,
      intent: .applyLater
    )

    #expect(effect == .none)
    #expect(firstWorkspace.generationWarning == nil)
    #expect(
      otherWorkspace.generationWarning
        == BrokerFeedGenerationWarning(
          pendingRevision: 4,
          blocker: nil
        )
    )

    let nextPending = BrokerFeedSnapshot(
      phase: .connected,
      generation: .stale(pendingRevision: 5, blocker: nil)
    )
    ConnectionFeature.reduce(
      state: &firstWorkspace,
      action: .snapshotReceived(nextPending)
    )
    ConnectionFeature.reduce(
      state: &otherWorkspace,
      action: .snapshotReceived(nextPending)
    )

    #expect(firstWorkspace.generationWarning?.pendingRevision == 5)
    #expect(otherWorkspace.generationWarning?.pendingRevision == 5)
  }

  @Test("A leased feed reaches connected and closes on release")
  func successfulLeaseLifecycle() async {
    let attempt = HoldingSuccessfulAttempt()
    let feed = BrokerFeed(attempt: attempt)

    await feed.connect(
      BrokerFeedConfiguration(
        profile: .feedTestProfile(),
        credentialRevision: 0
      )
    )
    await attempt.waitUntilConnected()

    #expect(await feed.snapshot().phase == .connected)

    await feed.release()

    #expect(await feed.snapshot() == .idle)
    #expect(await attempt.closeCount() >= 1)
  }

  @Test("A successful attempt emits the complete lifecycle sequence")
  func successfulLifecycleSequence() async {
    let attempt = GatedLifecycleAttempt()
    let feed = BrokerFeed(attempt: attempt)
    let snapshots = await feed.snapshots()
    var iterator = snapshots.makeAsyncIterator()

    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await attempt.waitUntilStarted()

    var phases = [await iterator.next()?.phase]
    phases.append(await iterator.next()?.phase)
    await attempt.advance()
    phases.append(await iterator.next()?.phase)
    await attempt.advance()
    phases.append(await iterator.next()?.phase)
    await attempt.advance()
    phases.append(await iterator.next()?.phase)

    #expect(
      phases
        == [
          .idle,
          .resolving,
          .connecting,
          .subscribing,
          .connected,
        ]
    )
    await feed.release()
  }

  @Test("Cancel remains suppressed across scene activity changes")
  func cancelSuppressesReactivation() async {
    let attempt = ScriptedAttempt(outcomes: [.failure(.dnsResolutionFailed)])
    let sleeper = ManualBrokerFeedSleeper()
    let feed = BrokerFeed(
      attempt: attempt,
      clock: .init(
        now: { Date(timeIntervalSince1970: 1_000) },
        sleep: sleeper.sleep
      ),
      jitter: .init { 0.5 }
    )
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await sleeper.waitForRequestCount(1)

    await feed.cancel()
    await feed.setSceneActive(false)
    await feed.setSceneActive(true)

    #expect(await feed.snapshot().phase == .idle)
    #expect(await attempt.attemptCount() == 1)
  }

  @Test("Terminal failures remain terminal across scene activity changes")
  func terminalFailureSuppressesReactivation() async {
    let attempt = ScriptedAttempt(
      outcomes: [.failure(.authenticationRejected)]
    )
    let feed = BrokerFeed(attempt: attempt)
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await attempt.waitForAttemptCount(1)
    await attempt.waitUntilOutcomeReturned(1)

    await feed.setSceneActive(false)
    await feed.setSceneActive(true)

    #expect(await feed.snapshot().phase == .failed)
    #expect(await attempt.attemptCount() == 1)
  }

  @Test("Explicit Retry starts a new attempt after a terminal failure")
  func explicitRetryAfterTerminalFailure() async {
    let attempt = ScriptedAttempt(
      outcomes: [
        .failure(.authenticationRejected),
        .holdAtSubscribing,
      ]
    )
    let feed = BrokerFeed(attempt: attempt)
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await attempt.waitUntilOutcomeReturned(1)

    await feed.retry()
    await attempt.waitForAttemptCount(2)
    await attempt.waitUntilSubscribing()

    #expect(await feed.snapshot().phase == .subscribing)
    #expect(await attempt.attemptCount() == 2)
    await feed.release()
  }

  @Test("The last failure remains visible until reconnect succeeds")
  func failureRemainsVisibleDuringReconnect() async {
    let attempt = ScriptedAttempt(
      outcomes: [
        .failure(.dnsResolutionFailed),
        .holdAtSubscribing,
      ]
    )
    let sleeper = ManualBrokerFeedSleeper()
    let feed = BrokerFeed(
      attempt: attempt,
      clock: .init(now: Date.init, sleep: sleeper.sleep),
      jitter: .init { 0.5 }
    )
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await sleeper.waitForRequestCount(1)
    await sleeper.resumeNext()
    await attempt.waitForAttemptCount(2)
    await attempt.waitUntilSubscribing()

    let snapshot = await feed.snapshot()
    #expect(snapshot.phase == .subscribing)
    #expect(snapshot.lastFailure == .dnsResolutionFailed)

    await feed.release()
  }

  @Test("A connected attempt resets the exponential retry count")
  func connectedAttemptResetsBackoff() async {
    let attempt = ScriptedAttempt(
      outcomes: [
        .failure(.dnsResolutionFailed),
        .connectThenFail(.networkUnavailable),
      ]
    )
    let sleeper = ManualBrokerFeedSleeper()
    let feed = BrokerFeed(
      attempt: attempt,
      clock: .init(
        now: { Date(timeIntervalSince1970: 2_000) },
        sleep: sleeper.sleep
      ),
      jitter: .init { 0.5 }
    )
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await sleeper.waitForRequestCount(1)
    await sleeper.resumeNext()
    await sleeper.waitForRequestCount(2)

    #expect(await feed.snapshot().retry?.attempt == 1)

    await feed.release()
  }

  @Test("Disabled reconnect makes a transient failure terminal")
  func disabledReconnectIsTerminal() async {
    let attempt = ScriptedAttempt(
      outcomes: [.failure(.brokerUnavailable)]
    )
    let feed = BrokerFeed(attempt: attempt)
    await feed.connect(
      .init(
        profile: .feedTestProfile(reconnectPolicy: .disabled),
        credentialRevision: 0
      )
    )
    await attempt.waitUntilOutcomeReturned(1)

    let snapshot = await feed.snapshot()
    #expect(snapshot.phase == .failed)
    #expect(snapshot.lastFailure == .brokerUnavailable)
    #expect(snapshot.retry == nil)
  }

  @Test(
    "Every transient failure schedules automatic retry",
    arguments: [
      BrokerFeedFailure.dnsResolutionFailed,
      .networkUnavailable,
      .transportUnavailable,
      .brokerUnavailable,
    ]
  )
  func everyTransientFailureRetries(
    failure: BrokerFeedFailure
  ) async {
    let attempt = ScriptedAttempt(outcomes: [.failure(failure)])
    let sleeper = ManualBrokerFeedSleeper()
    let feed = BrokerFeed(
      attempt: attempt,
      clock: .init(now: Date.init, sleep: sleeper.sleep),
      jitter: .init { 0.5 }
    )

    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await sleeper.waitForRequestCount(1)

    let snapshot = await feed.snapshot()
    #expect(snapshot.phase == .waitingToReconnect)
    #expect(snapshot.lastFailure == failure)
    #expect(snapshot.retry?.attempt == 1)
    await feed.release()
  }

  @Test(
    "Every permanent failure waits for explicit Retry",
    arguments: [
      PermanentFailureExpectation(
        failure: .authenticationRejected,
        phase: .failed
      ),
      PermanentFailureExpectation(failure: .trustRejected, phase: .failed),
      PermanentFailureExpectation(
        failure: .invalidConfiguration,
        phase: .failed
      ),
      PermanentFailureExpectation(
        failure: .subscriptionRejected,
        phase: .failed
      ),
      PermanentFailureExpectation(
        failure: .localOverload,
        phase: .overloaded
      ),
      PermanentFailureExpectation(
        failure: .credentialUnavailable,
        phase: .failed
      ),
      PermanentFailureExpectation(
        failure: .sessionAlreadyInUse,
        phase: .failed
      ),
      PermanentFailureExpectation(
        failure: .fixedClientIDConflict,
        phase: .failed
      ),
      PermanentFailureExpectation(
        failure: .protocolFailure,
        phase: .failed
      ),
    ]
  )
  func everyPermanentFailureIsTerminal(
    expectation: PermanentFailureExpectation
  ) async {
    let attempt = ScriptedAttempt(
      outcomes: [.failure(expectation.failure)]
    )
    let feed = BrokerFeed(attempt: attempt)
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await attempt.waitUntilOutcomeReturned(1)

    let snapshot = await feed.snapshot()
    #expect(snapshot.phase == expectation.phase)
    #expect(snapshot.lastFailure == expectation.failure)
    #expect(snapshot.retry == nil)
  }

  @Test("A stale backoff completion cannot restart a cancelled feed")
  func staleRetryCompletionIsIgnored() async {
    let attempt = ScriptedAttempt(outcomes: [.failure(.dnsResolutionFailed)])
    let sleeper = StubbornBrokerFeedSleeper()
    let feed = BrokerFeed(
      attempt: attempt,
      clock: .init(now: Date.init, sleep: sleeper.sleep),
      jitter: .init { 0.5 }
    )
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await sleeper.waitUntilSleeping()

    let cancelTask = Task { await feed.cancel() }
    await sleeper.resume()
    await cancelTask.value

    #expect(await feed.snapshot().phase == .idle)
    #expect(await attempt.attemptCount() == 1)
  }

  @Test("Dormancy preserves failure and reconnects only on activation")
  func dormancyPreservesFailure() async {
    let attempt = ScriptedAttempt(
      outcomes: [
        .failure(.networkUnavailable),
        .holdAtSubscribing,
      ]
    )
    let sleeper = ManualBrokerFeedSleeper()
    let feed = BrokerFeed(
      attempt: attempt,
      clock: .init(now: Date.init, sleep: sleeper.sleep),
      jitter: .init { 0.5 }
    )
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await sleeper.waitForRequestCount(1)

    await feed.setSceneActive(false)
    #expect(
      await feed.snapshot()
        == BrokerFeedSnapshot(
          phase: .suspended,
          lastFailure: .networkUnavailable
        )
    )
    #expect(await attempt.attemptCount() == 1)

    await feed.setSceneActive(true)
    await attempt.waitForAttemptCount(2)
    await attempt.waitUntilSubscribing()
    #expect(await feed.snapshot().phase == .subscribing)
    #expect(await feed.snapshot().lastFailure == .networkUnavailable)
    await feed.release()
  }

  @Test("Terminal cleanup runs once even when active close fails")
  func cleanupFailureCannotSkipOwnedWorkShutdown() async {
    let attempt = FailingCleanupAttempt()
    let feed = BrokerFeed(attempt: attempt)
    await feed.connect(
      .init(profile: .feedTestProfile(), credentialRevision: 0)
    )
    await attempt.waitUntilConnected()

    await feed.release()
    await feed.release()

    #expect(await feed.snapshot().phase == .idle)
    #expect(await attempt.closeCount() >= 1)
    #expect(await attempt.shutdownCount() == 1)
    #expect(await attempt.runWasCancelled())
  }

  @Test("A released feed cannot be revived")
  func releaseIsTerminal() async {
    let attempt = ScriptedAttempt(
      outcomes: [
        .holdAtSubscribing,
        .holdAtSubscribing,
      ]
    )
    let feed = BrokerFeed(attempt: attempt)
    let configuration = BrokerFeedConfiguration(
      profile: .feedTestProfile(),
      credentialRevision: 0
    )
    await feed.connect(configuration)
    await attempt.waitForAttemptCount(1)
    await attempt.waitUntilSubscribing()
    await feed.release()

    await feed.connect(configuration)
    await feed.retry()

    #expect(await feed.snapshot().phase == .idle)
    #expect(await attempt.attemptCount() == 1)
  }

  @Test("Final release terminates raw snapshot monitoring")
  func releaseTerminatesSnapshots() async {
    let feed = BrokerFeed(
      attempt: ScriptedAttempt(outcomes: [])
    )
    let snapshots = await feed.snapshots()
    var iterator = snapshots.makeAsyncIterator()

    #expect(await iterator.next() == .idle)
    await feed.release()
    #expect(await iterator.next() == .idle)
    #expect(await iterator.next() == nil)
  }
}

struct BackoffExpectation:
  Sendable,
  CustomTestStringConvertible
{
  let attempt: Int
  let jitter: Double
  let delay: Double

  var testDescription: String {
    "attempt \(attempt), jitter \(jitter) → \(delay)s"
  }
}

private actor GatedLifecycleAttempt: BrokerFeedAttempting {
  private let holdStream: AsyncStream<Void>
  private let holdContinuation: AsyncStream<Void>.Continuation
  private var started = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var gateWaiters: [CheckedContinuation<Void, Never>] = []
  private var pendingPermits = 0

  init() {
    (holdStream, holdContinuation) = AsyncStream.makeStream()
  }

  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws {
    started = true
    let waiters = startedWaiters
    startedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    await waitForAdvance()
    await events.connecting()
    await waitForAdvance()
    await events.subscribing()
    await waitForAdvance()
    await events.connected()

    for await _ in holdStream {}
    try Task.checkCancellation()
  }

  func closeActiveConnection() {
    holdContinuation.finish()
    for waiter in gateWaiters {
      waiter.resume()
    }
    gateWaiters.removeAll()
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedWaiters.append(continuation)
    }
  }

  func advance() {
    guard !gateWaiters.isEmpty else {
      pendingPermits += 1
      return
    }
    gateWaiters.removeFirst().resume()
  }

  private func waitForAdvance() async {
    guard pendingPermits == 0 else {
      pendingPermits -= 1
      return
    }
    await withCheckedContinuation { continuation in
      gateWaiters.append(continuation)
    }
  }
}

struct PermanentFailureExpectation:
  Sendable,
  CustomTestStringConvertible
{
  let failure: BrokerFeedFailure
  let phase: BrokerFeedPhase

  var testDescription: String {
    "\(failure) → \(phase)"
  }
}

private actor HoldingSuccessfulAttempt: BrokerFeedAttempting {
  private let holdStream: AsyncStream<Void>
  private let holdContinuation: AsyncStream<Void>.Continuation
  private var didConnect = false
  private var connectedWaiters: [CheckedContinuation<Void, Never>] = []
  private var closes = 0

  init() {
    (holdStream, holdContinuation) = AsyncStream.makeStream()
  }

  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws {
    await events.connecting()
    await events.subscribing()
    await events.connected()
    didConnect = true
    let waiters = connectedWaiters
    connectedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    for await _ in holdStream {}
    try Task.checkCancellation()
  }

  func closeActiveConnection() {
    closes += 1
    holdContinuation.finish()
  }

  func waitUntilConnected() async {
    guard !didConnect else { return }
    await withCheckedContinuation { continuation in
      connectedWaiters.append(continuation)
    }
  }

  func closeCount() -> Int {
    closes
  }
}

private actor ScriptedAttempt: BrokerFeedAttempting {
  enum Outcome: Sendable {
    case failure(BrokerFeedFailure)
    case connectThenFail(BrokerFeedFailure)
    case holdAtSubscribing
  }

  private var outcomes: [Outcome]
  private var attempts = 0
  private var returned = 0
  private var subscribingCount = 0
  private var attemptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var returnWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var subscribingWaiters: [CheckedContinuation<Void, Never>] = []
  private let holdStream: AsyncStream<Void>
  private let holdContinuation: AsyncStream<Void>.Continuation
  private var isHolding = false

  init(outcomes: [Outcome]) {
    self.outcomes = outcomes
    (holdStream, holdContinuation) = AsyncStream.makeStream()
  }

  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws {
    attempts += 1
    resumeAttemptWaiters()
    let outcome =
      outcomes.isEmpty ? Outcome.failure(.transportUnavailable) : outcomes.removeFirst()
    do {
      switch outcome {
      case .failure(let failure):
        await events.connecting()
        throw failure
      case .connectThenFail(let failure):
        await events.connecting()
        await events.subscribing()
        await events.connected()
        throw failure
      case .holdAtSubscribing:
        await events.connecting()
        await events.subscribing()
        subscribingCount += 1
        let waiters = subscribingWaiters
        subscribingWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
        isHolding = true
        for await _ in holdStream {}
        isHolding = false
        try Task.checkCancellation()
      }
    } catch {
      returned += 1
      resumeReturnWaiters()
      throw error
    }
    returned += 1
    resumeReturnWaiters()
  }

  func closeActiveConnection() {
    if isHolding {
      holdContinuation.finish()
    }
  }

  func attemptCount() -> Int {
    attempts
  }

  func waitForAttemptCount(_ count: Int) async {
    guard attempts < count else { return }
    await withCheckedContinuation { continuation in
      attemptWaiters.append((count, continuation))
    }
  }

  func waitUntilOutcomeReturned(_ count: Int) async {
    guard returned < count else { return }
    await withCheckedContinuation { continuation in
      returnWaiters.append((count, continuation))
    }
  }

  func waitUntilSubscribing() async {
    guard subscribingCount == 0 else { return }
    await withCheckedContinuation { continuation in
      subscribingWaiters.append(continuation)
    }
  }

  private func resumeAttemptWaiters() {
    let ready = attemptWaiters.filter { attempts >= $0.count }
    attemptWaiters.removeAll { attempts >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }

  private func resumeReturnWaiters() {
    let ready = returnWaiters.filter { returned >= $0.count }
    returnWaiters.removeAll { returned >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }
}

private actor ManualBrokerFeedSleeper {
  private struct Request {
    let continuation: AsyncStream<Void>.Continuation
  }

  private var requests: [Request] = []
  private var requestCount = 0
  private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func sleep(seconds: Double) async throws {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    requestCount += 1
    let ready = requestWaiters.filter { requestCount >= $0.count }
    requestWaiters.removeAll { requestCount >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }
    requests.append(Request(continuation: continuation))
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    try Task.checkCancellation()
  }

  func waitForRequestCount(_ count: Int) async {
    guard requestCount < count else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append((count, continuation))
    }
  }

  func resumeNext() {
    guard !requests.isEmpty else { return }
    let request = requests.removeFirst()
    request.continuation.yield()
    request.continuation.finish()
  }
}

private actor StubbornBrokerFeedSleeper {
  private var continuation: CheckedContinuation<Void, Never>?
  private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

  func sleep(seconds: Double) async throws {
    let waiters = sleepWaiters
    sleepWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilSleeping() async {
    guard continuation == nil else { return }
    await withCheckedContinuation { continuation in
      sleepWaiters.append(continuation)
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private actor FailingCleanupAttempt: BrokerFeedAttempting {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private var connected = false
  private var connectedWaiters: [CheckedContinuation<Void, Never>] = []
  private var closes = 0
  private var shutdowns = 0
  private var cancelled = false

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func runAttempt(
    configuration: BrokerFeedConfiguration,
    events: BrokerFeedAttemptEvents
  ) async throws {
    await events.connecting()
    await events.subscribing()
    await events.connected()
    connected = true
    let waiters = connectedWaiters
    connectedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    for await _ in stream {}
    cancelled = Task.isCancelled
    try Task.checkCancellation()
  }

  func closeActiveConnection() throws {
    closes += 1
    continuation.finish()
    throw CleanupTestError.closeFailed
  }

  func shutdownOwnedWork() throws {
    shutdowns += 1
    throw CleanupTestError.shutdownFailed
  }

  func waitUntilConnected() async {
    guard !connected else { return }
    await withCheckedContinuation { continuation in
      connectedWaiters.append(continuation)
    }
  }

  func closeCount() -> Int { closes }
  func shutdownCount() -> Int { shutdowns }
  func runWasCancelled() -> Bool { cancelled }
}

private enum CleanupTestError: Error {
  case closeFailed
  case shutdownFailed
}

extension BrokerProfile {
  fileprivate static func feedTestProfile(
    reconnectPolicy: ReconnectPolicy = .standard
  ) -> BrokerProfile {
    BrokerProfile(
      id: UUID(),
      name: "Test",
      host: "broker.example",
      port: 1_883,
      transport: .tcp,
      username: nil,
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: reconnectPolicy,
      subscriptions: [
        SubscriptionDefinition(filter: "#", qos: .atMostOnce)
      ]
    )
  }
}
