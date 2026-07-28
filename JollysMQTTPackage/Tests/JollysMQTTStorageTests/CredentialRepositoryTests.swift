import Foundation
import Security
import Synchronization
import Testing

@testable import JollysMQTTStorage

@Suite("Device-only credential repository")
struct CredentialRepositoryTests {
  @Test("A saved password uses one non-synchronizable device-only generic-password item")
  func savesDeviceOnlyGenericPassword() async throws {
    let client = RecordingKeychainClient()
    let repository = CredentialRepository(keychain: client)
    let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let password = randomCredential()

    let status = try await repository.save(password, for: profileID)

    #expect(status == CredentialStatus(availability: .available, revision: 1))
    let operations = client.operations()
    #expect(operations.count == 2)
    let update = try #require(operations.first?.updateRequest)
    assertStableDeviceOnlyMatch(update.match, profileID: profileID)
    #expect(update.value.matches(password))
    let add = try #require(operations.last?.addRequest)
    assertStableDeviceOnlyMatch(add.match, profileID: profileID)
    #expect(add.accessibility == .whenUnlockedThisDeviceOnly)
    #expect(add.value.matches(password))
  }

  @Test("Replacement advances revision only after the Keychain update succeeds")
  func replacementRevisionFollowsSuccessfulMutation() async throws {
    let client = RecordingKeychainClient(
      scriptedResults: [.itemNotFound, .success, .success, .denied, .success]
    )
    let repository = CredentialRepository(keychain: client)
    let profileID = UUID()

    #expect(
      try await repository.save(randomCredential(), for: profileID).revision == 1
    )
    #expect(
      try await repository.save(randomCredential(), for: profileID).revision == 2
    )
    await #expect(throws: CredentialRepositoryError.denied) {
      try await repository.save(randomCredential(), for: profileID)
    }
    #expect(try await repository.status(for: profileID).revision == 2)
  }

  @Test(
    "Availability queries request no password bytes",
    arguments: [
      (KeychainClientResult.success, CredentialAvailability.available),
      (.itemNotFound, .missing),
    ]
  )
  func availabilityDoesNotLoadSecret(
    result: KeychainClientResult,
    expected: CredentialAvailability
  ) async throws {
    let client = RecordingKeychainClient(scriptedResults: [result])
    let repository = CredentialRepository(keychain: client)
    let profileID = UUID()

    let status = try await repository.status(for: profileID)

    #expect(status.availability == expected)
    let query = try #require(client.operations().first?.containsQuery)
    assertStableDeviceOnlyMatch(query.match, profileID: profileID)
    #expect(query.returnData == false)
  }

  @Test("Cancellation and denial are modeled without advancing revision")
  func expectedFailuresAreModeled() async throws {
    let profileID = UUID()

    for (result, expected) in [
      (KeychainClientResult.userCancelled, CredentialRepositoryError.cancelled),
      (.denied, .denied),
    ] {
      let client = RecordingKeychainClient(
        scriptedResults: [result, .itemNotFound]
      )
      let repository = CredentialRepository(keychain: client)
      await #expect(throws: expected) {
        try await repository.save(randomCredential(), for: profileID)
      }
      #expect(try await repository.status(for: profileID).revision == 0)
    }
  }

  @Test("Revision capacity is checked before any Keychain mutation")
  func revisionOverflowDoesNotMutateKeychain() async {
    let client = RecordingKeychainClient(scriptedResults: [.success])
    let profileID = UUID()
    let repository = CredentialRepository(
      keychain: client,
      revisions: [profileID: .max]
    )

    await #expect(throws: CredentialRepositoryError.revisionOverflow) {
      try await repository.save(randomCredential(), for: profileID)
    }
    #expect(client.operations().isEmpty)
  }

  @Test("The Security translator emits the exact query and mutation dictionaries")
  func securityDictionaryTranslation() throws {
    let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let match = KeychainGenericPasswordMatch(
      itemClass: .genericPassword,
      service: "eu.jinx.JollysMQTT.credentials.password.v1",
      account: profileID.uuidString.lowercased(),
      synchronizable: false
    )
    let credential = randomCredential()
    let secret = KeychainSecret(credential)

    let contains = SecurityKeychainAttributes.contains(
      KeychainContainsRequest(match: match, returnData: false)
    )
    #expect(contains.count == 6)
    assertSecurityMatch(contains, profileID: profileID)
    #expect(contains[kSecMatchLimit] as? String == kSecMatchLimitOne as String)
    #expect(contains[kSecReturnData] as? Bool == false)

    let add = SecurityKeychainAttributes.add(
      KeychainAddRequest(
        match: match,
        accessibility: .whenUnlockedThisDeviceOnly,
        value: secret
      )
    )
    #expect(add.count == 6)
    assertSecurityMatch(add, profileID: profileID)
    #expect(
      add[kSecAttrAccessible] as? String
        == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    )
    #expect((add[kSecValueData] as? Data) == secret.data)

    let update = SecurityKeychainAttributes.update(
      KeychainUpdateRequest(match: match, value: secret)
    )
    #expect(update.count == 1)
    #expect((update[kSecValueData] as? Data) == secret.data)

    let deletion = SecurityKeychainAttributes.delete(
      KeychainDeleteRequest(match: match)
    )
    #expect(deletion.count == 4)
    assertSecurityMatch(deletion, profileID: profileID)
  }

  @Test("Connection preparation resolves bytes only inside a scoped operation")
  func scopedCredentialResolution() async throws {
    let profileID = UUID()
    let credential = randomCredential()
    let client = RecordingKeychainClient(
      retrievalResults: [.success(KeychainSecret(credential))]
    )
    let repository = CredentialRepository(keychain: client)

    let matched = try await repository.withCredential(
      for: profileID,
      expectedRevision: 0
    ) { resolved in
      resolved == credential
    }

    #expect(matched)
    let request = try #require(client.operations().first?.retrieveRequest)
    assertStableDeviceOnlyMatch(request.match, profileID: profileID)
    #expect(request.returnData)
    let attributes = SecurityKeychainAttributes.retrieve(request)
    #expect(attributes.count == 6)
    #expect(attributes[kSecReturnData] as? Bool == true)
    #expect(attributes[kSecAttrAccessible] == nil)
    #expect(attributes[kSecValueData] == nil)
  }

  @Test("Scoped resolution rejects a stale generation before loading bytes")
  func staleResolutionDoesNotLoadCredential() async {
    let profileID = UUID()
    let client = RecordingKeychainClient(
      retrievalResults: [.success(KeychainSecret(randomCredential()))]
    )
    let repository = CredentialRepository(
      keychain: client,
      revisions: [profileID: 4]
    )

    await #expect(
      throws: CredentialRepositoryError.staleRevision(expected: 3, actual: 4)
    ) {
      try await repository.withCredential(
        for: profileID,
        expectedRevision: 3
      ) { _ in
        Issue.record("A stale generation must not receive credential material")
      }
    }
    #expect(client.operations().isEmpty)
  }

  @Test("Invalid legacy Keychain bytes cannot become an MQTT password string")
  func invalidUTF8IsRejectedAtConnectionBoundary() async {
    let profileID = UUID()
    let client = RecordingKeychainClient(
      retrievalResults: [.success(KeychainSecret(Data([0xC3, 0x28])))]
    )
    let repository = CredentialRepository(keychain: client)

    await #expect(throws: TransientCredentialError.invalidUTF8) {
      try await repository.withCredential(
        for: profileID,
        expectedRevision: 0
      ) { credential in
        try credential.withUTF8String { _ in () }
      }
    }
  }
}

private func randomCredential() -> TransientCredential {
  var generator = SystemRandomNumberGenerator()
  let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  return TransientCredential(bytes: Data(bytes))
}

private func assertStableDeviceOnlyMatch(
  _ match: KeychainGenericPasswordMatch,
  profileID: UUID
) {
  #expect(match.itemClass == .genericPassword)
  #expect(match.service == "eu.jinx.JollysMQTT.credentials.password.v1")
  #expect(match.account == profileID.uuidString.lowercased())
  #expect(match.synchronizable == false)
}

private func assertSecurityMatch(
  _ attributes: [CFString: Any],
  profileID: UUID
) {
  #expect(attributes[kSecClass] as? String == kSecClassGenericPassword as String)
  #expect(
    attributes[kSecAttrService] as? String
      == "eu.jinx.JollysMQTT.credentials.password.v1"
  )
  #expect(
    attributes[kSecAttrAccount] as? String
      == profileID.uuidString.lowercased()
  )
  #expect(attributes[kSecAttrSynchronizable] as? Bool == false)
}

private final class RecordingKeychainClient: KeychainClient, Sendable {
  private let state: Mutex<State>

  init(
    scriptedResults: [KeychainClientResult] = [.itemNotFound, .success],
    retrievalResults: [KeychainRetrieveResult] = []
  ) {
    state = Mutex(
      State(
        scriptedResults: scriptedResults,
        retrievalResults: retrievalResults
      )
    )
  }

  func contains(_ query: KeychainContainsRequest) -> KeychainClientResult {
    record(.contains(query))
  }

  func add(_ request: KeychainAddRequest) -> KeychainClientResult {
    record(.add(request))
  }

  func update(_ request: KeychainUpdateRequest) -> KeychainClientResult {
    record(.update(request))
  }

  func delete(_ query: KeychainDeleteRequest) -> KeychainClientResult {
    record(.delete(query))
  }

  func retrieve(_ query: KeychainRetrieveRequest) -> KeychainRetrieveResult {
    state.withLock { state in
      state.operations.append(.retrieve(query))
      return state.retrievalResults.isEmpty
        ? .itemNotFound
        : state.retrievalResults.removeFirst()
    }
  }

  func operations() -> [Operation] {
    state.withLock(\.operations)
  }

  private func record(_ operation: Operation) -> KeychainClientResult {
    state.withLock { state in
      state.operations.append(operation)
      return state.scriptedResults.isEmpty
        ? .failure(-1)
        : state.scriptedResults.removeFirst()
    }
  }

  private struct State {
    var scriptedResults: [KeychainClientResult]
    var retrievalResults: [KeychainRetrieveResult]
    var operations: [Operation] = []
  }

  enum Operation: Sendable {
    case contains(KeychainContainsRequest)
    case add(KeychainAddRequest)
    case update(KeychainUpdateRequest)
    case delete(KeychainDeleteRequest)
    case retrieve(KeychainRetrieveRequest)

    var containsQuery: KeychainContainsRequest? {
      guard case .contains(let query) = self else { return nil }
      return query
    }

    var addRequest: KeychainAddRequest? {
      guard case .add(let request) = self else { return nil }
      return request
    }

    var updateRequest: KeychainUpdateRequest? {
      guard case .update(let request) = self else { return nil }
      return request
    }

    var retrieveRequest: KeychainRetrieveRequest? {
      guard case .retrieve(let request) = self else { return nil }
      return request
    }
  }
}
