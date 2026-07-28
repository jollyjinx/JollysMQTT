import Foundation
import JollysMQTTCore

public struct RankedBrokerProfile: Codable, Hashable, Identifiable, Sendable {
  public var id: BrokerProfile.ID { profile.id }

  public let profile: BrokerProfile
  public let reorderRank: Int64

  public init(profile: BrokerProfile, reorderRank: Int64) {
    self.profile = profile
    self.reorderRank = reorderRank
  }
}

public protocol ProfileRepositoryProtocol: Sendable {
  func load() async throws -> [RankedBrokerProfile]
  func replaceAll(_ profiles: [RankedBrokerProfile]) async throws
}

public enum LocalProfileRepositoryError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case corruptDocument
  case invalidProfile(BrokerProfile.ID)
  case duplicateProfile(BrokerProfile.ID)
}

public enum ProfileFileRole: Sendable {
  case primary
  case backup
}

public protocol ProfileFilePolicy: Sendable {
  func apply(to url: URL, role: ProfileFileRole) async throws
}

public struct SystemProfileFilePolicy: ProfileFilePolicy {
  public init() {}

  public func apply(to url: URL, role: ProfileFileRole) async throws {
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

public actor LocalProfileRepository: ProfileRepositoryProtocol {
  public let fileURL: URL
  public let backupURL: URL

  private let fileManager: FileManager
  private let filePolicy: any ProfileFilePolicy
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    fileURL: URL,
    fileManager: FileManager = .default,
    filePolicy: any ProfileFilePolicy = SystemProfileFilePolicy()
  ) {
    self.fileURL = fileURL
    self.backupURL = fileURL.appendingPathExtension("backup")
    self.fileManager = fileManager
    self.filePolicy = filePolicy

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
    self.decoder = JSONDecoder()
  }

  public func load() async throws -> [RankedBrokerProfile] {
    guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

    let primaryDocument: LocalProfileDocument
    do {
      primaryDocument = try readValidatedDocument(at: fileURL)
    } catch let primaryError as LocalProfileRepositoryError {
      guard primaryError.isRecoverableFromBackup else {
        throw primaryError
      }
      guard fileManager.fileExists(atPath: backupURL.path),
        let backup = try? readValidatedDocument(at: backupURL)
      else {
        throw primaryError
      }

      try await filePolicy.apply(to: backupURL, role: .backup)
      let backupData = try encoder.encode(backup)
      try backupData.write(to: fileURL, options: [.atomic])
      try await filePolicy.apply(to: fileURL, role: .primary)
      return backup.sortedForDisplay
    } catch {
      throw error
    }

    try await filePolicy.apply(to: fileURL, role: .primary)
    if fileManager.fileExists(atPath: backupURL.path) {
      try await filePolicy.apply(to: backupURL, role: .backup)
    }
    return primaryDocument.sortedForDisplay
  }

  public func replaceAll(_ profiles: [RankedBrokerProfile]) async throws {
    try validate(profiles)

    let document = LocalProfileDocument(
      version: LocalProfileDocument.currentVersion,
      profiles: profiles.sortedForStorage
    )
    let encoded = try encoder.encode(document)
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    if fileManager.fileExists(atPath: fileURL.path),
      let currentData = try? Data(contentsOf: fileURL),
      (try? readValidatedDocument(data: currentData)) != nil
    {
      try currentData.write(to: backupURL, options: [.atomic])
      try await filePolicy.apply(to: backupURL, role: .backup)
    } else if !fileManager.fileExists(atPath: backupURL.path) {
      try encoded.write(to: backupURL, options: [.atomic])
      try await filePolicy.apply(to: backupURL, role: .backup)
    }

    try encoded.write(to: fileURL, options: [.atomic])
    try await filePolicy.apply(to: fileURL, role: .primary)
  }

  private func readValidatedDocument(at url: URL) throws -> LocalProfileDocument {
    try readValidatedDocument(data: Data(contentsOf: url))
  }

  private func readValidatedDocument(data: Data) throws -> LocalProfileDocument {
    let document: LocalProfileDocument
    do {
      document = try decoder.decode(LocalProfileDocument.self, from: data)
    } catch {
      throw LocalProfileRepositoryError.corruptDocument
    }
    guard document.version == LocalProfileDocument.currentVersion else {
      throw LocalProfileRepositoryError.unsupportedVersion(document.version)
    }
    try validate(document.profiles)
    return document
  }

  private func validate(_ profiles: [RankedBrokerProfile]) throws {
    var seen: Set<BrokerProfile.ID> = []
    for ranked in profiles {
      guard ranked.profile.validationIssues.isEmpty else {
        throw LocalProfileRepositoryError.invalidProfile(ranked.id)
      }
      guard seen.insert(ranked.id).inserted else {
        throw LocalProfileRepositoryError.duplicateProfile(ranked.id)
      }
    }
  }
}

extension LocalProfileRepositoryError {
  fileprivate var isRecoverableFromBackup: Bool {
    switch self {
    case .corruptDocument, .invalidProfile, .duplicateProfile:
      true
    case .unsupportedVersion:
      false
    }
  }
}

private struct LocalProfileDocument: Codable, Sendable {
  static let currentVersion = 1

  let version: Int
  let profiles: [RankedBrokerProfile]

  var sortedForDisplay: [RankedBrokerProfile] {
    profiles.sortedForStorage
  }
}

extension Array where Element == RankedBrokerProfile {
  fileprivate var sortedForStorage: Self {
    sorted {
      if $0.reorderRank == $1.reorderRank {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.reorderRank < $1.reorderRank
    }
  }
}
