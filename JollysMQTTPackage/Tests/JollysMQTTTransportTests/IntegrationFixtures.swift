import Darwin
import Foundation
import Testing
@testable import JollysMQTTTransport

actor MosquittoFixture {
    let directory: URL
    let plainEndpoint: MQTTBrokerEndpoint
    let tlsEndpoint: MQTTBrokerEndpoint
    let rootCertificateDER: URL

    private let process: Process
    private let logURL: URL

    static func start() async throws -> MosquittoFixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "jollysmqtt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let plainPort = try reserveTCPPort()
        let tlsPort = try reserveTCPPort()
        let rootCertificateDER = directory.appending(component: "root.der")
        try generateCertificates(
            in: directory,
            rootCertificateDER: rootCertificateDER
        )

        let logURL = directory.appending(component: "mosquitto.log")
        let configURL = directory.appending(component: "mosquitto.conf")
        let configuration = """
        user \(NSUserName())
        per_listener_settings true
        sys_interval 1
        log_dest file \(logURL.path)
        log_type all

        listener \(plainPort) 127.0.0.1
        protocol mqtt
        allow_anonymous true

        listener \(tlsPort) 127.0.0.1
        protocol mqtt
        allow_anonymous true
        cafile \(directory.appending(component: "root.pem").path)
        certfile \(directory.appending(component: "server.pem").path)
        keyfile \(directory.appending(component: "server.key").path)
        require_certificate false
        """
        try configuration.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/sbin/mosquitto")
        process.arguments = ["-c", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let fixture = MosquittoFixture(
            directory: directory,
            plainEndpoint: MQTTBrokerEndpoint(
                host: "127.0.0.1",
                port: Int(plainPort)
            ),
            tlsEndpoint: MQTTBrokerEndpoint(
                host: "127.0.0.1",
                port: Int(tlsPort),
                security: .systemTrustTLS(serverName: "localhost")
            ),
            rootCertificateDER: rootCertificateDER,
            process: process,
            logURL: logURL
        )
        try await fixture.waitUntilReady()
        return fixture
    }

    private init(
        directory: URL,
        plainEndpoint: MQTTBrokerEndpoint,
        tlsEndpoint: MQTTBrokerEndpoint,
        rootCertificateDER: URL,
        process: Process,
        logURL: URL
    ) {
        self.directory = directory
        self.plainEndpoint = plainEndpoint
        self.tlsEndpoint = tlsEndpoint
        self.rootCertificateDER = rootCertificateDER
        self.process = process
        self.logURL = logURL
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
            Issue.record("Mosquitto fixture did not terminate promptly")
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForLog(containing text: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            guard let data = try? Data(contentsOf: self.logURL),
                  let log = String(data: data, encoding: .utf8)
            else {
                try await clock.sleep(for: .milliseconds(20))
                continue
            }
            if log.contains(text) {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        let log = (try? String(contentsOf: logURL, encoding: .utf8))
            ?? "<broker log unavailable>"
        throw FixtureError(
            "Timed out waiting for broker log containing \(text). Log: \(log)"
        )
    }

    private func waitUntilReady() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            guard process.isRunning else {
                throw FixtureError("Mosquitto exited before becoming ready")
            }
            if commandSucceeds(
                executable: "/opt/homebrew/bin/mosquitto_pub",
                arguments: [
                    "-h", plainEndpoint.host,
                    "-p", String(plainEndpoint.port),
                    "-t", "ticket2/fixture/ready",
                    "-n",
                    "-q", "1",
                ]
            ) {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw FixtureError("Timed out waiting for Mosquitto readiness")
    }
}

actor SilentTCPFixture {
    let port: Int

    private let directory: URL
    private let process: Process

    static func start() async throws -> SilentTCPFixture {
        let port = try reserveTCPPort()
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "jollysmqtt-silent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let script = try #require(
            Bundle.module.url(
                forResource: "silent_tcp_server",
                withExtension: "py",
                subdirectory: "Fixtures"
            )
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            script.path,
            String(port),
            directory.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let fixture = SilentTCPFixture(
            port: Int(port),
            directory: directory,
            process: process
        )
        try await fixture.waitForState("ready")
        return fixture
    }

    private init(port: Int, directory: URL, process: Process) {
        self.port = port
        self.directory = directory
        self.process = process
    }

    func waitForState(_ state: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let statePath = directory.appending(component: state).path
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: statePath) {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw FixtureError("Timed out waiting for silent TCP fixture state \(state)")
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
            Issue.record("Silent TCP fixture did not terminate promptly")
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func generateCertificates(
    in directory: URL,
    rootCertificateDER: URL
) throws {
    let rootKey = directory.appending(component: "root.key").path
    let rootPEM = directory.appending(component: "root.pem").path
    let serverKey = directory.appending(component: "server.key").path
    let serverCSR = directory.appending(component: "server.csr").path
    let serverPEM = directory.appending(component: "server.pem").path
    let extensionsURL = directory.appending(component: "server.ext")

    try """
    basicConstraints=CA:FALSE
    keyUsage=digitalSignature,keyEncipherment
    extendedKeyUsage=serverAuth
    subjectAltName=DNS:localhost,IP:127.0.0.1
    """.write(to: extensionsURL, atomically: true, encoding: .utf8)

    try runCommand(
        executable: "/opt/homebrew/bin/openssl",
        arguments: [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", rootKey,
            "-out", rootPEM,
            "-days", "2",
            "-subj", "/CN=JollysMQTT Test Root",
        ]
    )
    try runCommand(
        executable: "/opt/homebrew/bin/openssl",
        arguments: [
            "req", "-newkey", "rsa:2048", "-nodes",
            "-keyout", serverKey,
            "-out", serverCSR,
            "-subj", "/CN=localhost",
        ]
    )
    try runCommand(
        executable: "/opt/homebrew/bin/openssl",
        arguments: [
            "x509", "-req",
            "-in", serverCSR,
            "-CA", rootPEM,
            "-CAkey", rootKey,
            "-CAcreateserial",
            "-out", serverPEM,
            "-days", "2",
            "-sha256",
            "-extfile", extensionsURL.path,
        ]
    )
    try runCommand(
        executable: "/opt/homebrew/bin/openssl",
        arguments: [
            "x509",
            "-in", rootPEM,
            "-outform", "DER",
            "-out", rootCertificateDER.path,
        ]
    )
}

private func reserveTCPPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw FixtureError("Unable to create port-reservation socket")
    }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0)
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
        throw FixtureError("Unable to reserve a local TCP port")
    }

    var result = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &result) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else {
        throw FixtureError("Unable to read reserved local TCP port")
    }
    return UInt16(bigEndian: result.sin_port)
}

private func runCommand(
    executable: String,
    arguments: [String]
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureError(
            "\(URL(fileURLWithPath: executable).lastPathComponent) failed"
        )
    }
}

private func commandSucceeds(
    executable: String,
    arguments: [String]
) -> Bool {
    do {
        try runCommand(executable: executable, arguments: arguments)
        return true
    } catch {
        return false
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
