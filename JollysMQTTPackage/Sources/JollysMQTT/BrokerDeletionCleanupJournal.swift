import Foundation

public struct BrokerDeletionCleanupEntry:
  Codable,
  Equatable,
  Sendable
{
  public let profileID: UUID
  public let options: BrokerDeletionOptions

  public init(
    profileID: UUID,
    options: BrokerDeletionOptions
  ) {
    self.profileID = profileID
    self.options = options
  }
}

public protocol BrokerDeletionCleanupJournaling: Sendable {
  func pendingEntries() async throws -> [BrokerDeletionCleanupEntry]
  func save(_ entry: BrokerDeletionCleanupEntry) async throws
  func remove(profileID: UUID) async throws
}

public actor MemoryBrokerDeletionCleanupJournal:
  BrokerDeletionCleanupJournaling
{
  private var entriesByID: [UUID: BrokerDeletionCleanupEntry]

  public init(entries: [BrokerDeletionCleanupEntry] = []) {
    entriesByID = Dictionary(
      uniqueKeysWithValues: entries.map { ($0.profileID, $0) }
    )
  }

  public func pendingEntries() -> [BrokerDeletionCleanupEntry] {
    entriesByID.values.sorted {
      $0.profileID.uuidString < $1.profileID.uuidString
    }
  }

  public func save(_ entry: BrokerDeletionCleanupEntry) {
    entriesByID[entry.profileID] = entry
  }

  public func remove(profileID: UUID) {
    entriesByID[profileID] = nil
  }
}

actor LocalBrokerDeletionCleanupJournal:
  BrokerDeletionCleanupJournaling
{
  private struct Document: Codable {
    static let currentVersion = 1

    let version: Int
    let entries: [BrokerDeletionCleanupEntry]
  }

  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func pendingEntries() throws -> [BrokerDeletionCleanupEntry] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }
    let document = try JSONDecoder().decode(
      Document.self,
      from: Data(contentsOf: fileURL)
    )
    guard document.version == Document.currentVersion else {
      throw BrokerDeletionCleanupJournalError.unsupportedVersion
    }
    guard
      Set(document.entries.map(\.profileID)).count
        == document.entries.count
    else {
      throw BrokerDeletionCleanupJournalError.corruptDocument
    }
    return document.entries.sorted {
      $0.profileID.uuidString < $1.profileID.uuidString
    }
  }

  func save(_ entry: BrokerDeletionCleanupEntry) throws {
    var entries = try pendingEntries()
    entries.removeAll { $0.profileID == entry.profileID }
    entries.append(entry)
    try replace(entries)
  }

  func remove(profileID: UUID) throws {
    var entries = try pendingEntries()
    entries.removeAll { $0.profileID == profileID }
    try replace(entries)
  }

  private func replace(_ entries: [BrokerDeletionCleanupEntry]) throws {
    if entries.isEmpty {
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.removeItem(at: fileURL)
      }
      return
    }
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(
      Document(
        version: Document.currentVersion,
        entries: entries.sorted {
          $0.profileID.uuidString < $1.profileID.uuidString
        }
      )
    ).write(to: fileURL, options: [.atomic])
    #if os(iOS)
      try FileManager.default.setAttributes(
        [
          .protectionKey:
            FileProtectionType.completeUntilFirstUserAuthentication
        ],
        ofItemAtPath: fileURL.path
      )
    #endif
  }
}

enum BrokerDeletionCleanupJournalError: Error {
  case unsupportedVersion
  case corruptDocument
}
