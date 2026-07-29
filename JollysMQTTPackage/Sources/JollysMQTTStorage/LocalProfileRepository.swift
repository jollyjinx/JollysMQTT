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

public protocol ProfileReplicaRepositoryProtocol:
  ProfileRepositoryProtocol
{
  func loadReplica() async throws -> ProfileReplica
  func replaceReplica(_ replica: ProfileReplica) async throws
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

public actor LocalProfileRepository: ProfileReplicaRepositoryProtocol {
  public let fileURL: URL
  public let backupURL: URL

  private let fileManager: FileManager
  private let filePolicy: any ProfileFilePolicy
  private let installationID: UUID
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    fileURL: URL,
    fileManager: FileManager = .default,
    filePolicy: any ProfileFilePolicy = SystemProfileFilePolicy(),
    installationID: UUID
  ) {
    self.fileURL = fileURL
    self.backupURL = fileURL.appendingPathExtension("backup")
    self.fileManager = fileManager
    self.filePolicy = filePolicy
    self.installationID = installationID

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
    self.decoder = JSONDecoder()
  }

  public func load() async throws -> [RankedBrokerProfile] {
    try await loadReplica().visibleProfiles
  }

  public func loadReplica() async throws -> ProfileReplica {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return try ProfileReplica()
    }

    let primaryReplica: ProfileReplica
    do {
      primaryReplica = try readValidatedReplica(at: fileURL)
    } catch let primaryError as LocalProfileRepositoryError {
      guard primaryError.isRecoverableFromBackup else {
        throw primaryError
      }
      guard fileManager.fileExists(atPath: backupURL.path),
        let backup = try? readValidatedReplica(at: backupURL)
      else {
        throw primaryError
      }

      try await filePolicy.apply(to: backupURL, role: .backup)
      let backupData = try encode(replica: backup)
      try backupData.write(to: fileURL, options: [.atomic])
      try await filePolicy.apply(to: fileURL, role: .primary)
      return backup
    } catch {
      throw error
    }

    try await filePolicy.apply(to: fileURL, role: .primary)
    if fileManager.fileExists(atPath: backupURL.path) {
      try await filePolicy.apply(to: backupURL, role: .backup)
    }
    return primaryReplica
  }

  public func replaceAll(_ profiles: [RankedBrokerProfile]) async throws {
    try validate(profiles)
    let current =
      if fileManager.fileExists(atPath: fileURL.path) {
        try readValidatedReplica(at: fileURL)
      } else {
        try ProfileReplica()
      }
    let updated = try current.applyingLocalSnapshot(
      profiles,
      installationID: installationID
    )
    try await replaceReplica(updated)
  }

  public func replaceReplica(_ replica: ProfileReplica) async throws {
    try validate(replica.visibleProfiles)
    let encoded = try encode(replica: replica)
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    var wroteBackup = false
    if fileManager.fileExists(atPath: fileURL.path),
      let currentData = try? Data(contentsOf: fileURL),
      (try? readValidatedReplica(data: currentData)) != nil
    {
      // A stale backup containing a live profile must never be able to undo a
      // committed deletion after primary-file corruption. Once the replica
      // contains any permanent tombstone, keep the recovery copy at the same
      // deletion-safe state. Non-deletion writes retain the prior-known-good
      // rollback behavior.
      let backupData =
        replica.records.contains(where: { $0.tombstone != nil })
        ? encoded
        : currentData
      try backupData.write(to: backupURL, options: [.atomic])
      wroteBackup = true
    } else if !fileManager.fileExists(atPath: backupURL.path) {
      try encoded.write(to: backupURL, options: [.atomic])
      wroteBackup = true
    }

    try encoded.write(to: fileURL, options: [.atomic])
    if wroteBackup {
      try await filePolicy.apply(to: backupURL, role: .backup)
    }
    try await filePolicy.apply(to: fileURL, role: .primary)
  }

  private func readValidatedReplica(at url: URL) throws -> ProfileReplica {
    try readValidatedReplica(data: Data(contentsOf: url))
  }

  private func readValidatedReplica(data: Data) throws -> ProfileReplica {
    let header: LocalProfileDocumentHeader
    do {
      header = try decoder.decode(
        LocalProfileDocumentHeader.self,
        from: data
      )
    } catch {
      throw LocalProfileRepositoryError.corruptDocument
    }

    switch header.version {
    case 1:
      do {
        let legacy = try decoder.decode(
          LocalProfileDocumentV1.self,
          from: data
        )
        try validate(legacy.profiles)
        return try ProfileReplica(
          records: legacy.profiles.map {
            ProfileReplicaRecord(
              id: $0.id,
              content: ProfileContentRegister(
                value: $0.profile,
                revision: .legacy
              ),
              rank: ProfileRankRegister(
                value: $0.reorderRank,
                revision: .legacy
              ),
              tombstone: nil
            )
          }
        )
      } catch let error as LocalProfileRepositoryError {
        throw error
      } catch {
        throw LocalProfileRepositoryError.corruptDocument
      }

    case LocalProfileDocumentV2.currentVersion:
      do {
        let document = try decoder.decode(
          LocalProfileDocumentV2.self,
          from: data
        )
        return try ProfileReplica(records: document.records)
      } catch {
        throw LocalProfileRepositoryError.corruptDocument
      }

    default:
      throw LocalProfileRepositoryError.unsupportedVersion(
        header.version
      )
    }
  }

  private func encode(replica: ProfileReplica) throws -> Data {
    try encoder.encode(
      LocalProfileDocumentV2(
        version: LocalProfileDocumentV2.currentVersion,
        records: replica.records
      )
    )
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

private struct LocalProfileDocumentHeader: Decodable, Sendable {
  let version: Int
}

private struct LocalProfileDocumentV1: Codable, Sendable {
  let version: Int
  let profiles: [RankedBrokerProfile]
}

private struct LocalProfileDocumentV2: Codable, Sendable {
  static let currentVersion = 2

  let version: Int
  let records: [ProfileReplicaRecord]
}
