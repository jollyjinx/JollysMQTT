import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@Suite("Local history retention settings")
struct LocalHistoryRetentionSettingsRepositoryTests {
  @Test("A per-broker policy persists locally and profile cleanup removes its record")
  func roundTripAndRemove() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTSettingsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "history-settings.json")
    let brokerID = UUID()
    let policy = try HistoryRetentionPolicy(
      topicMessageLimit: 42,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 512 * 1_024,
      messagePruneBatchLimit: 250,
      vacuumPageLimit: 512
    )
    let repository = try LocalHistoryRetentionSettingsRepository(
      fileURL: fileURL
    )

    try await repository.save(policy, for: brokerID)
    #expect(repository.policy(for: brokerID) == policy)
    let relaunched = try LocalHistoryRetentionSettingsRepository(
      fileURL: fileURL
    )
    #expect(relaunched.policy(for: brokerID) == policy)

    try await relaunched.removePolicy(for: brokerID)
    #expect(relaunched.policy(for: brokerID) == .default)
    let cleaned = try LocalHistoryRetentionSettingsRepository(
      fileURL: fileURL
    )
    #expect(cleaned.policy(for: brokerID) == .default)
    #expect(try String(contentsOf: fileURL, encoding: .utf8).contains(brokerID.uuidString) == false)
  }

  @Test("Concurrent saves keep the synchronous cache linearized with the document")
  func concurrentSaveOrdering() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTSettingsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "history-settings.json")
    let brokerID = UUID()
    let first = try HistoryRetentionPolicy(
      topicMessageLimit: 10,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 512 * 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    let second = try HistoryRetentionPolicy(
      topicMessageLimit: 20,
      brokerByteLimit: 80 * 1_024 * 1_024,
      payloadByteLimit: 768 * 1_024,
      messagePruneBatchLimit: 20,
      vacuumPageLimit: 20
    )
    let gate = GatedHistorySettingsFilePolicy()
    let repository = try LocalHistoryRetentionSettingsRepository(
      fileURL: fileURL,
      filePolicy: gate
    )

    let firstSave = Task {
      try await repository.save(first, for: brokerID)
    }
    await gate.waitForFirstApplication()
    let secondSave = Task {
      try await repository.save(second, for: brokerID)
    }
    await gate.releaseFirstApplication()
    try await firstSave.value
    try await secondSave.value

    #expect(repository.policy(for: brokerID) == second)
    let relaunched = try LocalHistoryRetentionSettingsRepository(
      fileURL: fileURL
    )
    #expect(relaunched.policy(for: brokerID) == second)
  }

  @Test("A protection failure reports committed policy without making the cache stale")
  func filePolicyFailureAfterCommit() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTSettingsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "history-settings.json")
    let brokerID = UUID()
    let policy = try HistoryRetentionPolicy(
      topicMessageLimit: 42,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 512 * 1_024,
      messagePruneBatchLimit: 250,
      vacuumPageLimit: 512
    )
    let repository = try LocalHistoryRetentionSettingsRepository(
      fileURL: fileURL,
      filePolicy: FailingHistorySettingsFilePolicy()
    )

    await #expect(throws: LocalHistoryRetentionSettingsError.filePolicyAfterCommit) {
      try await repository.save(policy, for: brokerID)
    }

    #expect(repository.policy(for: brokerID) == policy)
    let relaunched = try LocalHistoryRetentionSettingsRepository(
      fileURL: fileURL
    )
    #expect(relaunched.policy(for: brokerID) == policy)
  }

  @Test("Unavailable settings use defaults but never claim writes persisted")
  func unavailableRepositorySurfacesWrites() async {
    let repository = UnavailableHistoryRetentionSettingsRepository()
    let brokerID = UUID()

    #expect(repository.policy(for: brokerID) == .default)
    await #expect(throws: LocalHistoryRetentionSettingsError.unavailable) {
      try await repository.save(.default, for: brokerID)
    }
    await #expect(throws: LocalHistoryRetentionSettingsError.unavailable) {
      try await repository.removePolicy(for: brokerID)
    }
  }

  @Test("Corrupt and future-version documents fail closed")
  func corruptAndFutureDocuments() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTSettingsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let corruptURL = directory.appending(path: "corrupt.json")
    try Data("{".utf8).write(to: corruptURL)
    #expect(
      throws: LocalHistoryRetentionSettingsError.corruptDocument
    ) {
      try LocalHistoryRetentionSettingsRepository(fileURL: corruptURL)
    }

    let futureURL = directory.appending(path: "future.json")
    try Data(
      """
      {"version":2,"policies":{}}
      """.utf8
    ).write(to: futureURL)
    #expect(
      throws: LocalHistoryRetentionSettingsError.unsupportedVersion(2)
    ) {
      try LocalHistoryRetentionSettingsRepository(fileURL: futureURL)
    }
  }

  @Test("Duplicate UUID keys with different casing are rejected")
  func duplicateCanonicalBrokerKeys() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "JollysMQTTSettingsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "duplicates.json")
    let brokerID = UUID()
    let encodedPolicy = try JSONEncoder().encode(
      HistoryRetentionPolicy.default
    )
    let policyJSON = try #require(
      String(data: encodedPolicy, encoding: .utf8)
    )
    try Data(
      """
      {
        "version": 1,
        "policies": {
          "\(brokerID.uuidString.uppercased())": \(policyJSON),
          "\(brokerID.uuidString.lowercased())": \(policyJSON)
        }
      }
      """.utf8
    ).write(to: fileURL)

    #expect(
      throws: LocalHistoryRetentionSettingsError.corruptDocument
    ) {
      try LocalHistoryRetentionSettingsRepository(fileURL: fileURL)
    }
  }
}

private actor GatedHistorySettingsFilePolicy:
  HistoryRetentionSettingsFilePolicy
{
  private var applicationCount = 0
  private var firstStarted = false
  private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func apply(to url: URL) async {
    applicationCount += 1
    guard applicationCount == 1 else { return }
    firstStarted = true
    let waiters = firstStartWaiters
    firstStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      firstReleaseWaiters.append(continuation)
    }
  }

  func waitForFirstApplication() async {
    if firstStarted { return }
    await withCheckedContinuation { continuation in
      firstStartWaiters.append(continuation)
    }
  }

  func releaseFirstApplication() {
    let waiters = firstReleaseWaiters
    firstReleaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private struct FailingHistorySettingsFilePolicy:
  HistoryRetentionSettingsFilePolicy
{
  func apply(to url: URL) throws {
    throw TestHistorySettingsPolicyError.failed
  }
}

private enum TestHistorySettingsPolicyError: Error {
  case failed
}
