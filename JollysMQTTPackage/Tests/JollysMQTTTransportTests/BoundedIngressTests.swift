import Foundation
import JollysMQTTTransport
import Testing

@Suite("Bounded MQTT ingress")
struct BoundedIngressTests {
    @Test(
        "The first publication beyond capacity closes upstream and requires user retry",
        .timeLimit(.minutes(1))
    )
    func firstRejectedPublicationTriggersLocalOverload() async throws {
        let messages = MQTTMessageFixtureSource(
            count: 3,
            payloadBytes: 1
        )
        let processingGate = ProcessingGate()
        let closeRecorder = CloseRecorder()
        let adapter = MQTTBoundedIngressAdapter(
            policy: MQTTIngressPolicy(
                capacity: 2,
                drainTimeout: .seconds(1)
            )
        )

        let consumption = Task {
            try await adapter.consume(
                messages,
                closeUpstream: {
                    await closeRecorder.record()
                },
                process: { _ in
                    await processingGate.wait()
                }
            )
        }

        await closeRecorder.waitForFirstClose()
        await processingGate.release()
        let report = try await consumption.value

        #expect(await closeRecorder.count == 1)
        #expect(report.termination == .localOverload)
        #expect(report.acceptedMessageCount == 2)
        #expect(report.processedMessageCount == 2)
        #expect(report.rejectedMessageCount == 1)
        #expect(report.discardedMessageCount == 0)
        #expect(report.highWaterMark == 2)
        #expect(
            report.coverageGap
                == MQTTIngressCoverageGap(
                    minimumMissingMessageCount: 1,
                    isOpenEnded: true
                )
        )
        #expect(report.allowsAutomaticReconnect == false)
    }

    @Test(
        "The drain deadline cancels processing and records a conservative coverage gap",
        .timeLimit(.minutes(1))
    )
    func drainDeadlineCancelsProcessing() async throws {
        let processingGate = CancellableProcessingGate()
        let messages = OverloadAfterProcessingStartsSource(
            processingGate: processingGate
        )
        let closeRecorder = CloseRecorder()
        let adapter = MQTTBoundedIngressAdapter(
            policy: MQTTIngressPolicy(
                capacity: 2,
                drainTimeout: .zero
            )
        )

        let report = try await adapter.consume(
            messages,
            closeUpstream: {
                await closeRecorder.record()
            },
            process: { _ in
                try await processingGate.wait()
            }
        )

        #expect(await closeRecorder.count == 1)
        #expect(await processingGate.observedCancellation)
        #expect(report.termination == .localOverload)
        #expect(report.acceptedMessageCount == 2)
        #expect(report.processedMessageCount == 0)
        #expect(report.rejectedMessageCount == 1)
        #expect(report.discardedMessageCount == 2)
        #expect(
            report.coverageGap
                == MQTTIngressCoverageGap(
                    minimumMissingMessageCount: 3,
                    isOpenEnded: true
                )
        )
    }
}

private actor CloseRecorder {
    private(set) var count = 0
    private var firstCloseWaiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        count += 1
        guard count == 1 else {
            return
        }
        let waiting = firstCloseWaiters
        firstCloseWaiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    func waitForFirstClose() async {
        guard count == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            firstCloseWaiters.append(continuation)
        }
    }
}

private struct MQTTMessageFixtureSource: AsyncSequence, Sendable {
    typealias Element = MQTTReceivedMessage

    let messages: [MQTTReceivedMessage]

    init(count: Int, payloadBytes: Int) {
        let payload = Data(repeating: 0x41, count: payloadBytes)
        self.messages = (0..<count).map { index in
            MQTTReceivedMessage(
                topic: "fixture/\(index)",
                payload: payload,
                qos: .atMostOnce,
                retained: false,
                duplicate: false
            )
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(messages: messages)
    }

    struct Iterator: AsyncIteratorProtocol {
        let messages: [MQTTReceivedMessage]
        var index = 0

        mutating func next() async -> MQTTReceivedMessage? {
            guard index < messages.count else {
                return nil
            }
            defer { index += 1 }
            return messages[index]
        }
    }
}

private actor ProcessingGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor CancellableProcessingGate {
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private let releases: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private(set) var observedCancellation = false

    init() {
        (releases, releaseContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func wait() async throws {
        isStarted = true
        let waiting = startWaiters
        startWaiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }

        var iterator = releases.makeAsyncIterator()
        _ = await iterator.next()
        do {
            try Task.checkCancellation()
        } catch {
            observedCancellation = true
            throw error
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private struct OverloadAfterProcessingStartsSource: AsyncSequence, Sendable {
    typealias Element = MQTTReceivedMessage

    let processingGate: CancellableProcessingGate

    func makeAsyncIterator() -> Iterator {
        Iterator(processingGate: processingGate)
    }

    struct Iterator: AsyncIteratorProtocol {
        let processingGate: CancellableProcessingGate
        var index = 0

        mutating func next() async -> MQTTReceivedMessage? {
            guard index < 3 else {
                return nil
            }
            if index == 1 {
                await processingGate.waitUntilStarted()
            }
            defer { index += 1 }
            return MQTTReceivedMessage(
                topic: "deadline/\(index)",
                payload: Data([UInt8(index)]),
                qos: .atMostOnce,
                retained: false,
                duplicate: false
            )
        }
    }
}
