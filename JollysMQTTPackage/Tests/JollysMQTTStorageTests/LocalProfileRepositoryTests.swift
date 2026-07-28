import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTTStorage

@Suite("Local profile document repository")
struct LocalProfileRepositoryTests {
  @Test("A versioned document restores profiles and explicit reorder rank after relaunch")
  func restoresProfilesAndRanks() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = RankedBrokerProfile(
      profile: fixtureProfile(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        name: "Production"
      ),
      reorderRank: 20
    )
    let second = RankedBrokerProfile(
      profile: fixtureProfile(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        name: "Lab"
      ),
      reorderRank: 10
    )

    let writer = LocalProfileRepository(fileURL: fileURL)
    try await writer.replaceAll([first, second])

    let relaunched = LocalProfileRepository(fileURL: fileURL)
    let restored = try await relaunched.load()

    #expect(restored == [second, first])
    let bytes = try Data(contentsOf: fileURL)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["version"] as? Int == 1)
  }

  @Test("Corrupt primary data is replaced from the last-known-good backup")
  func restoresBackupAfterCorruption() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let repository = LocalProfileRepository(fileURL: fileURL)
    let original = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Known Good"),
      reorderRank: 10
    )
    let newer = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Newer"),
      reorderRank: 20
    )
    try await repository.replaceAll([original])
    try await repository.replaceAll([original, newer])
    try Data("{not-json".utf8).write(to: fileURL)

    let recovered = try await LocalProfileRepository(fileURL: fileURL).load()
    #expect(recovered == [original])

    let restoredPrimary = try await LocalProfileRepository(fileURL: fileURL).load()
    #expect(restoredPrimary == [original])
  }

  @Test("The first successful write immediately establishes a recovery backup")
  func firstWriteEstablishesBackup() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let expected = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "First"),
      reorderRank: 10
    )
    try await LocalProfileRepository(fileURL: fileURL).replaceAll([expected])
    try Data("{truncated".utf8).write(to: fileURL)

    #expect(try await LocalProfileRepository(fileURL: fileURL).load() == [expected])
  }

  @Test("File protection is reapplied after every atomic profile document replacement")
  func reappliesFilePolicyAcrossWriteAndRecoveryPaths() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let policy = RecordingProfileFilePolicy()
    let repository = LocalProfileRepository(fileURL: fileURL, filePolicy: policy)
    let original = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Original"),
      reorderRank: 10
    )
    let newer = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Newer"),
      reorderRank: 20
    )

    try await repository.replaceAll([original])
    try await repository.replaceAll([original, newer])
    try Data("{corrupt".utf8).write(to: fileURL)
    _ = try await repository.load()
    _ = try await repository.load()

    #expect(
      await policy.applications() == [
        .init(url: fileURL.appendingPathExtension("backup"), role: .backup),
        .init(url: fileURL, role: .primary),
        .init(url: fileURL.appendingPathExtension("backup"), role: .backup),
        .init(url: fileURL, role: .primary),
        .init(url: fileURL.appendingPathExtension("backup"), role: .backup),
        .init(url: fileURL, role: .primary),
        .init(url: fileURL, role: .primary),
        .init(url: fileURL.appendingPathExtension("backup"), role: .backup),
      ]
    )
  }

  @Test("A load-time file policy failure is propagated instead of hidden by backup recovery")
  func propagatesLoadTimeFilePolicyFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Protected"),
      reorderRank: 10
    )
    try await LocalProfileRepository(fileURL: fileURL).replaceAll([profile])
    let repository = LocalProfileRepository(
      fileURL: fileURL,
      filePolicy: FailingProfileFilePolicy()
    )

    await #expect(throws: ProfileFilePolicyTestError.denied) {
      try await repository.load()
    }
  }

  @Test("An interrupted orphan write cannot replace the last complete document")
  func ignoresInterruptedOrphanWrite() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let expected = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Complete"),
      reorderRank: 10
    )
    let repository = LocalProfileRepository(fileURL: fileURL)
    try await repository.replaceAll([expected])
    try Data(repeating: 0xA5, count: 4_096).write(
      to: fileURL.appendingPathExtension("interrupted-write")
    )

    #expect(try await LocalProfileRepository(fileURL: fileURL).load() == [expected])
  }

  @Test("Serialized profiles and diagnostics contain no credential schema or bytes")
  func serializedPrivacyBoundary() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Private"),
      reorderRank: 10
    )
    try await LocalProfileRepository(fileURL: fileURL).replaceAll([profile])

    let serialized = try Data(contentsOf: fileURL)
    let backup = try Data(contentsOf: fileURL.appendingPathExtension("backup"))
    let diagnostics = String(reflecting: profile)
    let object = try JSONSerialization.jsonObject(with: serialized)
    let forbiddenKeys = [
      "\"password\"",
      "\"credential\"",
      "\"hasPassword\"",
      "\"passwordPresent\"",
      "\"credentialBytes\"",
    ]
    let credentialSentinel = Data("never-serialize-this-secret".utf8)

    for data in [serialized, backup] {
      let text = try #require(String(data: data, encoding: .utf8))
      #expect(forbiddenKeys.allSatisfy { !text.localizedCaseInsensitiveContains($0) })
      #expect(data.range(of: credentialSentinel) == nil)
    }
    #expect(forbiddenKeys.allSatisfy { !diagnostics.localizedCaseInsensitiveContains($0) })
    #expect(!diagnostics.contains("never-serialize-this-secret"))
    #expect(
      recursiveJSONKeys(in: object) == [
        "clientIDPolicy",
        "cleanSession",
        "exponential",
        "filter",
        "host",
        "id",
        "initialDelaySeconds",
        "isEnabled",
        "keepAliveSeconds",
        "maximumDelaySeconds",
        "name",
        "port",
        "profile",
        "profiles",
        "qos",
        "reconnectPolicy",
        "reorderRank",
        "stableGenerated",
        "subscriptions",
        "transport",
        "username",
        "version",
      ]
    )
  }

  @Test("A future document version is never downgraded through an older backup")
  func refusesFutureVersionEvenWithBackup() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let expected = RankedBrokerProfile(
      profile: fixtureProfile(id: UUID(), name: "Current"),
      reorderRank: 10
    )
    let repository = LocalProfileRepository(fileURL: fileURL)
    try await repository.replaceAll([expected])
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    object["version"] = 2
    try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

    await #expect(throws: LocalProfileRepositoryError.unsupportedVersion(2)) {
      try await LocalProfileRepository(fileURL: fileURL).load()
    }
  }
}

private actor RecordingProfileFilePolicy: ProfileFilePolicy {
  struct Application: Equatable, Sendable {
    let url: URL
    let role: ProfileFileRole
  }

  private var recorded: [Application] = []

  func apply(to url: URL, role: ProfileFileRole) {
    recorded.append(Application(url: url, role: role))
  }

  func applications() -> [Application] {
    recorded
  }
}

private enum ProfileFilePolicyTestError: Error {
  case denied
}

private struct FailingProfileFilePolicy: ProfileFilePolicy {
  func apply(to url: URL, role: ProfileFileRole) throws {
    throw ProfileFilePolicyTestError.denied
  }
}

private func recursiveJSONKeys(in value: Any) -> Set<String> {
  if let object = value as? [String: Any] {
    return object.reduce(into: Set(object.keys)) { result, element in
      result.formUnion(recursiveJSONKeys(in: element.value))
    }
  }
  if let array = value as? [Any] {
    return array.reduce(into: []) { result, value in
      result.formUnion(recursiveJSONKeys(in: value))
    }
  }
  return []
}

private func fixtureProfile(id: UUID, name: String) -> BrokerProfile {
  BrokerProfile(
    id: id,
    name: name,
    host: "broker.example",
    port: 8_883,
    transport: .tls,
    username: "operator",
    clientIDPolicy: .stableGenerated,
    cleanSession: true,
    keepAliveSeconds: 60,
    reconnectPolicy: .standard,
    subscriptions: [
      SubscriptionDefinition(filter: "site/#", qos: .atLeastOnce)
    ]
  )
}
