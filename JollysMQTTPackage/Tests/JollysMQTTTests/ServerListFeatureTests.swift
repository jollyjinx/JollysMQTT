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

private func rankedProfile(name: String, rank: Int64) -> RankedBrokerProfile {
  RankedBrokerProfile(
    profile: BrokerProfile(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
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
