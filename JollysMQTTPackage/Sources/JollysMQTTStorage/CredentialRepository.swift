import Foundation

#if canImport(Security)
  import Security
#endif

public enum CredentialAvailability: Equatable, Sendable {
  case missing
  case available
}

public struct CredentialStatus: Equatable, Sendable {
  public let availability: CredentialAvailability
  public let revision: UInt64

  public init(availability: CredentialAvailability, revision: UInt64) {
    self.availability = availability
    self.revision = revision
  }
}

/// A short-lived password value intended to move directly from a secure field
/// into the credential repository.
///
/// Swift and Foundation may copy the backing storage, so this type cannot
/// promise complete zeroization. It does prevent accidental serialization and
/// redacts textual and reflected diagnostics.
public struct TransientCredential:
  Equatable,
  Sendable,
  CustomStringConvertible,
  CustomDebugStringConvertible,
  CustomReflectable
{
  fileprivate let storage: Data

  public init(utf8 value: String) {
    storage = Data(value.utf8)
  }

  init(bytes: Data) {
    storage = bytes
  }

  public var description: String { "<redacted credential>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(reflecting: description) }

  public static func == (
    lhs: TransientCredential,
    rhs: TransientCredential
  ) -> Bool {
    lhs.storage == rhs.storage
  }

  /// Exposes the UTF-8 password only for the synchronous construction of
  /// connection authentication input.
  public func withUTF8String<Result>(
    _ operation: (String) throws -> Result
  ) throws -> Result {
    guard let value = String(data: storage, encoding: .utf8) else {
      throw TransientCredentialError.invalidUTF8
    }
    return try operation(value)
  }

  fileprivate var secret: KeychainSecret {
    KeychainSecret(storage)
  }
}

public enum TransientCredentialError: Error, Equatable, Sendable {
  case invalidUTF8
}

public enum CredentialRepositoryError: Error, Equatable, Sendable {
  case missing
  case staleRevision(expected: UInt64, actual: UInt64)
  case cancelled
  case denied
  case keychainFailure(Int32)
  case revisionOverflow
}

public protocol CredentialRepositoryProtocol: Sendable {
  func status(for profileID: UUID) async throws -> CredentialStatus
  func save(
    _ credential: TransientCredential,
    for profileID: UUID
  ) async throws -> CredentialStatus
  func delete(for profileID: UUID) async throws -> CredentialStatus
}

public protocol ConnectionCredentialResolving: Sendable {
  func withCredential<Result: Sendable>(
    for profileID: UUID,
    expectedRevision: UInt64,
    operation: @Sendable (TransientCredential) async throws -> Result
  ) async throws -> Result
}

public actor CredentialRepository:
  CredentialRepositoryProtocol,
  ConnectionCredentialResolving
{
  public static let shared = CredentialRepository()

  private let keychain: any KeychainClient
  private var revisions: [UUID: UInt64] = [:]

  public init() {
    keychain = SystemKeychainClient()
  }

  init(
    keychain: any KeychainClient,
    revisions: [UUID: UInt64] = [:]
  ) {
    self.keychain = keychain
    self.revisions = revisions
  }

  public func status(for profileID: UUID) throws -> CredentialStatus {
    let request = KeychainContainsRequest(
      match: Self.match(for: profileID),
      returnData: false
    )
    let availability: CredentialAvailability
    switch keychain.contains(request) {
    case .success:
      availability = .available
    case .itemNotFound:
      availability = .missing
    case let failure:
      throw Self.error(for: failure)
    }
    return CredentialStatus(
      availability: availability,
      revision: revisions[profileID, default: 0]
    )
  }

  public func save(
    _ credential: TransientCredential,
    for profileID: UUID
  ) throws -> CredentialStatus {
    try requireRevisionCapacity(for: profileID)
    let match = Self.match(for: profileID)
    let update = KeychainUpdateRequest(
      match: match,
      value: credential.secret
    )

    switch keychain.update(update) {
    case .success:
      break
    case .itemNotFound:
      let add = KeychainAddRequest(
        match: match,
        accessibility: .whenUnlockedThisDeviceOnly,
        value: credential.secret
      )
      switch keychain.add(add) {
      case .success:
        break
      case .duplicateItem:
        try requireSuccess(keychain.update(update))
      case let failure:
        throw Self.error(for: failure)
      }
    case let failure:
      throw Self.error(for: failure)
    }

    return advanceRevision(
      for: profileID,
      availability: .available
    )
  }

  public func delete(for profileID: UUID) throws -> CredentialStatus {
    try requireRevisionCapacity(for: profileID)
    switch keychain.delete(
      KeychainDeleteRequest(match: Self.match(for: profileID))
    ) {
    case .success:
      return advanceRevision(for: profileID, availability: .missing)
    case .itemNotFound:
      return CredentialStatus(
        availability: .missing,
        revision: revisions[profileID, default: 0]
      )
    case let failure:
      throw Self.error(for: failure)
    }
  }

  /// Resolves a password only within the operation that prepares a connection.
  ///
  /// This API deliberately does not appear on `CredentialRepositoryProtocol`,
  /// which is the narrower dependency exposed to UI stores.
  public func withCredential<Result: Sendable>(
    for profileID: UUID,
    expectedRevision: UInt64,
    operation: @Sendable (TransientCredential) async throws -> Result
  ) async throws -> Result {
    try Task.checkCancellation()
    let actualRevision = revisions[profileID, default: 0]
    guard actualRevision == expectedRevision else {
      throw CredentialRepositoryError.staleRevision(
        expected: expectedRevision,
        actual: actualRevision
      )
    }
    let request = KeychainRetrieveRequest(
      match: Self.match(for: profileID),
      returnData: true
    )
    let credential: TransientCredential
    switch keychain.retrieve(request) {
    case .success(let secret):
      credential = TransientCredential(bytes: secret.data)
    case .itemNotFound:
      throw CredentialRepositoryError.missing
    case .userCancelled:
      throw CredentialRepositoryError.cancelled
    case .denied:
      throw CredentialRepositoryError.denied
    case .failure(let status):
      throw CredentialRepositoryError.keychainFailure(status)
    }
    try Task.checkCancellation()
    return try await operation(credential)
  }

  private func advanceRevision(
    for profileID: UUID,
    availability: CredentialAvailability
  ) -> CredentialStatus {
    let current = revisions[profileID, default: 0]
    let next = current + 1
    revisions[profileID] = next
    return CredentialStatus(availability: availability, revision: next)
  }

  private func requireRevisionCapacity(for profileID: UUID) throws {
    guard revisions[profileID, default: 0] < UInt64.max else {
      throw CredentialRepositoryError.revisionOverflow
    }
  }

  private func requireSuccess(_ result: KeychainClientResult) throws {
    guard result == .success else {
      throw Self.error(for: result)
    }
  }

  private static func match(for profileID: UUID) -> KeychainGenericPasswordMatch {
    KeychainGenericPasswordMatch(
      itemClass: .genericPassword,
      service: "eu.jinx.JollysMQTT.credentials.password.v1",
      account: profileID.uuidString.lowercased(),
      synchronizable: false
    )
  }

  private static func error(
    for result: KeychainClientResult
  ) -> CredentialRepositoryError {
    switch result {
    case .userCancelled:
      .cancelled
    case .denied:
      .denied
    case .failure(let status):
      .keychainFailure(status)
    case .itemNotFound, .duplicateItem, .success:
      .keychainFailure(result.unexpectedStatus)
    }
  }
}

enum KeychainItemClass: Equatable, Sendable {
  case genericPassword
}

enum KeychainAccessibility: Equatable, Sendable {
  case whenUnlockedThisDeviceOnly
}

struct KeychainGenericPasswordMatch: Equatable, Sendable {
  let itemClass: KeychainItemClass
  let service: String
  let account: String
  let synchronizable: Bool
}

struct KeychainSecret:
  Equatable,
  Sendable,
  CustomStringConvertible,
  CustomDebugStringConvertible,
  CustomReflectable
{
  private let storage: Data

  init(_ storage: Data) {
    self.storage = storage
  }

  init(_ credential: TransientCredential) {
    storage = credential.storage
  }

  var description: String { "<redacted credential bytes>" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(reflecting: description) }

  func matches(_ credential: TransientCredential) -> Bool {
    storage == credential.storage
  }

  var data: Data { storage }
}

struct KeychainContainsRequest: Equatable, Sendable {
  let match: KeychainGenericPasswordMatch
  let returnData: Bool
}

struct KeychainAddRequest: Equatable, Sendable {
  let match: KeychainGenericPasswordMatch
  let accessibility: KeychainAccessibility
  let value: KeychainSecret
}

struct KeychainUpdateRequest: Equatable, Sendable {
  let match: KeychainGenericPasswordMatch
  let value: KeychainSecret
}

struct KeychainDeleteRequest: Equatable, Sendable {
  let match: KeychainGenericPasswordMatch
}

struct KeychainRetrieveRequest: Equatable, Sendable {
  let match: KeychainGenericPasswordMatch
  let returnData: Bool
}

enum KeychainRetrieveResult: Equatable, Sendable {
  case success(KeychainSecret)
  case itemNotFound
  case userCancelled
  case denied
  case failure(Int32)
}

enum KeychainClientResult: Equatable, Sendable {
  case success
  case itemNotFound
  case duplicateItem
  case userCancelled
  case denied
  case failure(Int32)

  fileprivate var unexpectedStatus: Int32 {
    switch self {
    case .success: 0
    case .itemNotFound: -25_300
    case .duplicateItem: -25_299
    case .userCancelled: -128
    case .denied: -25_293
    case .failure(let status): status
    }
  }
}

protocol KeychainClient: Sendable {
  func contains(_ query: KeychainContainsRequest) -> KeychainClientResult
  func add(_ request: KeychainAddRequest) -> KeychainClientResult
  func update(_ request: KeychainUpdateRequest) -> KeychainClientResult
  func delete(_ query: KeychainDeleteRequest) -> KeychainClientResult
  func retrieve(_ query: KeychainRetrieveRequest) -> KeychainRetrieveResult
}

private struct SystemKeychainClient: KeychainClient {
  func contains(_ request: KeychainContainsRequest) -> KeychainClientResult {
    #if canImport(Security)
      return map(
        SecItemCopyMatching(
          SecurityKeychainAttributes.contains(request) as CFDictionary,
          nil
        )
      )
    #else
      return .failure(-1)
    #endif
  }

  func add(_ request: KeychainAddRequest) -> KeychainClientResult {
    #if canImport(Security)
      return map(
        SecItemAdd(
          SecurityKeychainAttributes.add(request) as CFDictionary,
          nil
        )
      )
    #else
      return .failure(-1)
    #endif
  }

  func update(_ request: KeychainUpdateRequest) -> KeychainClientResult {
    #if canImport(Security)
      return map(
        SecItemUpdate(
          SecurityKeychainAttributes.match(request.match) as CFDictionary,
          SecurityKeychainAttributes.update(request) as CFDictionary
        )
      )
    #else
      return .failure(-1)
    #endif
  }

  func delete(_ request: KeychainDeleteRequest) -> KeychainClientResult {
    #if canImport(Security)
      return map(
        SecItemDelete(
          SecurityKeychainAttributes.delete(request) as CFDictionary
        )
      )
    #else
      return .failure(-1)
    #endif
  }

  func retrieve(_ request: KeychainRetrieveRequest) -> KeychainRetrieveResult {
    #if canImport(Security)
      var result: CFTypeRef?
      let status = SecItemCopyMatching(
        SecurityKeychainAttributes.retrieve(request) as CFDictionary,
        &result
      )
      switch map(status) {
      case .success:
        guard let data = result as? Data else {
          return .failure(-1)
        }
        return .success(KeychainSecret(data))
      case .itemNotFound:
        return .itemNotFound
      case .userCancelled:
        return .userCancelled
      case .denied:
        return .denied
      case .duplicateItem, .failure:
        return .failure(status)
      }
    #else
      return .failure(-1)
    #endif
  }

  #if canImport(Security)
    private func map(_ status: OSStatus) -> KeychainClientResult {
      switch status {
      case errSecSuccess:
        .success
      case errSecItemNotFound:
        .itemNotFound
      case errSecDuplicateItem:
        .duplicateItem
      case errSecUserCanceled:
        .userCancelled
      case errSecAuthFailed, errSecInteractionNotAllowed:
        .denied
      default:
        .failure(status)
      }
    }
  #endif
}

#if canImport(Security)
  enum SecurityKeychainAttributes {
    static func contains(
      _ request: KeychainContainsRequest
    ) -> [CFString: Any] {
      var attributes = match(request.match)
      attributes[kSecMatchLimit] = kSecMatchLimitOne
      attributes[kSecReturnData] = request.returnData
      return attributes
    }

    static func add(_ request: KeychainAddRequest) -> [CFString: Any] {
      var attributes = match(request.match)
      attributes[kSecAttrAccessible] = accessibility(request.accessibility)
      attributes[kSecValueData] = request.value.data
      return attributes
    }

    static func update(_ request: KeychainUpdateRequest) -> [CFString: Any] {
      [kSecValueData: request.value.data]
    }

    static func delete(_ request: KeychainDeleteRequest) -> [CFString: Any] {
      match(request.match)
    }

    static func retrieve(_ request: KeychainRetrieveRequest) -> [CFString: Any] {
      var attributes = match(request.match)
      attributes[kSecMatchLimit] = kSecMatchLimitOne
      attributes[kSecReturnData] = request.returnData
      return attributes
    }

    static func match(
      _ match: KeychainGenericPasswordMatch
    ) -> [CFString: Any] {
      [
        kSecClass: itemClass(match.itemClass),
        kSecAttrService: match.service,
        kSecAttrAccount: match.account,
        kSecAttrSynchronizable: match.synchronizable,
      ]
    }

    private static func itemClass(_ itemClass: KeychainItemClass) -> CFString {
      switch itemClass {
      case .genericPassword:
        kSecClassGenericPassword
      }
    }

    private static func accessibility(
      _ accessibility: KeychainAccessibility
    ) -> CFString {
      switch accessibility {
      case .whenUnlockedThisDeviceOnly:
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      }
    }
  }
#endif
