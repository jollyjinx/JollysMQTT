import Foundation
import JollysMQTTCore

public enum WorkspaceRoute: Codable, Equatable, Sendable {
  case serverList
  case connected(profileID: UUID)
}

public struct WorkspaceRecord: Codable, Equatable, Sendable {
  public let id: WorkspaceID
  public var route: WorkspaceRoute
  public var selectedProfileID: UUID?
  public var selectedTopic: String?
  public var closedAt: Date?

  public init(
    id: WorkspaceID,
    route: WorkspaceRoute = .serverList,
    selectedProfileID: UUID? = nil,
    selectedTopic: String? = nil,
    closedAt: Date? = nil
  ) {
    self.id = id
    self.route = route
    self.selectedProfileID = selectedProfileID
    self.selectedTopic = selectedTopic
    self.closedAt = closedAt
  }
}

public protocol WorkspaceRepositoryProtocol: Sendable {
  func load(id: WorkspaceID) async throws -> WorkspaceRecord
  func save(_ record: WorkspaceRecord) async throws
  func markClosed(id: WorkspaceID) async throws
  func pruneClosed() async throws
}

public enum LocalWorkspaceRepositoryError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
}

public protocol WorkspaceFilePolicy: Sendable {
  func apply(to url: URL) async throws
}

public struct SystemWorkspaceFilePolicy: WorkspaceFilePolicy {
  public init() {}

  public func apply(to url: URL) async throws {
    #if os(iOS)
      try FileManager.default.setAttributes(
        [
          .protectionKey:
            FileProtectionType.completeUntilFirstUserAuthentication
        ],
        ofItemAtPath: url.path
      )
    #endif
  }
}

public actor LocalWorkspaceRepository: WorkspaceRepositoryProtocol {
  public let directoryURL: URL

  private let fileManager: FileManager
  private let filePolicy: any WorkspaceFilePolicy
  private let decoder = JSONDecoder()
  private let encoder: JSONEncoder
  private let now: @Sendable () -> Date

  public init(
    directoryURL: URL,
    fileManager: FileManager = .default,
    filePolicy: any WorkspaceFilePolicy = SystemWorkspaceFilePolicy(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directoryURL = directoryURL
    self.fileManager = fileManager
    self.filePolicy = filePolicy
    self.now = now
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
  }

  public func load(id: WorkspaceID) async throws -> WorkspaceRecord {
    let url = fileURL(for: id)
    guard fileManager.fileExists(atPath: url.path) else {
      return WorkspaceRecord(id: id)
    }
    try await filePolicy.apply(to: url)
    let data = try Data(contentsOf: url)
    guard let probe = try? decoder.decode(WorkspaceVersionProbe.self, from: data)
    else {
      return WorkspaceRecord(id: id)
    }
    guard probe.version == WorkspaceDocument.currentVersion else {
      throw LocalWorkspaceRepositoryError.unsupportedVersion(probe.version)
    }
    guard
      let document = try? decoder.decode(WorkspaceDocument.self, from: data),
      document.record.id == id
    else {
      return WorkspaceRecord(id: id)
    }
    return document.record
  }

  public func save(_ record: WorkspaceRecord) async throws {
    let url = fileURL(for: record.id)
    if fileManager.fileExists(atPath: url.path) {
      let existing = try Data(contentsOf: url)
      if let probe = try? decoder.decode(WorkspaceVersionProbe.self, from: existing),
        probe.version != WorkspaceDocument.currentVersion
      {
        throw LocalWorkspaceRepositoryError.unsupportedVersion(probe.version)
      }
    }
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let document = WorkspaceDocument(
      version: WorkspaceDocument.currentVersion,
      record: record
    )
    try encoder.encode(document).write(
      to: url,
      options: [.atomic]
    )
    try await filePolicy.apply(to: url)
  }

  public func markClosed(id: WorkspaceID) async throws {
    var record = try await load(id: id)
    record.closedAt = now()
    try await save(record)
  }

  public func pruneClosed() async throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    let retentionCutoff = now().addingTimeInterval(-7 * 24 * 60 * 60)
    let files = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for url in files where url.pathExtension == "json" {
      let data = try Data(contentsOf: url)
      guard
        let probe = try? decoder.decode(WorkspaceVersionProbe.self, from: data),
        probe.version == WorkspaceDocument.currentVersion,
        let document = try? decoder.decode(WorkspaceDocument.self, from: data),
        let closedAt = document.record.closedAt,
        closedAt <= retentionCutoff
      else {
        continue
      }
      try fileManager.removeItem(at: url)
    }
  }

  private func fileURL(for id: WorkspaceID) -> URL {
    directoryURL.appending(
      path: "\(id.rawValue.uuidString.lowercased()).json",
      directoryHint: .notDirectory
    )
  }
}

private struct WorkspaceDocument: Codable, Sendable {
  static let currentVersion = 1

  let version: Int
  let record: WorkspaceRecord
}

private struct WorkspaceVersionProbe: Decodable {
  let version: Int
}
