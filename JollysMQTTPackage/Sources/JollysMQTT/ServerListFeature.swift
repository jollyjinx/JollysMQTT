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

public enum ServerListFeature {
  public struct State: Equatable, Sendable {
    public var profiles: [RankedBrokerProfile]
    public var selectedProfileID: BrokerProfile.ID?
    public var editor: ProfileEditorState?
    public var isLoading: Bool
    public var hasLoaded: Bool
    public var persistenceError: Bool
    public var hasUnpersistedChanges: Bool
    public var connectProfile: BrokerProfile?
    public var pendingDeletionProfileID: BrokerProfile.ID?

    public init(
      profiles: [RankedBrokerProfile] = [],
      selectedProfileID: BrokerProfile.ID? = nil,
      editor: ProfileEditorState? = nil,
      isLoading: Bool = false,
      hasLoaded: Bool = false,
      persistenceError: Bool = false,
      hasUnpersistedChanges: Bool = false,
      connectProfile: BrokerProfile? = nil,
      pendingDeletionProfileID: BrokerProfile.ID? = nil
    ) {
      self.profiles = profiles
      self.selectedProfileID = selectedProfileID
      self.editor = editor
      self.isLoading = isLoading
      self.hasLoaded = hasLoaded
      self.persistenceError = persistenceError
      self.hasUnpersistedChanges = hasUnpersistedChanges
      self.connectProfile = connectProfile
      self.pendingDeletionProfileID = pendingDeletionProfileID
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
    case deleteProfile(BrokerProfile.ID)
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
  }

  public enum Action: Sendable {
    case loaded(Result<[RankedBrokerProfile], ProfileRepositoryFailure>)
    case persisted(Result<Void, ProfileRepositoryFailure>)
  }

  public enum Effect: Equatable, Sendable {
    case loadProfiles
    case persistProfiles([RankedBrokerProfile])
    case connect(BrokerProfile)
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

    case .deleteProfile(let id):
      return deleteProfile(id, from: &state)

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
      state.connectProfile = profile
      return .connect(profile)
    }

    return nil
  }

  public static func reduce(state: inout State, action: Action) {
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
    }
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

  private static func deleteProfile(
    _ id: BrokerProfile.ID,
    from state: inout State
  ) -> Effect {
    state.profiles.removeAll { $0.id == id }
    state.profiles = normalizedRanks(state.profiles)
    if state.selectedProfileID == id {
      state.selectedProfileID = state.profiles.first?.id
    }
    state.hasUnpersistedChanges = true
    return .persistProfiles(state.profiles)
  }
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
  private var persistenceTail: Task<Result<Void, ProfileRepositoryFailure>, Never>?
  private var pendingPersistenceCount = 0

  public init(
    initialState: ServerListFeature.State = .init(),
    repository: any ProfileRepositoryProtocol
  ) {
    self.state = initialState
    self.repository = repository
  }

  public func send(_ intent: ServerListFeature.Intent) async {
    guard let effect = ServerListFeature.reduce(state: &state, intent: intent) else {
      return
    }

    switch effect {
    case .loadProfiles:
      do {
        let profiles = try await repository.load()
        ServerListFeature.reduce(
          state: &state,
          action: .loaded(.success(profiles))
        )
      } catch {
        ServerListFeature.reduce(
          state: &state,
          action: .loaded(.failure(ProfileRepositoryFailure()))
        )
      }

    case .persistProfiles(let profiles):
      pendingPersistenceCount += 1
      let previous = persistenceTail
      let repository = repository
      let task = Task<Result<Void, ProfileRepositoryFailure>, Never> {
        if let previous {
          _ = await previous.value
        }
        do {
          try await repository.replaceAll(profiles)
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
        ServerListFeature.reduce(
          state: &state,
          action: .persisted(.success(()))
        )
      case .failure:
        ServerListFeature.reduce(
          state: &state,
          action: .persisted(.failure(ProfileRepositoryFailure()))
        )
      case .success:
        break
      }

    case .connect:
      break
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
