import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

public struct ProfileEditorState: Equatable, Identifiable, Sendable {
  public enum Mode: Equatable, Sendable {
    case create
    case edit
  }

  public let id: UUID
  public let mode: Mode
  public var name: String
  public var host: String
  public var port: Int
  public var transport: BrokerTransport
  public var username: String
  public var clientIDPolicy: ClientIDPolicy
  public var cleanSession: Bool
  public var keepAliveSeconds: Int
  public var reconnectPolicy: ReconnectPolicy
  public var subscriptions: [SubscriptionDefinition]
  public var validationIssues: [BrokerProfileValidationIssue]

  public init(profile: BrokerProfile, mode: Mode) {
    self.id = profile.id
    self.mode = mode
    self.name = profile.name
    self.host = profile.host
    self.port = profile.port
    self.transport = profile.transport
    self.username = profile.username ?? ""
    self.clientIDPolicy = profile.clientIDPolicy
    self.cleanSession = profile.cleanSession
    self.keepAliveSeconds = profile.keepAliveSeconds
    self.reconnectPolicy = profile.reconnectPolicy
    self.subscriptions = profile.subscriptions
    self.validationIssues = []
  }

  public var hasBroadSubscriptionWarning: Bool {
    subscriptions.contains {
      $0.isEnabled && ($0.filter == "#" || $0.filter == "$SYS/#")
    }
  }

  public var profile: BrokerProfile {
    BrokerProfile(
      id: id,
      name: name,
      host: host,
      port: port,
      transport: transport,
      username: username.isEmpty ? nil : username,
      clientIDPolicy: clientIDPolicy,
      cleanSession: cleanSession,
      keepAliveSeconds: keepAliveSeconds,
      reconnectPolicy: reconnectPolicy,
      subscriptions: subscriptions
    )
  }
}

public struct ConnectReadyState: Equatable, Sendable {
  public let profile: BrokerProfile
  public let credentialRevision: UInt64
  public let requestID: UInt64

  public init(
    profile: BrokerProfile,
    credentialRevision: UInt64,
    requestID: UInt64
  ) {
    self.profile = profile
    self.credentialRevision = credentialRevision
    self.requestID = requestID
  }
}

public struct CredentialPromptState: Equatable, Sendable {
  public let profileID: BrokerProfile.ID
  public let profileName: String
  public let requestID: UInt64
  public var isSaving: Bool

  public init(
    profileID: BrokerProfile.ID,
    profileName: String,
    requestID: UInt64,
    isSaving: Bool = false
  ) {
    self.profileID = profileID
    self.profileName = profileName
    self.requestID = requestID
    self.isSaving = isSaving
  }
}

public enum CredentialPresentationError: Equatable, Sendable {
  case cancelled
  case denied
  case unavailable
}

public enum CredentialEffectFailure: Error, Equatable, Sendable {
  case cancelled
  case denied
  case unavailable
}

public enum ServerListFeature {
  public struct State: Equatable, Sendable {
    public var profiles: [RankedBrokerProfile]
    public var selectedProfileID: BrokerProfile.ID?
    public var editor: ProfileEditorState?
    public var isLoading: Bool
    public var hasLoaded: Bool
    public var persistenceError: Bool
    public var hasUnpersistedChanges: Bool
    public var pendingDeletionProfileID: BrokerProfile.ID?
    public var credentialStatuses: [BrokerProfile.ID: CredentialStatus]
    public var credentialPrompt: CredentialPromptState?
    public var credentialError: CredentialPresentationError?
    public var connectReady: ConnectReadyState?
    var pendingConnectRequest: PendingCredentialRequest?
    var pendingCredentialDeletionRequest: PendingCredentialRequest?
    var nextCredentialRequestID: UInt64

    public init(
      profiles: [RankedBrokerProfile] = [],
      selectedProfileID: BrokerProfile.ID? = nil,
      editor: ProfileEditorState? = nil,
      isLoading: Bool = false,
      hasLoaded: Bool = false,
      persistenceError: Bool = false,
      hasUnpersistedChanges: Bool = false,
      pendingDeletionProfileID: BrokerProfile.ID? = nil,
      credentialStatuses: [BrokerProfile.ID: CredentialStatus] = [:],
      credentialPrompt: CredentialPromptState? = nil,
      credentialError: CredentialPresentationError? = nil,
      connectReady: ConnectReadyState? = nil
    ) {
      self.profiles = profiles
      self.selectedProfileID = selectedProfileID
      self.editor = editor
      self.isLoading = isLoading
      self.hasLoaded = hasLoaded
      self.persistenceError = persistenceError
      self.hasUnpersistedChanges = hasUnpersistedChanges
      self.pendingDeletionProfileID = pendingDeletionProfileID
      self.credentialStatuses = credentialStatuses
      self.credentialPrompt = credentialPrompt
      self.credentialError = credentialError
      self.connectReady = connectReady
      self.pendingConnectRequest = nil
      self.pendingCredentialDeletionRequest = nil
      self.nextCredentialRequestID = 0
    }
  }

  public enum Intent: Equatable, Sendable {
    case load
    case select(BrokerProfile.ID?)
    case createProfile(id: UUID)
    case editProfile(BrokerProfile.ID)
    case duplicateProfile(BrokerProfile.ID, newID: UUID)
    case requestDeleteProfile(BrokerProfile.ID)
    case cancelDeleteProfile
    case confirmDeleteProfile
    case confirmDeleteProfileAndCredential
    case deleteProfile(BrokerProfile.ID)
    case deleteProfileAndCredential(BrokerProfile.ID)
    case moveProfile(BrokerProfile.ID, before: BrokerProfile.ID?)
    case setName(String)
    case setHost(String)
    case setPort(Int)
    case setTransport(BrokerTransport)
    case setUsername(String)
    case setClientIDPolicy(ClientIDPolicy)
    case setCleanSession(Bool)
    case setKeepAliveSeconds(Int)
    case setReconnectPolicy(ReconnectPolicy)
    case addSubscription(id: UUID)
    case removeSubscription(SubscriptionDefinition.ID)
    case setSubscriptionFilter(SubscriptionDefinition.ID, String)
    case setSubscriptionQoS(SubscriptionDefinition.ID, MQTTQualityOfService)
    case setSubscriptionEnabled(SubscriptionDefinition.ID, Bool)
    case cancelEditor
    case saveEditor
    case connect(BrokerProfile.ID)
    case submitCredential(TransientCredential)
    case cancelCredentialPrompt
    case dismissCredentialError
    case consumeConnectReady(requestID: UInt64)
  }

  public enum Action: Sendable {
    case loaded(Result<[RankedBrokerProfile], ProfileRepositoryFailure>)
    case persisted(Result<Void, ProfileRepositoryFailure>)
    case connectCredentialResolved(
      profileID: BrokerProfile.ID,
      requestID: UInt64,
      Result<CredentialStatus, CredentialEffectFailure>
    )
    case credentialSaved(
      profileID: BrokerProfile.ID,
      requestID: UInt64,
      Result<CredentialStatus, CredentialEffectFailure>
    )
    case credentialDeleted(
      profileID: BrokerProfile.ID,
      requestID: UInt64,
      Result<CredentialStatus, CredentialEffectFailure>
    )
  }

  public enum Effect: Equatable, Sendable {
    case loadProfiles
    case persistProfiles([RankedBrokerProfile])
    case checkCredential(BrokerProfile, requestID: UInt64)
    case saveCredential(
      profileID: BrokerProfile.ID,
      requestID: UInt64,
      TransientCredential
    )
    case deleteCredential(profileID: BrokerProfile.ID, requestID: UInt64)
  }

  public static func reduce(state: inout State, intent: Intent) -> Effect? {
    switch intent {
    case .load:
      state.isLoading = true
      return .loadProfiles

    case .select(let id):
      state.selectedProfileID = id

    case .createProfile(let id):
      state.editor = ProfileEditorState(
        profile: .new(id: id),
        mode: .create
      )

    case .editProfile(let id):
      guard let profile = state.profiles.first(where: { $0.id == id })?.profile else {
        return nil
      }
      state.editor = ProfileEditorState(profile: profile, mode: .edit)

    case .duplicateProfile(let id, let newID):
      guard let source = state.profiles.first(where: { $0.id == id })?.profile else {
        return nil
      }
      let copy = BrokerProfile(
        id: newID,
        name: source.name,
        host: source.host,
        port: source.port,
        transport: source.transport,
        username: source.username,
        clientIDPolicy: source.clientIDPolicy,
        cleanSession: source.cleanSession,
        keepAliveSeconds: source.keepAliveSeconds,
        reconnectPolicy: source.reconnectPolicy,
        subscriptions: source.subscriptions.map {
          SubscriptionDefinition(
            filter: $0.filter,
            qos: $0.qos,
            isEnabled: $0.isEnabled
          )
        }
      )
      state.editor = ProfileEditorState(profile: copy, mode: .create)

    case .requestDeleteProfile(let id):
      state.pendingDeletionProfileID = id

    case .cancelDeleteProfile:
      state.pendingDeletionProfileID = nil

    case .confirmDeleteProfile:
      guard let id = state.pendingDeletionProfileID else { return nil }
      state.pendingDeletionProfileID = nil
      return deleteProfile(id, from: &state)

    case .confirmDeleteProfileAndCredential:
      guard let id = state.pendingDeletionProfileID else { return nil }
      return beginProfileAndCredentialDeletion(id, in: &state)

    case .deleteProfile(let id):
      return deleteProfile(id, from: &state)

    case .deleteProfileAndCredential(let id):
      guard state.profiles.contains(where: { $0.id == id }) else { return nil }
      return beginProfileAndCredentialDeletion(id, in: &state)

    case .moveProfile(let id, let beforeID):
      guard let sourceIndex = state.profiles.firstIndex(where: { $0.id == id }) else {
        return nil
      }
      let moving = state.profiles.remove(at: sourceIndex)
      let destination =
        beforeID.flatMap { target in
          state.profiles.firstIndex(where: { $0.id == target })
        } ?? state.profiles.endIndex
      state.profiles.insert(moving, at: destination)
      state.profiles = normalizedRanks(state.profiles)
      state.hasUnpersistedChanges = true
      return .persistProfiles(state.profiles)

    case .setName(let value):
      state.editor?.name = value
    case .setHost(let value):
      state.editor?.host = value
    case .setPort(let value):
      state.editor?.port = value
    case .setTransport(let value):
      state.editor?.transport = value
    case .setUsername(let value):
      state.editor?.username = value
    case .setClientIDPolicy(let value):
      state.editor?.clientIDPolicy = value
    case .setCleanSession(let value):
      state.editor?.cleanSession = value
    case .setKeepAliveSeconds(let value):
      state.editor?.keepAliveSeconds = value
    case .setReconnectPolicy(let value):
      state.editor?.reconnectPolicy = value

    case .addSubscription(let id):
      state.editor?.subscriptions.append(
        SubscriptionDefinition(
          id: id,
          filter: "",
          qos: .atMostOnce
        )
      )

    case .removeSubscription(let id):
      state.editor?.subscriptions.removeAll { $0.id == id }

    case .setSubscriptionFilter(let id, let value):
      updateSubscription(in: &state, id: id) {
        SubscriptionDefinition(
          id: $0.id,
          filter: value,
          qos: $0.qos,
          isEnabled: $0.isEnabled
        )
      }

    case .setSubscriptionQoS(let id, let value):
      updateSubscription(in: &state, id: id) {
        SubscriptionDefinition(
          id: $0.id,
          filter: $0.filter,
          qos: value,
          isEnabled: $0.isEnabled
        )
      }

    case .setSubscriptionEnabled(let id, let value):
      updateSubscription(in: &state, id: id) {
        SubscriptionDefinition(
          id: $0.id,
          filter: $0.filter,
          qos: $0.qos,
          isEnabled: value
        )
      }

    case .cancelEditor:
      state.editor = nil

    case .saveEditor:
      guard var editor = state.editor else { return nil }
      let profile = editor.profile
      let issues = profile.validationIssues
      guard issues.isEmpty else {
        editor.validationIssues = issues
        state.editor = editor
        return nil
      }

      if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
        let rank = state.profiles[index].reorderRank
        state.profiles[index] = RankedBrokerProfile(
          profile: profile,
          reorderRank: rank
        )
      } else {
        state.profiles.append(
          RankedBrokerProfile(
            profile: profile,
            reorderRank: nextRank(after: state.profiles)
          )
        )
      }
      state.profiles = normalizedRanks(state.profiles)
      state.selectedProfileID = profile.id
      state.editor = nil
      state.hasUnpersistedChanges = true
      return .persistProfiles(state.profiles)

    case .connect(let id):
      guard let profile = state.profiles.first(where: { $0.id == id })?.profile else {
        return nil
      }
      let issues = profile.validationIssues
      guard issues.isEmpty else {
        state.editor = ProfileEditorState(profile: profile, mode: .edit)
        state.editor?.validationIssues = issues
        return nil
      }
      let requestID = nextCredentialRequestID(in: &state)
      state.connectReady = nil
      state.credentialPrompt = nil
      state.credentialError = nil
      guard profile.username != nil else {
        state.pendingConnectRequest = nil
        state.connectReady = ConnectReadyState(
          profile: profile,
          credentialRevision: 0,
          requestID: requestID
        )
        return nil
      }
      state.pendingConnectRequest = PendingCredentialRequest(
        profileID: id,
        requestID: requestID
      )
      return .checkCredential(profile, requestID: requestID)

    case .submitCredential(let credential):
      guard var prompt = state.credentialPrompt, !prompt.isSaving else {
        return nil
      }
      prompt.isSaving = true
      state.credentialPrompt = prompt
      state.credentialError = nil
      return .saveCredential(
        profileID: prompt.profileID,
        requestID: prompt.requestID,
        credential
      )

    case .cancelCredentialPrompt:
      state.credentialPrompt = nil
      state.pendingConnectRequest = nil
      state.credentialError = nil

    case .dismissCredentialError:
      state.credentialError = nil

    case .consumeConnectReady(let requestID):
      guard state.connectReady?.requestID == requestID else { return nil }
      state.connectReady = nil
    }

    return nil
  }

  @discardableResult
  public static func reduce(state: inout State, action: Action) -> Effect? {
    switch action {
    case .loaded(.success(let profiles)):
      state.profiles = profiles
      state.isLoading = false
      state.hasLoaded = true
      state.hasUnpersistedChanges = false
      if !profiles.contains(where: { $0.id == state.selectedProfileID }) {
        state.selectedProfileID = profiles.first?.id
      }
    case .loaded(.failure):
      state.isLoading = false
      state.hasLoaded = true
      state.persistenceError = true
    case .persisted(.success):
      state.persistenceError = false
      state.hasUnpersistedChanges = false
    case .persisted(.failure):
      state.persistenceError = true
      state.hasUnpersistedChanges = true

    case .connectCredentialResolved(
      let profileID,
      let requestID,
      .success(let status)
    ):
      guard
        state.pendingConnectRequest
          == PendingCredentialRequest(profileID: profileID, requestID: requestID),
        let profile = state.profiles.first(where: { $0.id == profileID })?.profile
      else { return nil }
      state.pendingConnectRequest = nil
      state.credentialStatuses[profileID] = status
      switch status.availability {
      case .available:
        state.connectReady = ConnectReadyState(
          profile: profile,
          credentialRevision: status.revision,
          requestID: requestID
        )
      case .missing:
        state.credentialPrompt = CredentialPromptState(
          profileID: profileID,
          profileName: profile.name,
          requestID: requestID
        )
      }

    case .connectCredentialResolved(
      let profileID,
      let requestID,
      .failure(let failure)
    ):
      guard
        state.pendingConnectRequest
          == PendingCredentialRequest(profileID: profileID, requestID: requestID)
      else { return nil }
      state.pendingConnectRequest = nil
      state.credentialError = presentationError(for: failure)

    case .credentialSaved(
      let profileID,
      let requestID,
      .success(let status)
    ):
      guard
        state.credentialPrompt?.profileID == profileID,
        state.credentialPrompt?.requestID == requestID,
        let profile = state.profiles.first(where: { $0.id == profileID })?.profile
      else { return nil }
      state.credentialStatuses[profileID] = status
      state.credentialPrompt = nil
      state.connectReady = ConnectReadyState(
        profile: profile,
        credentialRevision: status.revision,
        requestID: requestID
      )

    case .credentialSaved(
      let profileID,
      let requestID,
      .failure(let failure)
    ):
      guard
        state.credentialPrompt?.profileID == profileID,
        state.credentialPrompt?.requestID == requestID
      else { return nil }
      state.credentialPrompt?.isSaving = false
      state.credentialError = presentationError(for: failure)

    case .credentialDeleted(
      let profileID,
      let requestID,
      .success(let status)
    ):
      guard
        state.pendingCredentialDeletionRequest
          == PendingCredentialRequest(profileID: profileID, requestID: requestID)
      else { return nil }
      state.pendingCredentialDeletionRequest = nil
      state.credentialStatuses[profileID] = status
      return deleteProfile(profileID, from: &state)

    case .credentialDeleted(
      let profileID,
      let requestID,
      .failure(let failure)
    ):
      guard
        state.pendingCredentialDeletionRequest
          == PendingCredentialRequest(profileID: profileID, requestID: requestID)
      else { return nil }
      state.pendingCredentialDeletionRequest = nil
      state.credentialError = presentationError(for: failure)
    }
    return nil
  }

  private static func updateSubscription(
    in state: inout State,
    id: SubscriptionDefinition.ID,
    transform: (SubscriptionDefinition) -> SubscriptionDefinition
  ) {
    guard let index = state.editor?.subscriptions.firstIndex(where: { $0.id == id }),
      let current = state.editor?.subscriptions[index]
    else { return }
    state.editor?.subscriptions[index] = transform(current)
  }

  private static func normalizedRanks(
    _ profiles: [RankedBrokerProfile]
  ) -> [RankedBrokerProfile] {
    profiles.enumerated().map { index, ranked in
      RankedBrokerProfile(
        profile: ranked.profile,
        reorderRank: Int64(index + 1) * 1_024
      )
    }
  }

  private static func nextRank(after profiles: [RankedBrokerProfile]) -> Int64 {
    (profiles.map(\.reorderRank).max() ?? 0) + 1_024
  }

  private static func nextCredentialRequestID(in state: inout State) -> UInt64 {
    state.nextCredentialRequestID &+= 1
    return state.nextCredentialRequestID
  }

  private static func presentationError(
    for failure: CredentialEffectFailure
  ) -> CredentialPresentationError {
    switch failure {
    case .cancelled: .cancelled
    case .denied: .denied
    case .unavailable: .unavailable
    }
  }

  private static func deleteProfile(
    _ id: BrokerProfile.ID,
    from state: inout State
  ) -> Effect {
    if state.pendingDeletionProfileID == id {
      state.pendingDeletionProfileID = nil
    }
    state.profiles.removeAll { $0.id == id }
    state.profiles = normalizedRanks(state.profiles)
    if state.selectedProfileID == id {
      state.selectedProfileID = state.profiles.first?.id
    }
    state.hasUnpersistedChanges = true
    state.credentialStatuses[id] = nil
    if state.connectReady?.profile.id == id {
      state.connectReady = nil
    }
    return .persistProfiles(state.profiles)
  }

  private static func beginProfileAndCredentialDeletion(
    _ id: BrokerProfile.ID,
    in state: inout State
  ) -> Effect {
    if state.pendingDeletionProfileID == id {
      state.pendingDeletionProfileID = nil
    }
    let requestID = nextCredentialRequestID(in: &state)
    state.pendingCredentialDeletionRequest = PendingCredentialRequest(
      profileID: id,
      requestID: requestID
    )
    return .deleteCredential(profileID: id, requestID: requestID)
  }
}

struct PendingCredentialRequest: Equatable, Sendable {
  let profileID: BrokerProfile.ID
  let requestID: UInt64
}

public struct ProfileRepositoryFailure: Error, Equatable, Sendable {
  public init() {}
}

@MainActor
@Observable
public final class ServerListStore {
  public enum EditorTextField: Sendable {
    case name
    case host
    case username
    case explicitClientID
  }

  public enum EditorIntegerField: Sendable {
    case port
    case keepAlive
    case reconnectInitial
    case reconnectMaximum
  }

  public enum EditorClientIDMode: String, CaseIterable, Sendable {
    case stableGenerated
    case randomPerConnection
    case explicit
  }

  public private(set) var state: ServerListFeature.State

  private let repository: any ProfileRepositoryProtocol
  private let credentialRepository: any CredentialRepositoryProtocol
  private let brokerFeedGenerationCoordinator: any BrokerFeedGenerationCoordinating
  private var persistenceTail: Task<Result<Void, ProfileRepositoryFailure>, Never>?
  private var pendingPersistenceCount = 0

  public init(
    initialState: ServerListFeature.State = .init(),
    repository: any ProfileRepositoryProtocol,
    credentialRepository: any CredentialRepositoryProtocol = CredentialRepository.shared,
    brokerFeedGenerationCoordinator:
      any BrokerFeedGenerationCoordinating =
      NoopBrokerFeedGenerationCoordinator()
  ) {
    self.state = initialState
    self.repository = repository
    self.credentialRepository = credentialRepository
    self.brokerFeedGenerationCoordinator =
      brokerFeedGenerationCoordinator
  }

  public func send(_ intent: ServerListFeature.Intent) async {
    guard let effect = ServerListFeature.reduce(state: &state, intent: intent) else {
      return
    }

    await execute(effect)
  }

  private func execute(_ effect: ServerListFeature.Effect) async {
    switch effect {
    case .loadProfiles:
      do {
        let profiles = try await repository.load()
        _ = ServerListFeature.reduce(
          state: &state,
          action: .loaded(.success(profiles))
        )
      } catch {
        _ = ServerListFeature.reduce(
          state: &state,
          action: .loaded(.failure(ProfileRepositoryFailure()))
        )
      }

    case .persistProfiles(let profiles):
      pendingPersistenceCount += 1
      let previous = persistenceTail
      let repository = repository
      let brokerFeedGenerationCoordinator =
        brokerFeedGenerationCoordinator
      let task = Task<Result<Void, ProfileRepositoryFailure>, Never> {
        if let previous {
          _ = await previous.value
        }
        do {
          try await repository.replaceAll(profiles)
          await brokerFeedGenerationCoordinator.profilesDidChange(
            profiles.map(\.profile)
          )
          return .success(())
        } catch {
          return .failure(ProfileRepositoryFailure())
        }
      }
      persistenceTail = task
      let result = await task.value
      pendingPersistenceCount -= 1

      switch result {
      case .success where pendingPersistenceCount == 0:
        _ = ServerListFeature.reduce(
          state: &state,
          action: .persisted(.success(()))
        )
      case .failure:
        _ = ServerListFeature.reduce(
          state: &state,
          action: .persisted(.failure(ProfileRepositoryFailure()))
        )
      case .success:
        break
      }

    case .checkCredential(let profile, let requestID):
      let result: Result<CredentialStatus, CredentialEffectFailure>
      do {
        try Task.checkCancellation()
        let status = try await credentialRepository.status(for: profile.id)
        try Task.checkCancellation()
        result = .success(status)
      } catch {
        result = .failure(credentialFailure(for: error))
      }
      _ = ServerListFeature.reduce(
        state: &state,
        action: .connectCredentialResolved(
          profileID: profile.id,
          requestID: requestID,
          result
        )
      )
    case .saveCredential(let profileID, let requestID, let credential):
      let result: Result<CredentialStatus, CredentialEffectFailure>
      do {
        try Task.checkCancellation()
        let status = try await credentialRepository.save(
          credential,
          for: profileID
        )
        result = .success(status)
      } catch {
        result = .failure(credentialFailure(for: error))
      }
      _ = ServerListFeature.reduce(
        state: &state,
        action: .credentialSaved(
          profileID: profileID,
          requestID: requestID,
          result
        )
      )
      if case .success(let status) = result {
        await brokerFeedGenerationCoordinator.credentialRevisionDidChange(
          profileID: profileID,
          revision: status.revision
        )
      }

    case .deleteCredential(let profileID, let requestID):
      let result: Result<CredentialStatus, CredentialEffectFailure>
      do {
        try Task.checkCancellation()
        let status = try await credentialRepository.delete(for: profileID)
        result = .success(status)
      } catch {
        result = .failure(credentialFailure(for: error))
      }
      if case .success(let status) = result {
        await brokerFeedGenerationCoordinator.credentialRevisionDidChange(
          profileID: profileID,
          revision: status.revision
        )
      }
      if let followUp = ServerListFeature.reduce(
        state: &state,
        action: .credentialDeleted(
          profileID: profileID,
          requestID: requestID,
          result
        )
      ) {
        await execute(followUp)
      }
    }
  }

  private func credentialFailure(for error: any Error) -> CredentialEffectFailure {
    if error is CancellationError {
      return .cancelled
    }
    guard let error = error as? CredentialRepositoryError else {
      return .unavailable
    }
    switch error {
    case .cancelled:
      return .cancelled
    case .denied:
      return .denied
    case .missing, .staleRevision, .keychainFailure, .revisionOverflow:
      return .unavailable
    }
  }

  public func sendImmediately(_ intent: ServerListFeature.Intent) {
    let effect = ServerListFeature.reduce(state: &state, intent: intent)
    precondition(effect == nil, "Immediate editor intents cannot start effects")
  }

  public subscript(editorText field: EditorTextField) -> String {
    get {
      guard let editor = state.editor else { return "" }
      return switch field {
      case .name:
        editor.name
      case .host:
        editor.host
      case .username:
        editor.username
      case .explicitClientID:
        if case .explicit(let value) = editor.clientIDPolicy { value } else { "" }
      }
    }
    set {
      switch field {
      case .name:
        sendImmediately(.setName(newValue))
      case .host:
        sendImmediately(.setHost(newValue))
      case .username:
        sendImmediately(.setUsername(newValue))
      case .explicitClientID:
        sendImmediately(.setClientIDPolicy(.explicit(newValue)))
      }
    }
  }

  public subscript(editorInteger field: EditorIntegerField) -> Int {
    get {
      guard let editor = state.editor else { return 0 }
      return switch field {
      case .port:
        editor.port
      case .keepAlive:
        editor.keepAliveSeconds
      case .reconnectInitial:
        if case .exponential(let initial, _) = editor.reconnectPolicy {
          initial
        } else {
          1
        }
      case .reconnectMaximum:
        if case .exponential(_, let maximum) = editor.reconnectPolicy {
          maximum
        } else {
          60
        }
      }
    }
    set {
      switch field {
      case .port:
        sendImmediately(.setPort(newValue))
      case .keepAlive:
        sendImmediately(.setKeepAliveSeconds(newValue))
      case .reconnectInitial:
        let maximum = self[editorInteger: .reconnectMaximum]
        sendImmediately(
          .setReconnectPolicy(
            .exponential(
              initialDelaySeconds: newValue,
              maximumDelaySeconds: maximum
            )
          )
        )
      case .reconnectMaximum:
        let initial = self[editorInteger: .reconnectInitial]
        sendImmediately(
          .setReconnectPolicy(
            .exponential(
              initialDelaySeconds: initial,
              maximumDelaySeconds: newValue
            )
          )
        )
      }
    }
  }

  public var editorTransport: BrokerTransport {
    get { state.editor?.transport ?? .tcp }
    set { sendImmediately(.setTransport(newValue)) }
  }

  public var editorClientIDMode: EditorClientIDMode {
    get {
      switch state.editor?.clientIDPolicy ?? .stableGenerated {
      case .stableGenerated:
        .stableGenerated
      case .randomPerConnection:
        .randomPerConnection
      case .explicit:
        .explicit
      }
    }
    set {
      switch newValue {
      case .stableGenerated:
        sendImmediately(.setClientIDPolicy(.stableGenerated))
      case .randomPerConnection:
        sendImmediately(.setClientIDPolicy(.randomPerConnection))
      case .explicit:
        sendImmediately(.setClientIDPolicy(.explicit("")))
      }
    }
  }

  public var editorCleanSession: Bool {
    get { state.editor?.cleanSession ?? true }
    set { sendImmediately(.setCleanSession(newValue)) }
  }

  public var editorReconnectEnabled: Bool {
    get {
      if case .exponential = state.editor?.reconnectPolicy { true } else { false }
    }
    set {
      sendImmediately(
        .setReconnectPolicy(newValue ? .standard : .disabled)
      )
    }
  }

  public var selection: BrokerProfile.ID? {
    get { state.selectedProfileID }
    set { sendImmediately(.select(newValue)) }
  }

  public var editorPresented: Bool {
    get { state.editor != nil }
    set {
      if !newValue {
        sendImmediately(.cancelEditor)
      }
    }
  }

  public var deletionPresented: Bool {
    get { state.pendingDeletionProfileID != nil }
    set {
      if !newValue {
        sendImmediately(.cancelDeleteProfile)
      }
    }
  }

  public var credentialPromptPresented: Bool {
    get { state.credentialPrompt != nil }
    set {
      if !newValue {
        sendImmediately(.cancelCredentialPrompt)
      }
    }
  }

  public var credentialErrorPresented: Bool {
    get { state.credentialError != nil }
    set {
      if !newValue {
        sendImmediately(.dismissCredentialError)
      }
    }
  }

  public var pendingDeletionName: String {
    guard let id = state.pendingDeletionProfileID else { return "" }
    return state.profiles.first(where: { $0.id == id })?.profile.name ?? ""
  }

  public subscript(subscriptionFilter id: SubscriptionDefinition.ID) -> String {
    get {
      state.editor?.subscriptions.first(where: { $0.id == id })?.filter ?? ""
    }
    set { sendImmediately(.setSubscriptionFilter(id, newValue)) }
  }

  public subscript(subscriptionEnabled id: SubscriptionDefinition.ID) -> Bool {
    get {
      state.editor?.subscriptions.first(where: { $0.id == id })?.isEnabled ?? false
    }
    set { sendImmediately(.setSubscriptionEnabled(id, newValue)) }
  }

  public subscript(
    subscriptionQoS id: SubscriptionDefinition.ID
  ) -> MQTTQualityOfService {
    get {
      state.editor?.subscriptions.first(where: { $0.id == id })?.qos ?? .atMostOnce
    }
    set { sendImmediately(.setSubscriptionQoS(id, newValue)) }
  }
}
