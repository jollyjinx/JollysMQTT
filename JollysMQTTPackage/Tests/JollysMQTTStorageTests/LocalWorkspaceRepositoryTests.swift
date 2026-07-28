import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@Suite("Local workspace repository")
struct LocalWorkspaceRepositoryTests {
  @Test("A missing workspace opens at the server list")
  func missingWorkspaceUsesDefaultRecord() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    let record = try await repository.load(id: id)

    #expect(record == WorkspaceRecord(id: id))
    #expect(record.route == .serverList)
  }

  @Test("A workspace round-trips through a versioned atomic document")
  func workspaceRoundTripIsVersioned() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let profileID = UUID()
    let expected = WorkspaceRecord(
      id: id,
      route: .connected(profileID: profileID),
      selectedProfileID: profileID,
      selectedTopic: "factory/line/status"
    )
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    try await repository.save(expected)

    let data = try Data(contentsOf: fixture.fileURL(for: id))
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["version"] as? Int == 1)
    let relaunched = LocalWorkspaceRepository(directoryURL: fixture.directory)
    #expect(try await relaunched.load(id: id) == expected)
  }

  @Test("An undecodable current workspace recovers to the server list")
  func corruptWorkspaceRecoversSafely() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    try Data(#"{"version":1,"record":{"broken":true}}"#.utf8)
      .write(to: fixture.fileURL(for: id), options: [.atomic])
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    let recovered = try await repository.load(id: id)

    #expect(recovered == WorkspaceRecord(id: id))
    #expect(
      try Data(contentsOf: fixture.fileURL(for: id))
        == Data(#"{"version":1,"record":{"broken":true}}"#.utf8)
    )
  }

  @Test("A future workspace version is surfaced and cannot be downgraded")
  func futureVersionIsPreserved() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let futureData = Data(#"{"version":77,"record":{"future":"state"}}"#.utf8)
    try futureData.write(to: fixture.fileURL(for: id), options: [.atomic])
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    await #expect(
      throws: LocalWorkspaceRepositoryError.unsupportedVersion(77)
    ) {
      try await repository.load(id: id)
    }
    await #expect(
      throws: LocalWorkspaceRepositoryError.unsupportedVersion(77)
    ) {
      try await repository.save(WorkspaceRecord(id: id))
    }
    #expect(try Data(contentsOf: fixture.fileURL(for: id)) == futureData)
  }

  @Test("Closed records are retained for seven days and pruned deterministically")
  func closedRecordRetention() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000)
    let staleID = WorkspaceID()
    let recentID = WorkspaceID()
    let openID = WorkspaceID()
    let repository = LocalWorkspaceRepository(
      directoryURL: fixture.directory,
      now: { now }
    )
    try await repository.save(
      WorkspaceRecord(
        id: staleID,
        closedAt: now.addingTimeInterval(-7 * 24 * 60 * 60)
      )
    )
    try await repository.save(
      WorkspaceRecord(
        id: recentID,
        closedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 1)
      )
    )
    try await repository.save(WorkspaceRecord(id: openID))

    try await repository.pruneClosed()

    #expect(!FileManager.default.fileExists(atPath: fixture.fileURL(for: staleID).path))
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL(for: recentID).path))
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL(for: openID).path))
  }

  @Test("Data protection is applied after atomic writes and on load")
  func appliesWorkspaceFilePolicy() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let policy = RecordingWorkspaceFilePolicy()
    let repository = LocalWorkspaceRepository(
      directoryURL: fixture.directory,
      filePolicy: policy
    )

    try await repository.save(WorkspaceRecord(id: id))
    _ = try await repository.load(id: id)

    #expect(
      await policy.appliedURLs() == [
        fixture.fileURL(for: id),
        fixture.fileURL(for: id),
      ]
    )
  }
}

private actor RecordingWorkspaceFilePolicy: WorkspaceFilePolicy {
  private var urls: [URL] = []

  func apply(to url: URL) {
    urls.append(url)
  }

  func appliedURLs() -> [URL] { urls }
}

private struct WorkspaceFixture {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func fileURL(for id: WorkspaceID) -> URL {
    directory.appending(
      path: "\(id.rawValue.uuidString.lowercased()).json",
      directoryHint: .notDirectory
    )
  }
}
