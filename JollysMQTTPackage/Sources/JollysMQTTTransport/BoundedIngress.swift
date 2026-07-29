import Foundation
import Synchronization

public struct MQTTIngressPolicy: Equatable, Sendable {
    public let capacity: Int
    public let drainTimeout: Duration

    public init(capacity: Int, drainTimeout: Duration) {
        precondition(capacity > 0, "MQTT ingress capacity must be positive")
        precondition(
            drainTimeout >= .zero,
            "MQTT ingress drain timeout must not be negative"
        )
        self.capacity = capacity
        self.drainTimeout = drainTimeout
    }
}

public enum MQTTIngressTermination: Equatable, Sendable {
    case sourceFinished
    case localOverload
}

public struct MQTTIngressCoverageGap: Equatable, Sendable {
    /// Messages known to have been rejected or discarded locally.
    public let minimumMissingMessageCount: Int

    /// Always true for overload: mqtt-nio or the broker may have held more
    /// publications when the connection closed than JollysMQTT could count.
    public let isOpenEnded: Bool
    public let detectedAtMicroseconds: Int64?

    public init(
        minimumMissingMessageCount: Int,
        isOpenEnded: Bool,
        detectedAtMicroseconds: Int64? = nil
    ) {
        self.minimumMissingMessageCount = minimumMissingMessageCount
        self.isOpenEnded = isOpenEnded
        self.detectedAtMicroseconds = detectedAtMicroseconds
    }
}

public struct MQTTIngressReport: Equatable, Sendable {
    public let termination: MQTTIngressTermination
    public let acceptedMessageCount: Int
    public let processedMessageCount: Int
    public let rejectedMessageCount: Int
    public let discardedMessageCount: Int
    public let highWaterMark: Int
    public let coverageGap: MQTTIngressCoverageGap?
    public let overloadDrainDuration: Duration?

    public var allowsAutomaticReconnect: Bool {
        termination != .localOverload
    }
}

/// A fixed-capacity handoff between an MQTT subscription and slower work.
///
/// Capacity counts all accepted-but-not-yet-processed messages, including the
/// message currently in `process`. The first offer beyond capacity closes the
/// upstream source and permanently terminates this adapter as overloaded.
public struct MQTTBoundedIngressAdapter: Sendable {
    public let policy: MQTTIngressPolicy

    public init(policy: MQTTIngressPolicy) {
        self.policy = policy
    }

    public func consume<Source>(
        _ source: Source,
        closeUpstream: @escaping @Sendable () async -> Void,
        onOverload: @escaping @Sendable () -> Void = {},
        process: @escaping @Sendable (MQTTReceivedMessage) async throws -> Void
    ) async throws -> MQTTIngressReport
    where
        Source: AsyncSequence & Sendable,
        Source.Element == MQTTReceivedMessage
    {
        let buffer = MQTTIngressBuffer(policy: policy)
        let upstreamCloser = MQTTUpstreamCloseOnce(closeUpstream)
        let clock = ContinuousClock()

        try await withThrowingTaskGroup(
            of: MQTTIngressWorkerOutcome.self
        ) { group in
            group.addTask {
                do {
                    for try await message in source {
                        guard buffer.offer(message) else {
                            onOverload()
                            await upstreamCloser.close()
                            return .producerOverloaded
                        }
                    }
                    buffer.finishSource()
                    return .producerFinished
                } catch {
                    if buffer.isOverloaded {
                        return .producerOverloaded
                    }
                    buffer.finishSource()
                    throw error
                }
            }

            group.addTask {
                var signals = buffer.signals.makeAsyncIterator()
                while true {
                    if let message = buffer.takeNext() {
                        do {
                            try await process(message)
                            buffer.didProcessMessage()
                        } catch {
                            if buffer.isOverloaded {
                                buffer.expireDrain()
                                return .consumerFinished
                            }
                            throw error
                        }
                        continue
                    }
                    guard buffer.shouldWaitForSignal else {
                        return .consumerFinished
                    }
                    guard await signals.next() != nil else {
                        return .consumerFinished
                    }
                }
            }

            var overloadSeen = false
            var consumerFinished = false
            var deadlineScheduled = false
            do {
                while let outcome = try await group.next() {
                    switch outcome {
                    case .producerOverloaded:
                        guard !overloadSeen else {
                            continue
                        }
                        overloadSeen = true
                        if consumerFinished {
                            group.cancelAll()
                        } else {
                            deadlineScheduled = true
                            let drainTimeout = policy.drainTimeout
                            group.addTask {
                                do {
                                    try await clock.sleep(for: drainTimeout)
                                    return .drainDeadlineReached
                                } catch is CancellationError {
                                    return .drainDeadlineCancelled
                                }
                            }
                        }

                    case .producerFinished:
                        break

                    case .consumerFinished:
                        consumerFinished = true
                        if overloadSeen {
                            group.cancelAll()
                        }

                    case .drainDeadlineReached:
                        buffer.expireDrain()
                        group.cancelAll()

                    case .drainDeadlineCancelled:
                        break
                    }
                }
            } catch {
                await upstreamCloser.close()
                buffer.stop()
                group.cancelAll()
                throw error
            }

            if overloadSeen, deadlineScheduled, !consumerFinished {
                buffer.expireDrain()
            }
        }

        return buffer.report
    }
}

extension MQTTConnectionScope {
    /// Consumes a scoped mqtt-nio subscription through fixed-capacity ingress.
    ///
    /// Local overload closes the connection immediately and is returned as a
    /// terminal report so a feed can surface it without scheduling reconnect.
    public func consumeBoundedSubscription(
        to filters: [MQTTSubscriptionFilter],
        policy: MQTTIngressPolicy,
        boundaryPolicy: MQTTInboundBoundaryPolicy = .init(),
        onSubscribed: @escaping @Sendable () async -> Void = {},
        onOverload: @escaping @Sendable () -> Void = {},
        process: @escaping @Sendable (MQTTReceivedMessage) async throws -> Void
    ) async throws -> MQTTIngressReport {
        let completedReport = MQTTIngressReportBox()
        do {
            return try await withSubscription(
                to: filters,
                boundaryPolicy: boundaryPolicy
            ) { messages in
                await onSubscribed()
                let report = try await MQTTBoundedIngressAdapter(
                    policy: policy
                ).consume(
                    messages,
                    closeUpstream: {
                        close()
                    },
                    onOverload: onOverload,
                    process: process
                )
                completedReport.store(report)
                return report
            }
        } catch {
            if let report = completedReport.value,
                report.termination == .localOverload
            {
                return report
            }
            throw error
        }
    }
}

private final class MQTTIngressReportBox: Sendable {
    private let storage = Mutex<MQTTIngressReport?>(nil)

    var value: MQTTIngressReport? {
        storage.withLock { $0 }
    }

    func store(_ value: MQTTIngressReport) {
        storage.withLock { $0 = value }
    }
}

private enum MQTTIngressWorkerOutcome: Sendable {
    case producerFinished
    case producerOverloaded
    case consumerFinished
    case drainDeadlineReached
    case drainDeadlineCancelled
}

private actor MQTTUpstreamCloseOnce {
    private var didClose = false
    private let operation: @Sendable () async -> Void

    init(_ operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    func close() async {
        guard !didClose else {
            return
        }
        didClose = true
        await operation()
    }
}

private final class MQTTIngressBuffer: Sendable {
    private enum Phase {
        case accepting
        case sourceFinished
        case localOverload(ContinuousClock.Instant)
        case stopped
    }

    private struct State {
        var storage: [MQTTReceivedMessage?]
        var headIndex = 0
        var queuedCount = 0
        var phase = Phase.accepting
        var acceptedMessageCount = 0
        var processedMessageCount = 0
        var rejectedMessageCount = 0
        var discardedMessageCount = 0
        var highWaterMark = 0
        var drainExpired = false
        var overloadTerminationInstant: ContinuousClock.Instant?
        var overloadDetectedAtMicroseconds: Int64?

        init(capacity: Int) {
            storage = Array(repeating: nil, count: capacity)
        }
    }

    let signals: AsyncStream<Void>

    private let policy: MQTTIngressPolicy
    private let clock = ContinuousClock()
    private let signalContinuation: AsyncStream<Void>.Continuation
    private let state: Mutex<State>

    init(policy: MQTTIngressPolicy) {
        self.policy = policy
        self.state = Mutex(State(capacity: policy.capacity))
        (signals, signalContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    var isOverloaded: Bool {
        state.withLock { state in
            if case .localOverload = state.phase {
                return true
            }
            return false
        }
    }

    var shouldWaitForSignal: Bool {
        state.withLock { state in
            if case .accepting = state.phase {
                return true
            }
            return state.queuedCount > 0
        }
    }

    func offer(_ message: MQTTReceivedMessage) -> Bool {
        let accepted = state.withLock { state in
            guard case .accepting = state.phase else {
                return false
            }

            let outstanding =
                state.acceptedMessageCount
                - state.processedMessageCount
                - state.discardedMessageCount
            guard outstanding < policy.capacity else {
                state.phase = .localOverload(clock.now)
                state.overloadDetectedAtMicroseconds = Int64(
                    Date().timeIntervalSince1970 * 1_000_000
                )
                state.rejectedMessageCount = 1
                return false
            }

            let insertionIndex =
                (state.headIndex + state.queuedCount)
                % state.storage.count
            state.storage[insertionIndex] = message
            state.queuedCount += 1
            state.acceptedMessageCount += 1
            state.highWaterMark = max(
                state.highWaterMark,
                outstanding + 1
            )
            return true
        }
        signalContinuation.yield()
        return accepted
    }

    func takeNext() -> MQTTReceivedMessage? {
        let result = state.withLock { state -> MQTTReceivedMessage? in
            if case .localOverload(let overloadInstant) = state.phase,
                clock.now >= overloadInstant.advanced(by: policy.drainTimeout)
            {
                expireDrain(&state)
                return nil
            }

            guard state.queuedCount > 0 else {
                return nil
            }
            let message = state.storage[state.headIndex]
            state.storage[state.headIndex] = nil
            state.headIndex = (state.headIndex + 1) % state.storage.count
            state.queuedCount -= 1
            return message
        }
        finishSignalsIfTerminalAndDrained()
        return result
    }

    func didProcessMessage() {
        state.withLock { state in
            if case .localOverload(let overloadInstant) = state.phase,
                clock.now >= overloadInstant.advanced(by: policy.drainTimeout)
            {
                expireDrain(&state)
                return
            }
            guard !state.drainExpired else {
                return
            }
            state.processedMessageCount += 1
            if case .localOverload = state.phase,
                state.acceptedMessageCount == state.processedMessageCount
            {
                state.overloadTerminationInstant = clock.now
            }
        }
        signalContinuation.yield()
        finishSignalsIfTerminalAndDrained()
    }

    func finishSource() {
        state.withLock { state in
            guard case .accepting = state.phase else {
                return
            }
            state.phase = .sourceFinished
        }
        signalContinuation.yield()
        finishSignalsIfTerminalAndDrained()
    }

    func stop() {
        state.withLock { state in
            state.phase = .stopped
            state.discardedMessageCount += state.queuedCount
            state.storage = Array(
                repeating: nil,
                count: state.storage.count
            )
            state.headIndex = 0
            state.queuedCount = 0
        }
        signalContinuation.finish()
    }

    func expireDrain() {
        state.withLock { state in
            expireDrain(&state)
        }
        signalContinuation.finish()
    }

    var report: MQTTIngressReport {
        state.withLock { state in
            let termination: MQTTIngressTermination
            let coverageGap: MQTTIngressCoverageGap?
            switch state.phase {
            case .localOverload(let overloadInstant):
                termination = .localOverload
                coverageGap = MQTTIngressCoverageGap(
                    minimumMissingMessageCount:
                        state.rejectedMessageCount
                        + state.discardedMessageCount,
                    isOpenEnded: true,
                    detectedAtMicroseconds:
                        state.overloadDetectedAtMicroseconds
                )
                let terminationInstant =
                    state.overloadTerminationInstant ?? clock.now
                return MQTTIngressReport(
                    termination: termination,
                    acceptedMessageCount: state.acceptedMessageCount,
                    processedMessageCount: state.processedMessageCount,
                    rejectedMessageCount: state.rejectedMessageCount,
                    discardedMessageCount: state.discardedMessageCount,
                    highWaterMark: state.highWaterMark,
                    coverageGap: coverageGap,
                    overloadDrainDuration:
                        overloadInstant.duration(to: terminationInstant)
                )
            case .accepting, .sourceFinished, .stopped:
                termination = .sourceFinished
                coverageGap = nil
            }

            return MQTTIngressReport(
                termination: termination,
                acceptedMessageCount: state.acceptedMessageCount,
                processedMessageCount: state.processedMessageCount,
                rejectedMessageCount: state.rejectedMessageCount,
                discardedMessageCount: state.discardedMessageCount,
                highWaterMark: state.highWaterMark,
                coverageGap: coverageGap,
                overloadDrainDuration: nil
            )
        }
    }

    private func finishSignalsIfTerminalAndDrained() {
        let shouldFinish = state.withLock { state in
            switch state.phase {
            case .sourceFinished, .localOverload, .stopped:
                return state.queuedCount == 0
            case .accepting:
                return false
            }
        }
        if shouldFinish {
            signalContinuation.finish()
        }
    }

    private func expireDrain(_ state: inout State) {
        guard !state.drainExpired else {
            return
        }
        state.drainExpired = true
        state.discardedMessageCount =
            state.acceptedMessageCount - state.processedMessageCount
        state.storage = Array(repeating: nil, count: state.storage.count)
        state.headIndex = 0
        state.queuedCount = 0
        state.overloadTerminationInstant = clock.now
    }
}
