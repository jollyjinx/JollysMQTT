import Darwin
import Foundation
import JollysMQTTTransport
import Synchronization

@main
enum JollysMQTTOverloadProbe {
    static func main() async throws {
        try await runProbe()
    }
}

@concurrent
private func runProbe() async throws {
    let arguments = try ProbeArguments(CommandLine.arguments)
    let broker = try await ProbeBroker.start()
    let peakMemory = PeakMemorySampler()
    let baselineBytes: UInt64
    do {
        baselineBytes = try currentResidentBytes()
    } catch {
        await broker.stop()
        throw error
    }
    await peakMemory.sample(baselineBytes)
    let sampler = Task {
        let clock = ContinuousClock()
        do {
            while !Task.isCancelled {
                await peakMemory.sample(
                    try currentResidentBytes()
                )
                try await clock.sleep(for: .milliseconds(1))
            }
        } catch is CancellationError {
            return
        }
    }
    do {
        let subscribed = ProbeGate()
        let overloadTimestamp = OverloadTimestamp()
        let connectionTask = Task {
            try await MQTTTransportClient().withConnection(
                to: broker.endpoint,
                sessionPolicy: .clean(
                    clientID: "jolly-ticket3-overload-probe"
                )
            ) { connection in
                try await connection.consumeBoundedSubscription(
                    to: [
                        MQTTSubscriptionFilter(
                            topicFilter: "ticket3/probe/#",
                            qos: .atMostOnce
                        )
                    ],
                    policy: MQTTIngressPolicy(
                        capacity: arguments.capacity,
                        drainTimeout: .milliseconds(
                            arguments.drainMilliseconds
                        )
                    ),
                    onSubscribed: {
                        await subscribed.open()
                    },
                    onOverload: {
                        overloadTimestamp.markFirstRejection()
                    },
                    process: { _ in
                        try await Task.sleep(
                            for: .milliseconds(
                                arguments.processingMilliseconds
                            )
                        )
                    }
                )
            }
        }

        await subscribed.wait()
        let publisherStarted = ContinuousClock.now
        let publisher = try startPublisher(
            endpoint: broker.endpoint,
            messageCount: arguments.messageCount,
            payloadBytes: arguments.payloadBytes
        )
        defer {
            if publisher.isRunning {
                terminateAndReap(publisher)
            }
        }
        let report: MQTTIngressReport
        do {
            report = try await connectionTask.value
        } catch {
            terminateAndReap(publisher)
            throw error
        }
        let connectionTeardownDuration =
            try overloadTimestamp.durationToNow()
        publisher.waitUntilExit()
        let publisherElapsed = publisherStarted.duration(to: .now)
        let sentMessages = try publisherSentMessages(publisher)

        try await Task.sleep(
            for: .milliseconds(arguments.settleMilliseconds)
        )
        let settledBytes = try currentResidentBytes()
        await peakMemory.sample(settledBytes)
        sampler.cancel()
        try await sampler.value

        guard report.termination == .localOverload,
            report.highWaterMark == arguments.capacity,
            report.allowsAutomaticReconnect == false
        else {
            throw ProbeError.invalidOverloadReport
        }

        let peakBytes = await peakMemory.peakBytes
        let peakDeltaBytes =
            peakBytes >= baselineBytes
            ? peakBytes - baselineBytes
            : 0
        let drainMilliseconds =
            report.overloadDrainDuration?.milliseconds ?? .infinity
        let connectionTeardownMilliseconds =
            connectionTeardownDuration.milliseconds
        let deltaMemoryBudgetPassed =
            peakDeltaBytes <= arguments.rssDeltaBudgetBytes
        let absoluteMemoryBudgetPassed =
            peakBytes <= arguments.rssAbsoluteBudgetBytes
        let memoryBudgetPassed =
            deltaMemoryBudgetPassed && absoluteMemoryBudgetPassed
        let teardownBudgetPassed =
            connectionTeardownMilliseconds
            <= Double(arguments.teardownBudgetMilliseconds)

        let result = ProbeResult(
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            hardwareModel: hardwareModel(),
            operatingSystem: ProcessInfo.processInfo
                .operatingSystemVersionString,
            architecture: architectureName(),
            buildConfiguration: buildConfiguration,
            mqttNIOVersion: "3.0.0-alpha.2",
            mqttNIORevision:
                "e670a69ee3122bd11ef04f668757ffc01c263468",
            attemptedMessages: arguments.messageCount,
            publisherSentMessages: sentMessages,
            publisherElapsedMilliseconds: publisherElapsed.milliseconds,
            publisherMessagesPerSecond:
                publisherElapsed.seconds > 0
                ? Double(sentMessages) / publisherElapsed.seconds
                : 0,
            payloadBytes: arguments.payloadBytes,
            queueCapacity: arguments.capacity,
            processingMilliseconds:
                arguments.processingMilliseconds,
            drainDeadlineMilliseconds:
                arguments.drainMilliseconds,
            acceptedMessages: report.acceptedMessageCount,
            processedMessages: report.processedMessageCount,
            rejectedMessages: report.rejectedMessageCount,
            discardedMessages: report.discardedMessageCount,
            queueHighWaterMark: report.highWaterMark,
            coverageGapOpenEnded:
                report.coverageGap?.isOpenEnded ?? false,
            overloadDrainMilliseconds: drainMilliseconds,
            connectionTeardownMilliseconds:
                connectionTeardownMilliseconds,
            baselineResidentBytes: baselineBytes,
            peakResidentBytes: peakBytes,
            peakResidentDeltaBytes: peakDeltaBytes,
            settledResidentBytes: settledBytes,
            settleMilliseconds: arguments.settleMilliseconds,
            rssDeltaBudgetBytes: arguments.rssDeltaBudgetBytes,
            rssAbsoluteBudgetBytes:
                arguments.rssAbsoluteBudgetBytes,
            teardownBudgetMilliseconds:
                arguments.teardownBudgetMilliseconds,
            deltaMemoryBudgetPassed: deltaMemoryBudgetPassed,
            absoluteMemoryBudgetPassed:
                absoluteMemoryBudgetPassed,
            memoryBudgetPassed: memoryBudgetPassed,
            teardownBudgetPassed: teardownBudgetPassed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(result))
        FileHandle.standardOutput.write(Data([0x0A]))

        await broker.stop()
        guard memoryBudgetPassed, teardownBudgetPassed else {
            throw ProbeError.budgetExceeded
        }
    } catch {
        sampler.cancel()
        try? await sampler.value
        await broker.stop()
        throw error
    }
}

private struct ProbeArguments: Sendable {
    let messageCount: Int
    let payloadBytes: Int
    let capacity: Int
    let processingMilliseconds: Int
    let drainMilliseconds: Int
    let rssDeltaBudgetBytes: UInt64
    let settleMilliseconds: Int
    let teardownBudgetMilliseconds: Int
    let rssAbsoluteBudgetBytes: UInt64

    init(_ arguments: [String]) throws {
        messageCount = try Self.value(
            at: 1,
            arguments: arguments,
            default: 250_000
        )
        payloadBytes = try Self.value(
            at: 2,
            arguments: arguments,
            default: 256
        )
        capacity = try Self.value(
            at: 3,
            arguments: arguments,
            default: 4_096
        )
        processingMilliseconds = try Self.value(
            at: 4,
            arguments: arguments,
            default: 5
        )
        drainMilliseconds = try Self.value(
            at: 5,
            arguments: arguments,
            default: 100
        )
        rssDeltaBudgetBytes = UInt64(
            try Self.value(
                at: 6,
                arguments: arguments,
                default: 64 * 1_024 * 1_024
            )
        )
        settleMilliseconds = try Self.value(
            at: 7,
            arguments: arguments,
            default: 500
        )
        teardownBudgetMilliseconds = try Self.value(
            at: 8,
            arguments: arguments,
            default: 500
        )
        rssAbsoluteBudgetBytes = UInt64(
            try Self.value(
                at: 9,
                arguments: arguments,
                default: 128 * 1_024 * 1_024
            )
        )
    }

    private static func value(
        at index: Int,
        arguments: [String],
        default defaultValue: Int
    ) throws -> Int {
        guard arguments.indices.contains(index) else {
            return defaultValue
        }
        guard let value = Int(arguments[index]), value > 0 else {
            throw ProbeError.invalidArguments
        }
        return value
    }
}

private struct ProbeResult: Codable, Sendable {
    let timestampUTC: String
    let hardwareModel: String
    let operatingSystem: String
    let architecture: String
    let buildConfiguration: String
    let mqttNIOVersion: String
    let mqttNIORevision: String
    let attemptedMessages: Int
    let publisherSentMessages: Int
    let publisherElapsedMilliseconds: Double
    let publisherMessagesPerSecond: Double
    let payloadBytes: Int
    let queueCapacity: Int
    let processingMilliseconds: Int
    let drainDeadlineMilliseconds: Int
    let acceptedMessages: Int
    let processedMessages: Int
    let rejectedMessages: Int
    let discardedMessages: Int
    let queueHighWaterMark: Int
    let coverageGapOpenEnded: Bool
    let overloadDrainMilliseconds: Double
    let connectionTeardownMilliseconds: Double
    let baselineResidentBytes: UInt64
    let peakResidentBytes: UInt64
    let peakResidentDeltaBytes: UInt64
    let settledResidentBytes: UInt64
    let settleMilliseconds: Int
    let rssDeltaBudgetBytes: UInt64
    let rssAbsoluteBudgetBytes: UInt64
    let teardownBudgetMilliseconds: Int
    let deltaMemoryBudgetPassed: Bool
    let absoluteMemoryBudgetPassed: Bool
    let memoryBudgetPassed: Bool
    let teardownBudgetPassed: Bool
}

private actor ProbeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor PeakMemorySampler {
    private(set) var peakBytes: UInt64 = 0

    func sample(_ residentBytes: UInt64) {
        peakBytes = max(peakBytes, residentBytes)
    }
}

private final class OverloadTimestamp: Sendable {
    private let firstRejection =
        Mutex<ContinuousClock.Instant?>(nil)

    func markFirstRejection() {
        firstRejection.withLock { firstRejection in
            if firstRejection == nil {
                firstRejection = .now
            }
        }
    }

    func durationToNow() throws -> Duration {
        guard let firstRejection = firstRejection.withLock({ $0 }) else {
            throw ProbeError.invalidOverloadReport
        }
        return firstRejection.duration(to: .now)
    }
}

private actor ProbeBroker {
    let endpoint: MQTTBrokerEndpoint

    private let directory: URL
    private let process: Process

    static func start() async throws -> ProbeBroker {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "jollysmqtt-overload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let port = try reserveTCPPort()
        let configuration = """
            user \(NSUserName())
            listener \(port) 127.0.0.1
            protocol mqtt
            allow_anonymous true
            """
        let configURL = directory.appending(component: "mosquitto.conf")
        try configuration.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/opt/homebrew/sbin/mosquitto"
        )
        process.arguments = ["-c", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let broker = ProbeBroker(
            endpoint: MQTTBrokerEndpoint(
                host: "127.0.0.1",
                port: Int(port)
            ),
            directory: directory,
            process: process
        )
        do {
            try await broker.waitUntilReady()
            return broker
        } catch {
            terminateAndReap(process)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(
        endpoint: MQTTBrokerEndpoint,
        directory: URL,
        process: Process
    ) {
        self.endpoint = endpoint
        self.directory = directory
        self.process = process
    }

    func stop() async {
        if process.isRunning {
            process.terminate()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while process.isRunning, clock.now < deadline {
                try? await clock.sleep(for: .milliseconds(20))
            }
        }
        if process.isRunning {
            process.interrupt()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while process.isRunning, clock.now < deadline {
                try? await clock.sleep(for: .milliseconds(20))
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntilReady() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            guard process.isRunning else {
                throw ProbeError.brokerExited
            }
            if brokerIsReady(endpoint) {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw ProbeError.brokerReadinessTimedOut
    }
}

private func startPublisher(
    endpoint: MQTTBrokerEndpoint,
    messageCount: Int,
    payloadBytes: Int
) throws -> Process {
    guard
        let script = Bundle.module.url(
            forResource: "flood_mqtt",
            withExtension: "py",
            subdirectory: "Resources"
        )
    else {
        throw ProbeError.missingPublisher
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3",
        script.path,
        endpoint.host,
        String(endpoint.port),
        "ticket3/probe/value",
        String(messageCount),
        String(payloadBytes),
    ]
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func publisherSentMessages(_ process: Process) throws -> Int {
    guard let output = process.standardOutput as? Pipe else {
        throw ProbeError.publisherFailed
    }
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    guard process.terminationStatus == 0,
        let string = String(data: data, encoding: .utf8),
        let count = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        throw ProbeError.publisherFailed
    }
    return count
}

private func terminateAndReap(_ process: Process) {
    if process.isRunning {
        process.terminate()
    }
    process.waitUntilExit()
}

private func brokerIsReady(_ endpoint: MQTTBrokerEndpoint) -> Bool {
    let process = Process()
    process.executableURL = URL(
        fileURLWithPath: "/opt/homebrew/bin/mosquitto_pub"
    )
    process.arguments = [
        "-h", endpoint.host,
        "-p", String(endpoint.port),
        "-t", "ticket3/probe/ready",
        "-n",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func reserveTCPPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw ProbeError.portReservationFailed
    }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bindResult == 0 else {
        throw ProbeError.portReservationFailed
    }

    var result = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &result) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else {
        throw ProbeError.portReservationFailed
    }
    return UInt16(bigEndian: result.sin_port)
}

private func currentResidentBytes() throws -> UInt64 {
    var information = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size
            / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else {
        throw ProbeError.memoryMeasurementFailed
    }
    return UInt64(information.resident_size)
}

private func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else {
        return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
        return "unknown"
    }
    let unterminated = bytes.prefix { $0 != 0 }.map {
        UInt8(bitPattern: $0)
    }
    return String(decoding: unterminated, as: UTF8.self)
}

private func architectureName() -> String {
    #if arch(arm64)
        "arm64"
    #elseif arch(x86_64)
        "x86_64"
    #else
        "unknown"
    #endif
}

private var buildConfiguration: String {
    #if DEBUG
        "debug"
    #else
        "release"
    #endif
}

extension Duration {
    fileprivate var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    fileprivate var seconds: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum ProbeError: Error {
    case invalidArguments
    case brokerExited
    case brokerReadinessTimedOut
    case portReservationFailed
    case missingPublisher
    case publisherFailed
    case memoryMeasurementFailed
    case invalidOverloadReport
    case budgetExceeded
}
