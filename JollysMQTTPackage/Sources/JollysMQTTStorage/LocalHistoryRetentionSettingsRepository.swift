import Foundation
import JollysMQTTCore
import Synchronization

public protocol HistoryRetentionSettingsRepositoryProtocol: Sendable {
  func policy(for brokerID: UUID) -> HistoryRetentionPolicy
  func save(
    _ policy: HistoryRetentionPolicy,
    for brokerID: UUID
  ) async throws
  func removePolicy(for brokerID: UUID) async throws
}

public enum LocalHistoryRetentionSettingsError:
  Error,
  Equatable,
  Sendable
{
  case unsupportedVersion(Int)
  case corruptDocument
  case unavailable
  /// The atomic document replacement succeeded, but applying the platform
  /// protection policy failed. The new value remains authoritative.
  case filePolicyAfterCommit
}

/// Preserves a settings initialization failure as a visible write failure.
///
/// Reads use safe defaults so broker feeds remain available, while saves and
/// removals fail rather than pretending that volatile settings are durable.
public struct UnavailableHistoryRetentionSettingsRepository:
  HistoryRetentionSettingsRepositoryProtocol
{
  public init() {}

  public func policy(for brokerID: UUID) -> HistoryRetentionPolicy {
    .default
  }

  public func save(
    _ policy: HistoryRetentionPolicy,
    for brokerID: UUID
  ) async throws {
    throw LocalHistoryRetentionSettingsError.unavailable
  }

  public func removePolicy(for brokerID: UUID) async throws {
    throw LocalHistoryRetentionSettingsError.unavailable
  }
}

public protocol HistoryRetentionSettingsFilePolicy: Sendable {
  func apply(to url: URL) async throws
}

public struct SystemHistoryRetentionSettingsFilePolicy:
  HistoryRetentionSettingsFilePolicy
{
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

public final class LocalHistoryRetentionSettingsRepository:
  HistoryRetentionSettingsRepositoryProtocol,
  Sendable
{
  private let cache: HistoryRetentionPolicyCache
  private let writer: HistoryRetentionSettingsDocumentWriter

  public init(
    fileURL: URL,
    filePolicy: any HistoryRetentionSettingsFilePolicy =
      SystemHistoryRetentionSettingsFilePolicy()
  ) throws {
    let document: HistoryRetentionSettingsDocument
    if FileManager.default.fileExists(atPath: fileURL.path) {
      do {
        document = try JSONDecoder().decode(
          HistoryRetentionSettingsDocument.self,
          from: Data(contentsOf: fileURL)
        )
      } catch let error as LocalHistoryRetentionSettingsError {
        throw error
      } catch {
        throw LocalHistoryRetentionSettingsError.corruptDocument
      }
      guard document.version == HistoryRetentionSettingsDocument.currentVersion else {
        throw LocalHistoryRetentionSettingsError.unsupportedVersion(
          document.version
        )
      }
    } else {
      document = .empty
    }
    let policies = try Self.validatedPolicies(document.policies)
    let cache = HistoryRetentionPolicyCache(policies)
    self.cache = cache
    writer = HistoryRetentionSettingsDocumentWriter(
      fileURL: fileURL,
      filePolicy: filePolicy,
      document: document,
      cache: cache
    )
  }

  public func policy(for brokerID: UUID) -> HistoryRetentionPolicy {
    cache.policy(for: brokerID)
  }

  public func save(
    _ policy: HistoryRetentionPolicy,
    for brokerID: UUID
  ) async throws {
    try await writer.save(policy, for: brokerID)
  }

  public func removePolicy(for brokerID: UUID) async throws {
    try await writer.removePolicy(for: brokerID)
  }

  private static func validatedPolicies(
    _ encoded: [String: HistoryRetentionPolicy]
  ) throws -> [UUID: HistoryRetentionPolicy] {
    var result: [UUID: HistoryRetentionPolicy] = [:]
    result.reserveCapacity(encoded.count)
    for (key, policy) in encoded {
      guard let brokerID = UUID(uuidString: key), result[brokerID] == nil else {
        throw LocalHistoryRetentionSettingsError.corruptDocument
      }
      result[brokerID] = policy
    }
    return result
  }
}

public final class MemoryHistoryRetentionSettingsRepository:
  HistoryRetentionSettingsRepositoryProtocol,
  Sendable
{
  private let policies: Mutex<[UUID: HistoryRetentionPolicy]>

  public init(
    policies: [UUID: HistoryRetentionPolicy] = [:]
  ) {
    self.policies = Mutex(policies)
  }

  public func policy(for brokerID: UUID) -> HistoryRetentionPolicy {
    policies.withLock { $0[brokerID] ?? .default }
  }

  public func save(
    _ policy: HistoryRetentionPolicy,
    for brokerID: UUID
  ) {
    policies.withLock { $0[brokerID] = policy }
  }

  public func removePolicy(for brokerID: UUID) {
    policies.withLock { $0[brokerID] = nil }
  }
}

private struct HistoryRetentionSettingsDocument: Codable, Sendable {
  static let currentVersion = 1
  static let empty = HistoryRetentionSettingsDocument(
    version: currentVersion,
    policies: [:]
  )

  let version: Int
  let policies: [String: HistoryRetentionPolicy]
}

private actor HistoryRetentionSettingsDocumentWriter {
  private let fileURL: URL
  private let filePolicy: any HistoryRetentionSettingsFilePolicy
  private let cache: HistoryRetentionPolicyCache
  private var document: HistoryRetentionSettingsDocument

  init(
    fileURL: URL,
    filePolicy: any HistoryRetentionSettingsFilePolicy,
    document: HistoryRetentionSettingsDocument,
    cache: HistoryRetentionPolicyCache
  ) {
    self.fileURL = fileURL
    self.filePolicy = filePolicy
    self.document = document
    self.cache = cache
  }

  func save(
    _ policy: HistoryRetentionPolicy,
    for brokerID: UUID
  ) async throws {
    var policies = document.policies
    policies[brokerID.uuidString.lowercased()] = policy
    try await replace(
      with: HistoryRetentionSettingsDocument(
        version: HistoryRetentionSettingsDocument.currentVersion,
        policies: policies
      )
    )
  }

  func removePolicy(for brokerID: UUID) async throws {
    var policies = document.policies
    policies[brokerID.uuidString.lowercased()] = nil
    try await replace(
      with: HistoryRetentionSettingsDocument(
        version: HistoryRetentionSettingsDocument.currentVersion,
        policies: policies
      )
    )
  }

  private func replace(
    with replacement: HistoryRetentionSettingsDocument
  ) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
      .prettyPrinted,
      .sortedKeys,
      .withoutEscapingSlashes,
    ]
    let data = try encoder.encode(replacement)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
    document = replacement
    cache.replace(with: try Self.validatedPolicies(replacement.policies))
    do {
      try await filePolicy.apply(to: fileURL)
    } catch {
      throw LocalHistoryRetentionSettingsError.filePolicyAfterCommit
    }
  }

  private static func validatedPolicies(
    _ encoded: [String: HistoryRetentionPolicy]
  ) throws -> [UUID: HistoryRetentionPolicy] {
    var result: [UUID: HistoryRetentionPolicy] = [:]
    result.reserveCapacity(encoded.count)
    for (key, policy) in encoded {
      guard let brokerID = UUID(uuidString: key), result[brokerID] == nil else {
        throw LocalHistoryRetentionSettingsError.corruptDocument
      }
      result[brokerID] = policy
    }
    return result
  }
}

private final class HistoryRetentionPolicyCache: Sendable {
  private let policies: Mutex<[UUID: HistoryRetentionPolicy]>

  init(_ policies: [UUID: HistoryRetentionPolicy]) {
    self.policies = Mutex(policies)
  }

  func policy(for brokerID: UUID) -> HistoryRetentionPolicy {
    policies.withLock { $0[brokerID] ?? .default }
  }

  func replace(with replacement: [UUID: HistoryRetentionPolicy]) {
    policies.withLock { $0 = replacement }
  }
}
