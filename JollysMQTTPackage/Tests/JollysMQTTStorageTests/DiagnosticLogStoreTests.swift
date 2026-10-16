import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTTStorage

@Suite("Bounded support diagnostics")
struct DiagnosticLogStoreTests {
  @Test("Connections have separate anonymous files and writes are complete before export")
  func separateConnectionFiles() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiagnosticLogStore(directory: directory)
    let first = UUID()
    let second = UUID()
    #expect(await store.record(.connecting, connectionID: first))
    #expect(
      await store.record(
        .connectionFailed(.init(category: .tls, code: .trustRejected)), connectionID: second))
    #expect(await store.record(.connected, connectionID: first))
    let files = try await store.retainedFiles()
    #expect(files.count == 3)
    let firstFile = try #require(
      files.first { $0.lastPathComponent.contains(first.uuidString.lowercased()) })
    let firstText = try String(contentsOf: firstFile, encoding: .utf8)
    #expect(firstText.contains("connection.connecting"))
    #expect(firstText.contains("connection.connected"))
    #expect(!firstText.contains("trustRejected"))
    let secondFile = try #require(
      files.first { $0.lastPathComponent.contains(second.uuidString.lowercased()) })
    #expect(try String(contentsOf: secondFile, encoding: .utf8).contains("tls:trustRejected"))
    #expect(
      try firstFile.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    )
    let mode =
      try FileManager.default.attributesOfItem(atPath: firstFile.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test("Retention counts all connections and application files, including previous launches")
  func totalBudgetSurvivesRelaunch() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiagnosticLogStore(directory: directory, maximumBytes: 800, segmentBytes: 160)
    let firstConnection = UUID()
    await store.record(.connecting, connectionID: firstConnection)
    let initialFiles = try await store.retainedFiles()
    for _ in 0..<40 {
      #expect(await store.record(.connected, connectionID: UUID()))
      let files = try await store.retainedFiles()
      #expect(try size(of: files) <= 800)
    }
    #expect(initialFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    // A previously evicted live stream can write again without retaining stale handles.
    #expect(await store.record(.connectionClosed, connectionID: firstConnection))
    let relaunched = DiagnosticLogStore(directory: directory, maximumBytes: 400, segmentBytes: 160)
    #expect(try size(of: await relaunched.retainedFiles()) <= 400)
  }

  @Test(
    "Long connections rotate within the global budget and age pruning preserves unrelated files")
  func rotationAndAgeRetention() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let instant = Date(timeIntervalSince1970: 1_000_000)
    let store = DiagnosticLogStore(
      directory: directory, maximumBytes: 2000, segmentBytes: 128, now: { instant })
    let connection = UUID()
    for _ in 0..<10 { await store.record(.connected, connectionID: connection) }
    let files = try await store.retainedFiles()
    #expect(files.filter { $0.lastPathComponent.hasPrefix("connection-") }.count > 1)
    #expect(try files.allSatisfy { try Data(contentsOf: $0).count <= 128 })
    for file in files {
      try FileManager.default.setAttributes([.modificationDate: instant], ofItemAtPath: file.path)
    }
    let unrelated = directory.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: unrelated)
    let later = DiagnosticLogStore(
      directory: directory,
      now: {
        instant.addingTimeInterval(DiagnosticLogStore.maximumRetainedAge + 1)
      })
    #expect(try await later.retainedFiles().count == 1)
    #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test("Export creates a usable ZIP outside retention and cleans failed snapshots")
  func archiveSnapshot() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiagnosticLogStore(directory: directory.appending(path: "logs"))
    await store.record(.cloudKitFailure(operation: .send, code: 2, partialCodes: [14, 14]))
    let archive = try await store.createArchive(in: directory.appending(path: "exports"))
    let bytes = try Data(contentsOf: archive)
    #expect(bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]))
    #expect(!archive.path.hasPrefix(store.directory.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: archive.deletingLastPathComponent().appending(path: "JollysMQTT Logs").path))
    // Validate the central directory using the system ZIP reader, including CRCs.
    try await validateZIP(archive)
  }

  @Test("Unwritable logging does not break connections and archive failure is visible")
  func writeFailure() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocker = directory.appending(path: "file")
    try Data().write(to: blocker)
    let store = DiagnosticLogStore(directory: blocker.appending(path: "logs"))
    #expect(await store.record(.connected) == false)
    await #expect(throws: (any Error).self) {
      try await store.createArchive(in: directory.appending(path: "exports"))
    }
    // Retry must recover after storage becomes writable, even when no broker
    // produces another log event between export attempts.
    try FileManager.default.removeItem(at: blocker)
    let recovered = try await store.createArchive(in: directory.appending(path: "exports"))
    #expect(FileManager.default.fileExists(atPath: recovered.path))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "mqtt-log-tests-\(UUID().uuidString)")
  }

  private func size(of files: [URL]) throws -> Int {
    try files.reduce(0) { $0 + (try Data(contentsOf: $1).count) }
  }

  @concurrent private func validateZIP(_ archive: URL) async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/unzip")
    process.arguments = ["-tqq", archive.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let status = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Int32, any Error>) in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    #expect(status == 0)
  }
}
