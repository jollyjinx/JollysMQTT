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

  @Test("Regular selection keeps its editor open after saving")
  @MainActor
  func inlineSaveKeepsEditorOpen() throws {
    let existing = rankedProfile(name: "Lab", rank: 10)
    var state = ServerListFeature.State(
      profiles: [existing],
      selectedProfileID: existing.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfileInline(existing.id)
    )
    _ = ServerListFeature.reduce(state: &state, intent: .setHost("new.example"))

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .saveEditorKeepingOpen
    )

    #expect(state.profiles.first?.profile.host == "new.example")
    let editor = try #require(state.editor)
    #expect(editor.presentation == .inline)
    #expect(editor.mode == .edit)
    #expect(!state.editorHasUnsavedChanges)
    #expect(effect == .persistProfiles(state.profiles))
  }

  @Test("Changing editor presentation preserves an unsaved draft")
  @MainActor
  func editorPresentationTransitionPreservesDraft() throws {
    let existing = rankedProfile(name: "Lab", rank: 10)
    var state = ServerListFeature.State(
      profiles: [existing],
      selectedProfileID: existing.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfileInline(existing.id)
    )
    _ = ServerListFeature.reduce(state: &state, intent: .setName("Draft"))

    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfile(existing.id)
    )

    let editor = try #require(state.editor)
    #expect(editor.presentation == .modal)
    #expect(editor.name == "Draft")
    #expect(state.editorHasUnsavedChanges)
  }

  @Test("Cancelling inline creation restores the selected profile editor")
  @MainActor
  func cancelInlineCreationRestoresSelection() throws {
    let existing = rankedProfile(name: "Lab", rank: 10)
    var state = ServerListFeature.State(
      profiles: [existing],
      selectedProfileID: existing.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .createProfileInline(id: UUID())
    )

    _ = ServerListFeature.reduce(state: &state, intent: .cancelEditor)

    let editor = try #require(state.editor)
    #expect(editor.id == existing.id)
    #expect(editor.mode == .edit)
    #expect(editor.presentation == .inline)
    #expect(!state.editorHasUnsavedChanges)
  }

  @Test("Changing selection never silently discards an inline draft")
  @MainActor
  func selectionRequiresDraftDecision() throws {
    let first = uniqueRankedProfile(name: "First", rank: 10)
    let second = uniqueRankedProfile(name: "Second", rank: 20)
    var state = ServerListFeature.State(
      profiles: [first, second],
      selectedProfileID: first.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfileInline(first.id)
    )
    _ = ServerListFeature.reduce(state: &state, intent: .setName("Draft"))

    _ = ServerListFeature.reduce(state: &state, intent: .select(second.id))

    #expect(state.selectedProfileID == first.id)
    #expect(state.editor?.name == "Draft")
    #expect(state.pendingDraftDestination == .selection(second.id))

    _ = ServerListFeature.reduce(state: &state, intent: .continueEditingDraft)
    #expect(state.selectedProfileID == first.id)
    #expect(state.editor?.name == "Draft")
    #expect(state.pendingDraftDestination == nil)

    _ = ServerListFeature.reduce(state: &state, intent: .select(second.id))
    _ = ServerListFeature.reduce(state: &state, intent: .discardPendingDraft)
    #expect(state.selectedProfileID == second.id)
    #expect(state.editor == nil)
    #expect(state.profiles.first?.profile.name == "First")
  }

  @Test("Saving before a selection change preserves the draft durably")
  @MainActor
  func saveDraftBeforeSelectionChange() {
    let first = uniqueRankedProfile(name: "First", rank: 10)
    let second = uniqueRankedProfile(name: "Second", rank: 20)
    var state = ServerListFeature.State(
      profiles: [first, second],
      selectedProfileID: first.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfileInline(first.id)
    )
    _ = ServerListFeature.reduce(state: &state, intent: .setName("Saved"))
    _ = ServerListFeature.reduce(state: &state, intent: .select(second.id))

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .savePendingDraft
    )

    #expect(state.profiles.first?.profile.name == "Saved")
    #expect(state.selectedProfileID == second.id)
    #expect(state.editor == nil)
    #expect(effect == .persistProfiles(state.profiles))
  }

  @Test("A changed draft must be saved or discarded before connecting")
  @MainActor
  func connectRequiresSavedDraft() {
    let profile = rankedProfile(name: "Lab", rank: 10)
    var state = ServerListFeature.State(
      profiles: [profile],
      selectedProfileID: profile.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfileInline(profile.id)
    )
    _ = ServerListFeature.reduce(state: &state, intent: .setHost("changed.example"))

    let blocked = ServerListFeature.reduce(
      state: &state,
      intent: .connect(profile.id)
    )

    #expect(blocked == nil)
    #expect(state.connectReady == nil)
    #expect(state.profiles.first?.profile.host != "changed.example")
    #expect(state.pendingDraftDestination == .connection(profile.id))

    let saveAndConnect = ServerListFeature.reduce(
      state: &state,
      intent: .savePendingDraft
    )
    #expect(
      saveAndConnect
        == .persistProfilesAndConnect(
          state.profiles,
          state.profiles[0].profile
        )
    )
  }

  @Test("Save and Connect persists before handing the edited generation to the workspace")
  @MainActor
  func saveAndConnectOrdersPersistenceBeforeHandoff() async {
    let profile = rankedProfile(name: "Connected Elsewhere", rank: 10)
    let coordinator = RecordingFeedGenerationCoordinator()
    let store = ServerListStore(
      initialState: .init(
        profiles: [profile],
        selectedProfileID: profile.id
      ),
      repository: MemoryProfileRepository(profiles: [profile]),
      brokerFeedGenerationCoordinator: coordinator
    )
    await store.send(.editProfileInline(profile.id))
    await store.send(.setHost("next-generation.example"))
    await store.send(.connect(profile.id))

    #expect(store.state.connectReady == nil)
    #expect(store.state.pendingDraftDestination == .connection(profile.id))

    await store.send(.savePendingDraft)

    #expect(
      await coordinator.latestProfile(profileID: profile.id)?.host
        == "next-generation.example"
    )
    #expect(
      store.state.connectReady?.profile.host
        == "next-generation.example"
    )
    #expect(!store.state.hasUnpersistedChanges)
  }

  @Test("An invalid draft cannot replace storage or begin connecting")
  @MainActor
  func invalidDraftCannotConnect() throws {
    let profile = rankedProfile(name: "Lab", rank: 10)
    var state = ServerListFeature.State(
      profiles: [profile],
      selectedProfileID: profile.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfileInline(profile.id)
    )
    _ = ServerListFeature.reduce(state: &state, intent: .setHost(""))
    _ = ServerListFeature.reduce(state: &state, intent: .connect(profile.id))

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .savePendingDraft
    )

    #expect(effect == nil)
    #expect(state.profiles == [profile])
    #expect(state.connectReady == nil)
    #expect(state.pendingDraftDestination == nil)
    #expect(try #require(state.editor).validationIssues.isEmpty == false)
  }

  @Test("An unchanged valid selected profile connects directly")
  @MainActor
  func unchangedProfileConnectsDirectly() {
    let profile = rankedProfile(name: "Lab", rank: 10)
    var state = ServerListFeature.State(
      profiles: [profile],
      selectedProfileID: profile.id
    )
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .editProfileInline(profile.id)
    )

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .connect(profile.id)
    )

    #expect(effect == nil)
    #expect(state.pendingDraftDestination == nil)
    #expect(state.connectReady?.profile == profile.profile)
  }

  @Test("Selecting a broker row never begins a connection")
  @MainActor
  func rowSelectionDoesNotConnect() {
    let first = uniqueRankedProfile(name: "First", rank: 10)
    let second = uniqueRankedProfile(name: "Second", rank: 20)
    var state = ServerListFeature.State(
      profiles: [first, second],
      selectedProfileID: first.id
    )

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .select(second.id)
    )

    #expect(effect == nil)
    #expect(state.selectedProfileID == second.id)
    #expect(!state.isConnectionRequestPending)
    #expect(state.connectReady == nil)
  }

  @Test("Broker activation connects the exact available valid profile")
  @MainActor
  func rowActivationConnectsExactProfile() {
    let first = uniqueRankedProfile(name: "First", rank: 10)
    let second = uniqueRankedProfile(name: "Second", rank: 20)
    var state = ServerListFeature.State(
      profiles: [first, second],
      selectedProfileID: first.id
    )

    let effect = ServerListFeature.reduce(
      state: &state,
      intent: .connect(second.id)
    )

    #expect(effect == nil)
    #expect(state.connectReady?.profile == second.profile)
    #expect(state.connectReady?.requestID == 1)
  }

  @Test("Unavailable and invalid broker rows cannot begin a connection")
  @MainActor
  func unavailableAndInvalidRowsDoNotConnect() throws {
    let invalid = RankedBrokerProfile(
      profile: .new(name: "Invalid", host: ""),
      reorderRank: 10
    )
    var state = ServerListFeature.State(profiles: [invalid])

    _ = ServerListFeature.reduce(
      state: &state,
      intent: .connect(UUID())
    )
    #expect(!state.isConnectionRequestPending)
    #expect(state.editor == nil)

    _ = ServerListFeature.reduce(
      state: &state,
      intent: .connect(invalid.id)
    )
    #expect(!state.isConnectionRequestPending)
    #expect(state.connectReady == nil)
    #expect(try #require(state.editor).validationIssues.isEmpty == false)
  }

  @Test("Repeated broker activation cannot replace an in-flight connection request")
  @MainActor
  func duplicateRowActivationIsSuppressed() throws {
    let profile = rankedProfile(
      name: "Credentialed",
      rank: 10,
      username: "operator"
    )
    var state = ServerListFeature.State(profiles: [profile])

    let first = try #require(
      ServerListFeature.reduce(
        state: &state,
        intent: .connect(profile.id)
      )
    )
    let request = try #require(state.pendingConnectRequest)
    let duplicate = ServerListFeature.reduce(
      state: &state,
      intent: .connect(profile.id)
    )

    #expect(
      first
        == .checkCredential(
          profile.profile,
          requestID: request.requestID
        )
    )
    #expect(duplicate == nil)
    #expect(state.pendingConnectRequest == request)
    #expect(state.isConnectionRequestPending)
  }

  @Test("The observable store persists a create and restores it on relaunch")
  @MainActor
  func storePersistsCreate() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let repository = LocalProfileRepository(
      fileURL: fileURL,
      installationID: serverListTestInstallationID
    )
    let id = UUID()
    let store = ServerListStore(repository: repository)
    await store.send(.createProfile(id: id))
    await store.send(.setName("Home"))
    await store.send(.setHost("home.example"))
    await store.send(.saveEditor)

    let relaunched = ServerListStore(
      repository: LocalProfileRepository(
        fileURL: fileURL,
        installationID: serverListTestInstallationID
      )
    )
    await relaunched.send(.load)

    #expect(relaunched.state.profiles.map(\.profile.name) == ["Home"])
    #expect(relaunched.state.profiles.first?.id == id)
  }

  @Test("Durable profile and credential changes notify the feed registry")
  @MainActor
  func durableChangesNotifyFeedCoordinator() async throws {
    let profile = rankedProfile(
      name: "Connected",
      rank: 10,
      username: "operator"
    )
    let coordinator = RecordingFeedGenerationCoordinator()
    let credentials = ScriptedCredentialRepository(
      statuses: [
        .success(CredentialStatus(availability: .missing, revision: 2))
      ],
      saves: [
        .success(CredentialStatus(availability: .available, revision: 3))
      ]
    )
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials,
      brokerFeedGenerationCoordinator: coordinator
    )

    await store.send(.editProfile(profile.id))
    await store.send(.setHost("new.example"))
    await store.send(.saveEditor)
    await store.send(.connect(profile.id))
    await store.send(.submitCredential(randomTransientCredential()))

    #expect(
      await coordinator.latestProfile(profileID: profile.id)?.host
        == "new.example"
    )
    #expect(await coordinator.latestCredentialRevision(profile.id) == 3)
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
    #expect(state.profiles.map(\.id) == [second.id, first.id])
    #expect(
      deletion
        == .deleteProfileResources(
          profileID: second.id,
          requestID: 1,
          options: BrokerDeletionOptions(
            deleteHistory: false,
            deleteCredential: false
          ),
          profiles: [
            RankedBrokerProfile(
              profile: first.profile,
              reorderRank: 1_024
            )
          ]
        )
    )

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

  @Test("Profile writes and feed notifications remain in one durable order")
  @MainActor
  func persistenceNotificationsRemainOrdered() async {
    let profile = rankedProfile(name: "Connected", rank: 10)
    let repository = CountingProfileRepository(profiles: [profile])
    let coordinator = GatedFeedGenerationCoordinator()
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: repository,
      brokerFeedGenerationCoordinator: coordinator
    )

    await store.send(.editProfile(profile.id))
    await store.send(.setHost("edit-one.example"))
    let first = Task { await store.send(.saveEditor) }
    await coordinator.waitForFirstNotification()

    await store.send(.editProfile(profile.id))
    await store.send(.setHost("edit-two.example"))
    let second = Task { await store.send(.saveEditor) }
    for _ in 0..<100 {
      await Task.yield()
    }

    #expect(await repository.writeCount() == 1)
    #expect(await coordinator.notificationCount() == 1)

    await coordinator.finishFirstNotification()
    await first.value
    await second.value

    #expect(await repository.writeCount() == 2)
    #expect(await coordinator.notificationCount() == 2)
    #expect(
      await coordinator.latestProfile(profileID: profile.id)?.host
        == "edit-two.example"
    )
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

  @Test("A remotely synced profile connects after one device-local credential entry")
  @MainActor
  func remotelySyncedProfileNeedsOneLocalCredential() async throws {
    let remoteProfile = rankedProfile(
      name: "Synced Broker",
      rank: 1_024,
      username: "operator"
    )
    let sync = OneShotRemoteProfileSync(
      profiles: [remoteProfile]
    )
    let repository = LocalFirstProfileRepository(
      local: MemoryProfileRepository(profiles: []),
      sync: sync
    )
    #expect(
      try await repository.synchronize() == .available
    )
    let credentials = ScriptedCredentialRepository(
      statuses: [
        .success(
          CredentialStatus(
            availability: .missing,
            revision: 0
          )
        )
      ],
      saves: [
        .success(
          CredentialStatus(
            availability: .available,
            revision: 1
          )
        )
      ]
    )
    let store = ServerListStore(
      repository: repository,
      credentialRepository: credentials
    )

    await store.send(.load)
    #expect(store.state.profiles == [remoteProfile])

    await store.send(.connect(remoteProfile.id))
    #expect(
      store.state.credentialPrompt?.profileID
        == remoteProfile.id
    )
    #expect(store.state.connectReady == nil)

    await store.send(
      .submitCredential(randomTransientCredential())
    )

    #expect(
      store.state.connectReady
        == ConnectReadyState(
          profile: remoteProfile.profile,
          credentialRevision: 1,
          requestID: 1
        )
    )
    #expect(
      await credentials.operations()
        == [
          .status(remoteProfile.id),
          .save(remoteProfile.id),
        ]
    )
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

  @Test("History and credential deletion choices are independent and settings always leave")
  @MainActor
  func fourWayProfileDeletion() async throws {
    let profiles = (0..<4).map {
      uniqueRankedProfile(name: "Broker \($0)", rank: Int64($0 + 1))
    }
    let credentials = ScriptedCredentialRepository(
      deletes: [
        .success(CredentialStatus(availability: .missing, revision: 1)),
        .success(CredentialStatus(availability: .missing, revision: 1)),
      ]
    )
    let historyRecorder = DeletionHistoryRecorder()
    let settings = MemoryHistoryRetentionSettingsRepository()
    let customPolicy = try HistoryRetentionPolicy(
      topicMessageLimit: 42,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    for profile in profiles {
      settings.save(customPolicy, for: profile.id)
    }
    let store = ServerListStore(
      initialState: .init(profiles: profiles),
      repository: MemoryProfileRepository(profiles: profiles),
      credentialRepository: credentials,
      historyMaintenanceProvider: BrokerHistoryMaintenanceProvider {
        brokerID in
        RecordingDeletionHistoryMaintenance(
          brokerID: brokerID,
          recorder: historyRecorder
        )
      },
      historyRetentionSettings: settings
    )

    store.sendImmediately(.requestDeleteProfile(profiles[0].id))
    await store.send(.confirmDeleteProfile)
    store.sendImmediately(.requestDeleteProfile(profiles[1].id))
    await store.send(.confirmDeleteProfileAndHistory)
    store.sendImmediately(.requestDeleteProfile(profiles[2].id))
    await store.send(.confirmDeleteProfileAndCredential)
    store.sendImmediately(.requestDeleteProfile(profiles[3].id))
    await store.send(.confirmDeleteProfileAndHistoryAndCredential)

    #expect(store.state.profiles.isEmpty)
    #expect(
      await historyRecorder.brokerIDs
        == [profiles[1].id, profiles[3].id]
    )
    #expect(
      await credentials.operations()
        == [.delete(profiles[2].id), .delete(profiles[3].id)]
    )
    for profile in profiles {
      #expect(settings.policy(for: profile.id) == .default)
    }
  }

  @Test("A relaunched store resumes crash-interrupted optional cleanup")
  @MainActor
  func resumesDurableDeletionCleanupAfterRelaunch() async {
    let profileID = UUID()
    let credentials = ScriptedCredentialRepository(
      deletes: [
        .success(CredentialStatus(availability: .missing, revision: 1))
      ]
    )
    let historyRecorder = DeletionHistoryRecorder()
    let journal = MemoryBrokerDeletionCleanupJournal(
      entries: [
        BrokerDeletionCleanupEntry(
          profileID: profileID,
          options: BrokerDeletionOptions(
            deleteHistory: true,
            deleteCredential: true
          )
        )
      ]
    )
    let store = ServerListStore(
      repository: MemoryProfileRepository(profiles: []),
      credentialRepository: credentials,
      historyMaintenanceProvider: BrokerHistoryMaintenanceProvider {
        brokerID in
        RecordingDeletionHistoryMaintenance(
          brokerID: brokerID,
          recorder: historyRecorder
        )
      },
      deletionCleanupJournal: journal
    )

    await store.send(.load)

    #expect(await historyRecorder.brokerIDs == [profileID])
    #expect(await credentials.operations() == [.delete(profileID)])
    #expect(await journal.pendingEntries().isEmpty)
    #expect(store.state.deletionOutcome?.succeeded == true)
  }

  @Test("Local deletion journal persists only cleanup identity and choices")
  func localDeletionCleanupJournalRoundTripIsMinimal() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "cleanup.json")
    let profileID = UUID()
    let entry = BrokerDeletionCleanupEntry(
      profileID: profileID,
      options: BrokerDeletionOptions(
        deleteHistory: true,
        deleteCredential: false
      )
    )
    let journal = LocalBrokerDeletionCleanupJournal(fileURL: fileURL)

    try await journal.save(entry)

    #expect(try await journal.pendingEntries() == [entry])
    let document = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(document.contains(profileID.uuidString))
    #expect(document.contains("deleteHistory"))
    #expect(document.contains("deleteCredential"))
    #expect(!document.contains("host"))
    #expect(!document.contains("username"))
    #expect(!document.contains("topic"))
    #expect(!document.contains("payload"))
    #expect(!document.contains("password"))

    try await journal.remove(profileID: profileID)

    #expect(try await journal.pendingEntries().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test("A journal entry cannot delete resources while its profile still exists")
  @MainActor
  func liveProfileMakesDeletionJournalEntryStale() async throws {
    let profile = uniqueRankedProfile(name: "Still Present", rank: 1)
    let credentials = ScriptedCredentialRepository(
      deletes: [
        .success(CredentialStatus(availability: .missing, revision: 1))
      ]
    )
    let historyRecorder = DeletionHistoryRecorder()
    let journal = MemoryBrokerDeletionCleanupJournal(
      entries: [
        BrokerDeletionCleanupEntry(
          profileID: profile.id,
          options: BrokerDeletionOptions(
            deleteHistory: true,
            deleteCredential: true
          )
        )
      ]
    )
    let store = ServerListStore(
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials,
      historyMaintenanceProvider: BrokerHistoryMaintenanceProvider {
        brokerID in
        RecordingDeletionHistoryMaintenance(
          brokerID: brokerID,
          recorder: historyRecorder
        )
      },
      deletionCleanupJournal: journal
    )

    await store.send(.load)

    #expect(store.state.profiles == [profile])
    #expect(await historyRecorder.brokerIDs.isEmpty)
    #expect(await credentials.operations().isEmpty)
    #expect(await journal.pendingEntries().isEmpty)
    #expect(store.state.deletionOutcome == nil)
  }

  @Test("A second deletion cannot replace an active deletion request")
  func overlappingDeletionConfirmationIsRejected() throws {
    let first = uniqueRankedProfile(name: "First", rank: 1)
    let second = uniqueRankedProfile(name: "Second", rank: 2)
    var state = ServerListFeature.State(
      profiles: [first, second],
      selectedProfileID: first.id
    )

    _ = ServerListFeature.reduce(
      state: &state,
      intent: .requestDeleteProfile(first.id)
    )
    let firstEffect = try #require(
      ServerListFeature.reduce(
        state: &state,
        intent: .confirmDeleteProfile
      )
    )
    let firstRequest = try #require(state.pendingProfileDeletionRequest)

    #expect(state.isProfileDeletionBusy)
    #expect(state.isProfileMutationBlocked)
    _ = ServerListFeature.reduce(
      state: &state,
      intent: .requestDeleteProfile(second.id)
    )
    let secondEffect = ServerListFeature.reduce(
      state: &state,
      intent: .confirmDeleteProfileAndHistory
    )

    #expect(state.pendingDeletionProfileID == nil)
    #expect(state.pendingProfileDeletionRequest == firstRequest)
    #expect(secondEffect == nil)
    guard case .deleteProfileResources(let profileID, _, _, _) = firstEffect
    else {
      Issue.record("Expected the first profile-resource deletion effect.")
      return
    }
    #expect(profileID == first.id)
  }

  @Test("Profile deletion waits for prior persistence and blocks later mutation")
  @MainActor
  func deletionSerializesProfileWrites() async throws {
    let first = uniqueRankedProfile(name: "First", rank: 1)
    let second = uniqueRankedProfile(name: "Second", rank: 2)
    let repository = OrderedGatedProfileRepository(
      profiles: [first, second],
      heldWriteNumbers: [1, 2]
    )
    let store = ServerListStore(
      initialState: .init(
        profiles: [first, second],
        selectedProfileID: second.id
      ),
      repository: repository
    )

    let priorMutation = Task {
      await store.send(.moveProfile(second.id, before: first.id))
    }
    await repository.waitForWrite(1)
    #expect(store.state.profiles.map(\.id) == [second.id, first.id])

    store.sendImmediately(.requestDeleteProfile(second.id))
    let deletion = Task {
      await store.send(.confirmDeleteProfile)
    }
    while !store.state.isProfileDeletionCommitPending {
      await Task.yield()
    }

    await store.send(.moveProfile(first.id, before: second.id))
    store.sendImmediately(.requestDeleteProfile(first.id))
    await store.send(.confirmDeleteProfileAndHistory)

    #expect(store.state.profiles.map(\.id) == [second.id, first.id])
    #expect(store.state.pendingDeletionProfileID == nil)
    #expect(await repository.writeCount == 1)

    await repository.releaseWrite(1)
    await repository.waitForWrite(2)
    #expect(await repository.write(2).map(\.id) == [first.id])

    await repository.releaseWrite(2)
    await priorMutation.value
    await deletion.value

    #expect(store.state.profiles.map(\.id) == [first.id])
    #expect(await repository.persistedProfiles.map(\.id) == [first.id])
  }

  @Test("Partial history cleanup is explicit and other selected cleanup still runs")
  @MainActor
  func partialHistoryDeletionStopsProfileDeletion() async {
    let profile = uniqueRankedProfile(name: "Partial", rank: 1)
    let credentials = ScriptedCredentialRepository(
      deletes: [
        .success(CredentialStatus(availability: .missing, revision: 1))
      ]
    )
    let settings = MemoryHistoryRetentionSettingsRepository()
    let resumeRecorder = DeletionResumeRecorder()
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials,
      historyMaintenanceProvider: BrokerHistoryMaintenanceProvider { _ in
        PartialDeletionHistoryMaintenance(recorder: resumeRecorder)
      },
      historyRetentionSettings: settings
    )

    store.sendImmediately(.requestDeleteProfile(profile.id))
    await store.send(.confirmDeleteProfileAndHistoryAndCredential)

    #expect(store.state.profiles.isEmpty)
    #expect(store.state.deletionOutcome?.history == .partiallyRemoved)
    #expect(store.state.deletionOutcome?.failure == .history)
    #expect(await credentials.operations() == [.delete(profile.id)])
    #expect(settings.policy(for: profile.id) == .default)

    await store.send(.retryDeletionCleanup)
    #expect(store.state.deletionOutcome?.succeeded == true)
    #expect(await resumeRecorder.resumeCount == 1)
  }

  @Test("Independent history and credential failures are both retained")
  @MainActor
  func simultaneousPostProfileCleanupFailures() async {
    let profile = uniqueRankedProfile(name: "Two Failures", rank: 1)
    let credentials = ScriptedCredentialRepository(
      deletes: [.failure(.denied)]
    )
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: credentials,
      historyMaintenanceProvider: BrokerHistoryMaintenanceProvider { _ in
        FailingDeletionHistoryMaintenance()
      }
    )

    store.sendImmediately(.requestDeleteProfile(profile.id))
    await store.send(.confirmDeleteProfileAndHistoryAndCredential)

    #expect(store.state.profiles.isEmpty)
    #expect(store.state.deletionOutcome?.history == .failed)
    #expect(store.state.deletionOutcome?.credential == .failed)
    #expect(store.state.deletionOutcome?.retentionSettings == .removed)
    #expect(
      store.state.deletionOutcome?.failures == [.history, .credential]
    )
  }

  @Test("Pending secure history cleanup remains retryable after deletion")
  @MainActor
  func retryPendingSecureHistoryCleanup() async {
    let profile = uniqueRankedProfile(name: "Secure Cleanup", rank: 1)
    let recorder = SecureCleanupRetryRecorder()
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: MemoryProfileRepository(profiles: [profile]),
      credentialRepository: ScriptedCredentialRepository(),
      historyMaintenanceProvider: BrokerHistoryMaintenanceProvider { _ in
        PendingSecureCleanupHistoryMaintenance(recorder: recorder)
      }
    )

    store.sendImmediately(.requestDeleteProfile(profile.id))
    await store.send(.confirmDeleteProfileAndHistory)

    #expect(store.state.profiles.isEmpty)
    #expect(store.state.deletionOutcome?.history == .removed)
    #expect(store.state.deletionOutcome?.secureHistoryCleanupPending == true)
    #expect(store.state.deletionOutcome?.needsRetry == true)

    await store.send(.retryDeletionCleanup)

    #expect(store.state.deletionOutcome?.succeeded == true)
    #expect(await recorder.retryCount == 1)
  }

  @Test("A post-profile credential failure is reported as partial cleanup")
  @MainActor
  func failedCredentialDeletionPreservesProfile() async {
    let profile = rankedProfile(name: "Preserved", rank: 10)
    let profileRepository = MemoryProfileRepository(profiles: [profile])
    let credentials = ScriptedCredentialRepository(
      deletes: [
        .failure(.denied),
        .success(CredentialStatus(availability: .missing, revision: 2)),
      ]
    )
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: profileRepository,
      credentialRepository: credentials
    )

    store.sendImmediately(.requestDeleteProfile(profile.id))
    await store.send(.confirmDeleteProfileAndCredential)

    #expect(store.state.profiles.isEmpty)
    #expect(await profileRepository.persistedProfiles().isEmpty)
    #expect(store.state.deletionOutcome?.failure == .credential)
    #expect(store.state.deletionOutcome?.credential == .failed)

    await store.send(.retryDeletionCleanup)
    #expect(store.state.deletionOutcome?.succeeded == true)
    #expect(
      await credentials.operations()
        == [.delete(profile.id), .delete(profile.id)]
    )
  }

  @Test("Profile persistence failure leaves optional resources untouched")
  @MainActor
  func profileFailurePrecedesIrreversibleCleanup() async throws {
    let profile = uniqueRankedProfile(name: "Safe Failure", rank: 1)
    let credentials = ScriptedCredentialRepository(
      deletes: [
        .success(CredentialStatus(availability: .missing, revision: 1))
      ]
    )
    let historyRecorder = DeletionHistoryRecorder()
    let settings = MemoryHistoryRetentionSettingsRepository()
    let customPolicy = try HistoryRetentionPolicy(
      topicMessageLimit: 42,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    settings.save(customPolicy, for: profile.id)
    let store = ServerListStore(
      initialState: .init(profiles: [profile]),
      repository: FailingProfileRepository(),
      credentialRepository: credentials,
      historyMaintenanceProvider: BrokerHistoryMaintenanceProvider {
        brokerID in
        RecordingDeletionHistoryMaintenance(
          brokerID: brokerID,
          recorder: historyRecorder
        )
      },
      historyRetentionSettings: settings
    )

    store.sendImmediately(.requestDeleteProfile(profile.id))
    await store.send(.confirmDeleteProfileAndHistoryAndCredential)

    #expect(store.state.profiles == [profile])
    #expect(store.state.deletionOutcome?.failure == .profile)
    #expect(await historyRecorder.brokerIDs.isEmpty)
    #expect(await credentials.operations().isEmpty)
    #expect(settings.policy(for: profile.id) == customPolicy)
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

private let serverListTestInstallationID = UUID(
  uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
)

private struct FailingProfileRepository: ProfileRepositoryProtocol {
  func load() async throws -> [RankedBrokerProfile] { [] }
  func replaceAll(_ profiles: [RankedBrokerProfile]) async throws {
    throw ProfileRepositoryFailure()
  }
}

private actor OrderedGatedProfileRepository: ProfileRepositoryProtocol {
  private var profiles: [RankedBrokerProfile]
  private let heldWriteNumbers: Set<Int>
  private var writes: [[RankedBrokerProfile]] = []
  private var writeWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

  init(
    profiles: [RankedBrokerProfile],
    heldWriteNumbers: Set<Int>
  ) {
    self.profiles = profiles
    self.heldWriteNumbers = heldWriteNumbers
  }

  func load() -> [RankedBrokerProfile] { profiles }

  func replaceAll(_ profiles: [RankedBrokerProfile]) async {
    let writeNumber = writes.count + 1
    writes.append(profiles)
    let waiters = writeWaiters.removeValue(forKey: writeNumber) ?? []
    for waiter in waiters {
      waiter.resume()
    }
    if heldWriteNumbers.contains(writeNumber) {
      await withCheckedContinuation { continuation in
        releaseContinuations[writeNumber] = continuation
      }
    }
    self.profiles = profiles
  }

  var writeCount: Int { writes.count }
  var persistedProfiles: [RankedBrokerProfile] { profiles }

  func write(_ number: Int) -> [RankedBrokerProfile] {
    writes[number - 1]
  }

  func waitForWrite(_ number: Int) async {
    guard writes.count < number else { return }
    await withCheckedContinuation { continuation in
      writeWaiters[number, default: []].append(continuation)
    }
  }

  func releaseWrite(_ number: Int) {
    releaseContinuations.removeValue(forKey: number)?.resume()
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

private actor OneShotRemoteProfileSync: ProfileSyncing {
  private let profiles: [RankedBrokerProfile]
  private var didSynchronize = false

  init(profiles: [RankedBrokerProfile]) {
    self.profiles = profiles
  }

  func status() -> ProfileSyncStatus {
    .available
  }

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    .available
  }

  func synchronize() -> ProfileSyncExchange {
    guard !didSynchronize else { return .noChanges }
    didSynchronize = true
    return ProfileSyncExchange(
      remoteProfiles: profiles
    )
  }

  func cancel() {}
}

private actor CountingProfileRepository: ProfileRepositoryProtocol {
  private var profiles: [RankedBrokerProfile]
  private var writes = 0

  init(profiles: [RankedBrokerProfile]) {
    self.profiles = profiles
  }

  func load() -> [RankedBrokerProfile] { profiles }

  func replaceAll(_ profiles: [RankedBrokerProfile]) {
    writes += 1
    self.profiles = profiles
  }

  func writeCount() -> Int { writes }
}

private actor GatedFeedGenerationCoordinator:
  BrokerFeedGenerationCoordinating
{
  private var notifications = 0
  private var profilesByID: [BrokerProfile.ID: BrokerProfile] = [:]
  private var firstNotificationStarted = false
  private var firstNotificationWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstNotificationGate: CheckedContinuation<Void, Never>?

  func profilesDidChange(_ profiles: [BrokerProfile]) async {
    notifications += 1
    if notifications == 1 {
      firstNotificationStarted = true
      let waiters = firstNotificationWaiters
      firstNotificationWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstNotificationGate = continuation
      }
    }
    for profile in profiles {
      profilesByID[profile.id] = profile
    }
  }

  func credentialRevisionDidChange(
    profileID: BrokerProfile.ID,
    revision: UInt64
  ) {}

  func waitForFirstNotification() async {
    if firstNotificationStarted { return }
    await withCheckedContinuation { continuation in
      firstNotificationWaiters.append(continuation)
    }
  }

  func finishFirstNotification() {
    firstNotificationGate?.resume()
    firstNotificationGate = nil
  }

  func notificationCount() -> Int { notifications }

  func latestProfile(
    profileID: BrokerProfile.ID
  ) -> BrokerProfile? {
    profilesByID[profileID]
  }
}

private actor RecordingFeedGenerationCoordinator:
  BrokerFeedGenerationCoordinating
{
  private var profilesByID: [BrokerProfile.ID: BrokerProfile] = [:]
  private var revisionsByID: [BrokerProfile.ID: UInt64] = [:]

  func profilesDidChange(_ profiles: [BrokerProfile]) {
    for profile in profiles {
      profilesByID[profile.id] = profile
    }
  }

  func credentialRevisionDidChange(
    profileID: BrokerProfile.ID,
    revision: UInt64
  ) {
    revisionsByID[profileID] = revision
  }

  func latestProfile(
    profileID: BrokerProfile.ID
  ) -> BrokerProfile? {
    profilesByID[profileID]
  }

  func latestCredentialRevision(
    _ profileID: BrokerProfile.ID
  ) -> UInt64? {
    revisionsByID[profileID]
  }
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

private actor DeletionHistoryRecorder {
  private(set) var brokerIDs: [UUID] = []

  func record(_ brokerID: UUID) {
    brokerIDs.append(brokerID)
  }
}

private actor RecordingDeletionHistoryMaintenance:
  BrokerHistoryMaintaining
{
  let brokerID: UUID
  let recorder: DeletionHistoryRecorder

  init(brokerID: UUID, recorder: DeletionHistoryRecorder) {
    self.brokerID = brokerID
    self.recorder = recorder
  }

  func retentionPolicy() -> HistoryRetentionPolicy { .default }
  func maintenanceStatus() -> HistoryMaintenanceStatus { .notRun }
  func applyRetention() -> HistoryMaintenanceReport {
    HistoryMaintenanceReport(
      deletedForTopicLimit: 0,
      deletedForBrokerLimit: 0,
      deletedOrphanTopicCount: 0,
      finalMessageCount: 0,
      finalSQLiteBytes: 0
    )
  }
  func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) -> HistoryClearOutcome {
    completedClear
  }
  func clearBrokerHistory() async -> HistoryClearOutcome {
    await recorder.record(brokerID)
    return completedClear
  }
  func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) -> HistoryClearOutcome {
    completedClear
  }
  func retrySecureCleanup() {}

  private var completedClear: HistoryClearOutcome {
    HistoryClearOutcome(
      summary: HistoryClearSummary(
        deletedMessageCount: 0,
        deletedTopicCount: 0,
        deletedCoverageGapCount: 0,
        secureCleanupStatus: .completed
      )
    )
  }
}

private actor PartialDeletionHistoryMaintenance:
  BrokerHistoryMaintaining
{
  let recorder: DeletionResumeRecorder

  init(recorder: DeletionResumeRecorder) {
    self.recorder = recorder
  }

  func retentionPolicy() -> HistoryRetentionPolicy { .default }
  func maintenanceStatus() -> HistoryMaintenanceStatus { .notRun }
  func applyRetention() -> HistoryMaintenanceReport {
    HistoryMaintenanceReport(
      deletedForTopicLimit: 0,
      deletedForBrokerLimit: 0,
      deletedOrphanTopicCount: 0,
      finalMessageCount: 0,
      finalSQLiteBytes: 0
    )
  }
  func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) -> HistoryClearOutcome {
    partial
  }
  func clearBrokerHistory() -> HistoryClearOutcome { partial }
  func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) async -> HistoryClearOutcome {
    await recorder.recordResume()
    return HistoryClearOutcome(
      summary: HistoryClearSummary(
        deletedMessageCount: 2,
        deletedTopicCount: 1,
        deletedCoverageGapCount: 0,
        secureCleanupStatus: .completed
      )
    )
  }
  func retrySecureCleanup() {}

  private var partial: HistoryClearOutcome {
    let summary = HistoryClearSummary(
      deletedMessageCount: 1,
      deletedTopicCount: 0,
      deletedCoverageGapCount: 0,
      secureCleanupStatus: .notRequired
    )
    return HistoryClearOutcome(
      summary: summary,
      continuation: .broker(
        scope: HistoryBrokerClearScope(
          throughMessageOrder: 2,
          throughTopicOrder: 1,
          throughCoverageGapOrder: 0
        ),
        accumulated: summary
      ),
      interruption: .storageFailure
    )
  }
}

private actor FailingDeletionHistoryMaintenance:
  BrokerHistoryMaintaining
{
  func retentionPolicy() -> HistoryRetentionPolicy { .default }
  func maintenanceStatus() -> HistoryMaintenanceStatus { .notRun }
  func applyRetention() throws -> HistoryMaintenanceReport {
    throw ProfileRepositoryFailure()
  }
  func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) throws -> HistoryClearOutcome {
    throw ProfileRepositoryFailure()
  }
  func clearBrokerHistory() throws -> HistoryClearOutcome {
    throw ProfileRepositoryFailure()
  }
  func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) throws -> HistoryClearOutcome {
    throw ProfileRepositoryFailure()
  }
  func retrySecureCleanup() throws {
    throw ProfileRepositoryFailure()
  }
}

private actor PendingSecureCleanupHistoryMaintenance:
  BrokerHistoryMaintaining
{
  let recorder: SecureCleanupRetryRecorder

  init(recorder: SecureCleanupRetryRecorder) {
    self.recorder = recorder
  }

  func retentionPolicy() -> HistoryRetentionPolicy { .default }
  func maintenanceStatus() -> HistoryMaintenanceStatus { .notRun }
  func applyRetention() -> HistoryMaintenanceReport {
    HistoryMaintenanceReport(
      deletedForTopicLimit: 0,
      deletedForBrokerLimit: 0,
      deletedOrphanTopicCount: 0,
      finalMessageCount: 0,
      finalSQLiteBytes: 0
    )
  }
  func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) -> HistoryClearOutcome {
    pending
  }
  func clearBrokerHistory() -> HistoryClearOutcome { pending }
  func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) -> HistoryClearOutcome {
    pending
  }
  func retrySecureCleanup() async {
    await recorder.recordRetry()
  }

  private var pending: HistoryClearOutcome {
    HistoryClearOutcome(
      summary: HistoryClearSummary(
        deletedMessageCount: 2,
        deletedTopicCount: 1,
        deletedCoverageGapCount: 0,
        secureCleanupStatus: .pending
      )
    )
  }
}

private actor DeletionResumeRecorder {
  private(set) var resumeCount = 0

  func recordResume() {
    resumeCount += 1
  }
}

private actor SecureCleanupRetryRecorder {
  private(set) var retryCount = 0

  func recordRetry() {
    retryCount += 1
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

private func uniqueRankedProfile(
  name: String,
  rank: Int64
) -> RankedBrokerProfile {
  RankedBrokerProfile(
    profile: BrokerProfile(
      id: UUID(),
      name: name,
      host: "broker.example",
      port: 1_883,
      transport: .tcp,
      username: nil,
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
