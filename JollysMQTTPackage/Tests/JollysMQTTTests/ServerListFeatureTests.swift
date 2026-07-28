import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("Server-list profile workflow")
struct ServerListFeatureTests {
  @Test("Create opens an editor with safe broad-subscription defaults")
  @MainActor
  func createProfile() throws {
    var state = ServerListFeature.State()
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .createProfile(id: id)
    )

    #expect(effect == nil)
    let editor = try #require(state.editor)
    #expect(editor.id == id)
    #expect(editor.subscriptions.map(\.filter) == ["#", "$SYS/#"])
    #expect(editor.hasBroadSubscriptionWarning)
  }

  @Test("Saving a valid edit returns one persistence effect")
  @MainActor
  func saveEditedProfile() throws {
    let existing = rankedProfile(name: "Lab", rank: 10)
    var state = ServerListFeature.State(profiles: [existing])
    _ = ServerListFeature.reduce(state: &state, intent: .editProfile(existing.id))
    _ = ServerListFeature.reduce(state: &state, intent: .setName("Production Lab"))

    let effect = ServerListFeature.reduce(state: &state, intent: .saveEditor)

    #expect(state.profiles.map(\.profile.name) == ["Production Lab"])
    #expect(state.editor == nil)
    #expect(effect == .persistProfiles(state.profiles))
  }

  @Test("The observable store persists a create and restores it on relaunch")
  @MainActor
  func storePersistsCreate() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let repository = LocalProfileRepository(fileURL: fileURL)
    let id = UUID()
    let store = ServerListStore(repository: repository)
    await store.send(.createProfile(id: id))
    await store.send(.setName("Home"))
    await store.send(.setHost("home.example"))
    await store.send(.saveEditor)

    let relaunched = ServerListStore(
      repository: LocalProfileRepository(fileURL: fileURL)
    )
    await relaunched.send(.load)

    #expect(relaunched.state.profiles.map(\.profile.name) == ["Home"])
    #expect(relaunched.state.profiles.first?.id == id)
  }

  @Test("Duplicate, delete, reorder, and connect validation preserve stable identity")
  @MainActor
  func profileOperations() throws {
    let first = rankedProfile(name: "First", rank: 10)
    let second = RankedBrokerProfile(
      profile: BrokerProfile(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        name: "Second",
        host: "second.example",
        port: 1_883,
        transport: .tcp,
        username: nil,
        clientIDPolicy: .stableGenerated,
        cleanSession: true,
        keepAliveSeconds: 60,
        reconnectPolicy: .standard,
        subscriptions: [
          SubscriptionDefinition(filter: "second/#", qos: .atMostOnce)
        ]
      ),
      reorderRank: 20
    )
    var state = ServerListFeature.State(profiles: [first, second])
    let duplicateID = UUID()

    _ = ServerListFeature.reduce(
      state: &state,
      intent: .duplicateProfile(first.id, newID: duplicateID)
    )
    let duplicate = try #require(state.editor)
    #expect(duplicate.id == duplicateID)
    #expect(duplicate.subscriptions.first?.id != first.profile.subscriptions.first?.id)

    _ = ServerListFeature.reduce(state: &state, intent: .cancelEditor)
    let reorder = ServerListFeature.reduce(
      state: &state,
      intent: .moveProfile(first.id, before: nil)
    )
    #expect(state.profiles.map(\.id) == [second.id, first.id])
    #expect(reorder == .persistProfiles(state.profiles))

    _ = ServerListFeature.reduce(state: &state, intent: .requestDeleteProfile(second.id))
    let deletion = ServerListFeature.reduce(state: &state, intent: .confirmDeleteProfile)
    #expect(state.profiles.map(\.id) == [first.id])
    #expect(deletion == .persistProfiles(state.profiles))

    state.profiles = [
      RankedBrokerProfile(
        profile: .new(id: first.id),
        reorderRank: 10
      )
    ]
    let connect = ServerListFeature.reduce(state: &state, intent: .connect(first.id))
    #expect(connect == nil)
    #expect(state.editor?.validationIssues.isEmpty == false)
  }

  @Test("Loading clears a stale selection after relaunch")
  @MainActor
  func clearsStaleSelection() {
    let staleID = UUID()
    let available = rankedProfile(name: "Available", rank: 10)
    var state = ServerListFeature.State(selectedProfileID: staleID)

    ServerListFeature.reduce(
      state: &state,
      action: .loaded(.success([available]))
    )

    #expect(state.selectedProfileID == available.id)
  }

  @Test("A persistence failure remains visible and marks optimistic state undurable")
  @MainActor
  func persistenceFailureIsExplicit() async {
    let profile = rankedProfile(name: "Lab", rank: 10)
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: FailingProfileRepository()
    )

    await store.send(.deleteProfile(profile.id))

    #expect(store.state.profiles.isEmpty)
    #expect(store.state.persistenceError)
    #expect(store.state.hasUnpersistedChanges)

    await store.send(.select(nil))
    #expect(store.state.persistenceError)
    #expect(store.state.hasUnpersistedChanges)
  }

  @Test("Concurrent UI mutations cannot let an older write finish last")
  @MainActor
  func persistenceEffectsRemainOrdered() async {
    let first = rankedProfile(name: "First", rank: 10)
    let second = RankedBrokerProfile(
      profile: BrokerProfile(
        id: UUID(),
        name: "Second",
        host: "second.example",
        port: 1_883,
        transport: .tcp,
        username: nil,
        clientIDPolicy: .stableGenerated,
        cleanSession: true,
        keepAliveSeconds: 60,
        reconnectPolicy: .standard,
        subscriptions: [
          SubscriptionDefinition(filter: "second/#", qos: .atMostOnce)
        ]
      ),
      reorderRank: 20
    )
    let repository = DelayedProfileRepository()
    let store = ServerListStore(
      initialState: .init(profiles: [first, second]),
      repository: repository
    )

    let older = Task { await store.send(.moveProfile(first.id, before: nil)) }
    await repository.waitForFirstWrite()
    let newer = Task { await store.send(.moveProfile(second.id, before: nil)) }
    await older.value
    await newer.value

    let durable = await repository.persistedProfiles()
    #expect(durable.map(\.id) == store.state.profiles.map(\.id))
    #expect(!store.state.hasUnpersistedChanges)
  }

  @Test("Connect hands off only profile identity and a non-secret credential revision")
  @MainActor
  func availableCredentialBecomesConnectReady() async throws {
    let profile = rankedProfile(name: "Available", rank: 10, username: "operator")
    let credentials = ScriptedCredentialRepository(
      statuses: [
        .success(CredentialStatus(availability: .available, revision: 7))
      ]
    )
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials
    )

    await store.send(.connect(profile.id))

    #expect(
      store.state.connectReady
        == ConnectReadyState(
          profile: profile.profile,
          credentialRevision: 7,
          requestID: 1
        )
    )
    #expect(store.state.credentialPrompt == nil)
    #expect(store.state.credentialStatuses[profile.id]?.availability == .available)
  }

  @Test("A missing credential prompts, saves transiently, then becomes connect-ready")
  @MainActor
  func missingCredentialPromptFlow() async throws {
    let profile = rankedProfile(
      name: "Needs Password",
      rank: 10,
      username: "operator"
    )
    let credentials = ScriptedCredentialRepository(
      statuses: [
        .success(CredentialStatus(availability: .missing, revision: 0))
      ],
      saves: [
        .success(CredentialStatus(availability: .available, revision: 1))
      ]
    )
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials
    )

    await store.send(.connect(profile.id))
    #expect(store.state.credentialPrompt?.profileID == profile.id)
    #expect(store.state.connectReady == nil)

    await store.send(.submitCredential(randomTransientCredential()))

    #expect(
      store.state.connectReady
        == ConnectReadyState(
          profile: profile.profile,
          credentialRevision: 1,
          requestID: 1
        )
    )
    #expect(store.state.credentialPrompt == nil)
    #expect(await credentials.operations() == [.status(profile.id), .save(profile.id)])
  }

  @Test("Cancelling a prompt rejects a stale successful save without deleting the profile")
  @MainActor
  func promptCancellationRejectsStaleSave() async throws {
    let profile = rankedProfile(name: "Cancellable", rank: 10, username: "operator")
    let credentials = ControlledSaveCredentialRepository()
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials
    )
    await store.send(.connect(profile.id))

    let saving = Task {
      await store.send(.submitCredential(randomTransientCredential()))
    }
    await credentials.waitForSave()
    store.sendImmediately(.cancelCredentialPrompt)
    await credentials.completeSave(
      with: .success(CredentialStatus(availability: .available, revision: 1))
    )
    await saving.value

    #expect(store.state.credentialPrompt == nil)
    #expect(store.state.connectReady == nil)
    #expect(store.state.profiles == [profile])
  }

  @Test("Credential denial leaves the durable profile and prompt available for retry")
  @MainActor
  func credentialDenialPreservesProfile() async {
    let profile = rankedProfile(name: "Denied", rank: 10, username: "operator")
    let profileRepository = MemoryProfileRepository(profiles: [profile])
    let credentials = ScriptedCredentialRepository(
      statuses: [
        .success(CredentialStatus(availability: .missing, revision: 3))
      ],
      saves: [.failure(.denied)]
    )
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: profileRepository,
      credentialRepository: credentials
    )

    await store.send(.connect(profile.id))
    await store.send(.submitCredential(randomTransientCredential()))

    #expect(store.state.credentialError == .denied)
    #expect(store.state.credentialPrompt?.isSaving == false)
    #expect(store.state.connectReady == nil)
    #expect(store.state.profiles == [profile])
    #expect(await profileRepository.persistedProfiles() == [profile])
  }

  @Test("Profile deletion explicitly keeps or deletes the device credential")
  @MainActor
  func profileDeletionChoices() async {
    let keepProfile = rankedProfile(name: "Keep Credential", rank: 10)
    let deleteProfile = RankedBrokerProfile(
      profile: BrokerProfile(
        id: UUID(),
        name: "Delete Credential",
        host: "delete.example",
        port: 1_883,
        transport: .tcp,
        username: nil,
        clientIDPolicy: .stableGenerated,
        cleanSession: true,
        keepAliveSeconds: 60,
        reconnectPolicy: .standard,
        subscriptions: [
          SubscriptionDefinition(filter: "delete/#", qos: .atMostOnce)
        ]
      ),
      reorderRank: 20
    )
    let credentials = ScriptedCredentialRepository(
      deletes: [
        .success(CredentialStatus(availability: .missing, revision: 4))
      ]
    )
    let store = ServerListStore(
      initialState: .init(profiles: [keepProfile, deleteProfile]),
      repository: MemoryProfileRepository(profiles: [keepProfile, deleteProfile]),
      credentialRepository: credentials
    )

    store.sendImmediately(.requestDeleteProfile(keepProfile.id))
    await store.send(.confirmDeleteProfile)
    #expect(await credentials.operations().isEmpty)

    store.sendImmediately(.requestDeleteProfile(deleteProfile.id))
    await store.send(.confirmDeleteProfileAndCredential)

    #expect(store.state.profiles.isEmpty)
    #expect(await credentials.operations() == [.delete(deleteProfile.id)])
  }

  @Test("A failed credential deletion never deletes the saved profile")
  @MainActor
  func failedCredentialDeletionPreservesProfile() async {
    let profile = rankedProfile(name: "Preserved", rank: 10)
    let profileRepository = MemoryProfileRepository(profiles: [profile])
    let credentials = ScriptedCredentialRepository(deletes: [.failure(.denied)])
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: profileRepository,
      credentialRepository: credentials
    )

    store.sendImmediately(.requestDeleteProfile(profile.id))
    await store.send(.confirmDeleteProfileAndCredential)

    #expect(store.state.profiles == [profile])
    #expect(await profileRepository.persistedProfiles() == [profile])
    #expect(store.state.credentialError == .denied)
  }

  @Test("A profile without a username connects anonymously without Keychain access")
  @MainActor
  func anonymousProfileDoesNotPrompt() async {
    let profile = rankedProfile(name: "Anonymous", rank: 10)
    let credentials = ScriptedCredentialRepository()
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials
    )

    await store.send(.connect(profile.id))

    #expect(
      store.state.connectReady
        == ConnectReadyState(
          profile: profile.profile,
          credentialRevision: 0,
          requestID: 1
        )
    )
    #expect(store.state.credentialPrompt == nil)
    #expect(await credentials.operations().isEmpty)
  }

  @Test("Connect-ready handoffs are one-shot and ignore stale consumption")
  @MainActor
  func connectReadyIsOneShot() async {
    let profile = rankedProfile(name: "Anonymous", rank: 10)
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: ScriptedCredentialRepository()
    )
    await store.send(.connect(profile.id))

    store.sendImmediately(.consumeConnectReady(requestID: 0))
    #expect(store.state.connectReady?.requestID == 1)

    store.sendImmediately(.consumeConnectReady(requestID: 1))
    #expect(store.state.connectReady == nil)
  }

  @Test("Transient password bytes never enter observable State or diagnostics")
  @MainActor
  func credentialIsRedactedOutsideEffectExecution() throws {
    let profile = rankedProfile(name: "Private", rank: 10, username: "operator")
    var state = ServerListFeature.State(
      profiles: [profile],
      credentialPrompt: CredentialPromptState(
        profileID: profile.id,
        profileName: profile.profile.name,
        requestID: 42
      )
    )
    var generator = SystemRandomNumberGenerator()
    let secret = (0..<30).map { _ in
      Character(UnicodeScalar(Int.random(in: 0x21...0x7E, using: &generator))!)
    }
    let secretText = String(secret)

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .submitCredential(TransientCredential(utf8: secretText))
    )

    #expect(!String(reflecting: state).contains(secretText))
    #expect(!String(reflecting: effect).contains(secretText))
    #expect(String(reflecting: effect).contains("redacted"))
  }

  @Test("Cancellation after a committed password save cannot relabel success")
  @MainActor
  func committedSaveRemainsSuccessful() async {
    let profile = rankedProfile(name: "Committed", rank: 10, username: "operator")
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: CancellingAfterCommitCredentialRepository()
    )
    await store.send(.connect(profile.id))

    let submission = Task {
      await store.send(.submitCredential(randomTransientCredential()))
    }
    await submission.value

    #expect(store.state.connectReady?.credentialRevision == 1)
    #expect(store.state.credentialError == nil)
  }

  @Test("The public connection boundary can consume transient UTF-8 synchronously")
  func externalConnectionCredentialAccess() throws {
    var generator = SystemRandomNumberGenerator()
    let characters = (0..<32).map { _ in
      Character(UnicodeScalar(Int.random(in: 0x21...0x7E, using: &generator))!)
    }
    let expected = String(characters)
    let credential = TransientCredential(utf8: expected)

    let matches = try credential.withUTF8String { value in
      value == expected
    }

    #expect(matches)
    #expect(!String(reflecting: credential).contains(expected))
  }

  @Test("An external connection consumer resolves and converts without retaining a password")
  func externalResolverBuildsAuthentication() async throws {
    var generator = SystemRandomNumberGenerator()
    let characters = (0..<32).map { _ in
      Character(UnicodeScalar(Int.random(in: 0x21...0x7E, using: &generator))!)
    }
    let password = String(characters)
    let profileID = UUID()
    let resolver = ExternalCredentialResolver(
      profileID: profileID,
      revision: 9,
      credential: TransientCredential(utf8: password)
    )

    let authentication = try await buildMockAuthentication(
      resolver: resolver,
      profileID: profileID,
      revision: 9
    )

    #expect(authentication == MockAuthentication(hasPassword: true))
    #expect(!String(reflecting: authentication).contains(password))
  }
}

private struct FailingProfileRepository: ProfileRepositoryProtocol {
  func load() async throws -> [RankedBrokerProfile] { [] }
  func replaceAll(_ profiles: [RankedBrokerProfile]) async throws {
    throw ProfileRepositoryFailure()
  }
}

private actor DelayedProfileRepository: ProfileRepositoryProtocol {
  private var didStartFirstWrite = false
  private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
  private var profiles: [RankedBrokerProfile] = []
  private var callCount = 0

  func load() -> [RankedBrokerProfile] { profiles }

  func replaceAll(_ profiles: [RankedBrokerProfile]) async {
    callCount += 1
    if callCount == 1 {
      didStartFirstWrite = true
      let waiters = firstWriteWaiters
      firstWriteWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      try? await Task.sleep(for: .milliseconds(75))
    }
    self.profiles = profiles
  }

  func waitForFirstWrite() async {
    if didStartFirstWrite { return }
    await withCheckedContinuation { continuation in
      firstWriteWaiters.append(continuation)
    }
  }

  func persistedProfiles() -> [RankedBrokerProfile] { profiles }
}

private actor MemoryProfileRepository: ProfileRepositoryProtocol {
  private var profiles: [RankedBrokerProfile]

  init(profiles: [RankedBrokerProfile]) {
    self.profiles = profiles
  }

  func load() -> [RankedBrokerProfile] { profiles }
  func replaceAll(_ profiles: [RankedBrokerProfile]) {
    self.profiles = profiles
  }
  func persistedProfiles() -> [RankedBrokerProfile] { profiles }
}

private actor ScriptedCredentialRepository: CredentialRepositoryProtocol {
  enum Operation: Equatable, Sendable {
    case status(UUID)
    case save(UUID)
    case delete(UUID)
  }

  private var statuses: [Result<CredentialStatus, CredentialRepositoryError>]
  private var saves: [Result<CredentialStatus, CredentialRepositoryError>]
  private var deletes: [Result<CredentialStatus, CredentialRepositoryError>]
  private var recorded: [Operation] = []

  init(
    statuses: [Result<CredentialStatus, CredentialRepositoryError>] = [],
    saves: [Result<CredentialStatus, CredentialRepositoryError>] = [],
    deletes: [Result<CredentialStatus, CredentialRepositoryError>] = []
  ) {
    self.statuses = statuses
    self.saves = saves
    self.deletes = deletes
  }

  func status(for profileID: UUID) throws -> CredentialStatus {
    recorded.append(.status(profileID))
    return try statuses.removeFirst().get()
  }

  func save(
    _ credential: TransientCredential,
    for profileID: UUID
  ) throws -> CredentialStatus {
    recorded.append(.save(profileID))
    return try saves.removeFirst().get()
  }

  func delete(for profileID: UUID) throws -> CredentialStatus {
    recorded.append(.delete(profileID))
    return try deletes.removeFirst().get()
  }

  func operations() -> [Operation] { recorded }
}

private actor ControlledSaveCredentialRepository: CredentialRepositoryProtocol {
  private var didStartSave = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveContinuation: CheckedContinuation<CredentialStatus, any Error>?

  func status(for profileID: UUID) -> CredentialStatus {
    CredentialStatus(availability: .missing, revision: 0)
  }

  func save(
    _ credential: TransientCredential,
    for profileID: UUID
  ) async throws -> CredentialStatus {
    didStartSave = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    return try await withCheckedThrowingContinuation { continuation in
      saveContinuation = continuation
    }
  }

  func delete(for profileID: UUID) -> CredentialStatus {
    CredentialStatus(availability: .missing, revision: 0)
  }

  func waitForSave() async {
    if didStartSave { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func completeSave(
    with result: Result<CredentialStatus, CredentialRepositoryError>
  ) {
    saveContinuation?.resume(with: result.mapError { $0 as any Error })
    saveContinuation = nil
  }
}

private actor CancellingAfterCommitCredentialRepository:
  CredentialRepositoryProtocol
{
  func status(for profileID: UUID) -> CredentialStatus {
    CredentialStatus(availability: .missing, revision: 0)
  }

  func save(
    _ credential: TransientCredential,
    for profileID: UUID
  ) -> CredentialStatus {
    withUnsafeCurrentTask { task in
      task?.cancel()
    }
    return CredentialStatus(availability: .available, revision: 1)
  }

  func delete(for profileID: UUID) -> CredentialStatus {
    CredentialStatus(availability: .missing, revision: 0)
  }
}

private struct MockAuthentication: Equatable, Sendable {
  let hasPassword: Bool
}

private struct ExternalCredentialResolver: ConnectionCredentialResolving {
  let profileID: UUID
  let revision: UInt64
  let credential: TransientCredential

  func withCredential<Result: Sendable>(
    for profileID: UUID,
    expectedRevision: UInt64,
    operation: @Sendable (TransientCredential) async throws -> Result
  ) async throws -> Result {
    guard self.profileID == profileID, revision == expectedRevision else {
      throw CredentialRepositoryError.staleRevision(
        expected: expectedRevision,
        actual: revision
      )
    }
    return try await operation(credential)
  }
}

private func buildMockAuthentication<Resolver: ConnectionCredentialResolving>(
  resolver: Resolver,
  profileID: UUID,
  revision: UInt64
) async throws -> MockAuthentication {
  try await resolver.withCredential(
    for: profileID,
    expectedRevision: revision
  ) { credential in
    try credential.withUTF8String { password in
      MockAuthentication(hasPassword: !password.isEmpty)
    }
  }
}

private func rankedProfile(
  name: String,
  rank: Int64,
  username: String? = nil
) -> RankedBrokerProfile {
  RankedBrokerProfile(
    profile: BrokerProfile(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      name: name,
      host: "broker.example",
      port: 1_883,
      transport: .tcp,
      username: username,
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [
        SubscriptionDefinition(filter: "site/#", qos: .atMostOnce)
      ]
    ),
    reorderRank: rank
  )
}

private func randomTransientCredential() -> TransientCredential {
  var generator = SystemRandomNumberGenerator()
  let scalarCount = Int.random(in: 24...32, using: &generator)
  let scalars = (0..<scalarCount).map { _ in
    UnicodeScalar(Int.random(in: 0x21...0x7E, using: &generator))!
  }
  return TransientCredential(utf8: String(String.UnicodeScalarView(scalars)))
}
