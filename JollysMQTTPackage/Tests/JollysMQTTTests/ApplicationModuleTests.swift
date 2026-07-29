import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("Application composition module smoke tests")
struct ApplicationModuleTests {
  @Test("Composition module joins the three implementation layers")
  func moduleBoundaries() {
    #expect(
      ApplicationModule.dependencies == [
        "JollysMQTTCore",
        "JollysMQTTTransport",
        "JollysMQTTStorage",
      ]
    )
  }

  @Test("Live composition defaults to a local-first, local-only profile repository")
  func localFirstProfileComposition() async throws {
    let repository = try #require(
      JollysMQTTAppDependencies.shared.profileRepository
        as? LocalFirstProfileRepository
    )
    #expect(await repository.syncStatus() == .localOnly)
  }

  @Test("Profile sync build selection fails closed")
  func profileSyncBuildSelectionFailsClosed() {
    #expect(ProfileSyncBuildSelection(values: [:]) == .localOnly)
    #expect(
      ProfileSyncBuildSelection(
        values: [
          "JollysMQTTProfileSyncMode": "cloudKit",
          "JollysMQTTCloudKitContainerIdentifier":
            "iCloud.eu.jinx.JollysMQTT",
        ]
      ) == .localOnly
    )
    #expect(
      ProfileSyncBuildSelection(
        values: [
          "JollysMQTTProfileSyncMode": "localOnly",
          "JollysMQTTCloudKitContainerIdentifier":
            "iCloud.eu.jinx.JollysMQTT",
          "JollysMQTTCloudKitZoneName":
            "EncryptedBrokerProfiles",
        ]
      ) == .localOnly
    )
  }

  @Test("Complete explicit CloudKit selection preserves the configured container")
  func explicitCloudKitBuildSelection() {
    let selection = ProfileSyncBuildSelection(
      values: [
        "JollysMQTTProfileSyncMode": "cloudKit",
        "JollysMQTTCloudKitContainerIdentifier":
          "iCloud.example.Fork",
        "JollysMQTTCloudKitZoneName":
          "EncryptedBrokerProfiles",
      ]
    )

    #expect(
      selection
        == .cloudKit(
          CloudKitProfileSyncConfiguration(
            containerIdentifier: "iCloud.example.Fork",
            zoneName: "EncryptedBrokerProfiles"
          )
        )
    )
  }

  @MainActor
  @Test("Profile sync controls require explicit recovery choice")
  func profileSyncRecoveryControls() async {
    let recovery = ProfileSyncRecovery(
      reason: .encryptedDataReset
    )
    let repository = ProfileSyncRepositoryStub(
      status: .recoveryRequired(recovery)
    )
    let store = ProfileSyncControlStore(
      repository: repository
    )

    await store.start()

    #expect(store.status == .recoveryRequired(recovery))
    #expect(await repository.decisions().isEmpty)

    await store.resumeUsingLocalProfiles()

    #expect(store.status == .available)
    #expect(
      await repository.decisions()
        == [.resumeCloudSyncUsingLocalProfiles]
    )
  }

  @Test("Device-only sync choice survives relaunch and can be re-enabled")
  func deviceOnlyPreferenceSurvivesRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(
      path: "cloudkit-profile-sync-preferences.json"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = ProfileSyncRecovery(reason: .accountChanged)
    let snapshot = ProfileSyncSnapshot(
      generation: 1,
      profiles: []
    )
    let firstAdapter = RecordingProfileSync(
      status: .recoveryRequired(recovery)
    )
    let firstLaunch = ProvisionedProfileSync(
      adapter: firstAdapter,
      preferenceStore: LocalProfileSyncPreferenceStore(
        fileURL: fileURL
      )
    )

    #expect(
      await firstLaunch.resolveRecovery(
        .keepLocalOnly,
        localSnapshot: snapshot
      ) == .cloudSyncDisabled
    )

    let relaunchedAdapter = RecordingProfileSync(status: .available)
    let relaunched = ProvisionedProfileSync(
      adapter: relaunchedAdapter,
      preferenceStore: LocalProfileSyncPreferenceStore(
        fileURL: fileURL
      )
    )

    #expect(
      await relaunched.stageLocalProfiles(snapshot)
        == .cloudSyncDisabled
    )
    #expect(await relaunchedAdapter.stagedSnapshots().isEmpty)
    #expect(
      await relaunched.resolveRecovery(
        .resumeCloudSyncUsingLocalProfiles,
        localSnapshot: snapshot
      ) == .available
    )
    #expect(
      await relaunchedAdapter.stagedSnapshots() == [snapshot]
    )
  }

  @Test("Local-only builds ignore a persisted CloudKit opt-out")
  func localOnlyBuildIgnoresCloudPreference() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "sync-preferences.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let preferenceStore = LocalProfileSyncPreferenceStore(
      fileURL: fileURL
    )
    try await preferenceStore.setCloudSyncDisabled(true)
    let sync = ProvisionedProfileSync(
      selection: .localOnly,
      stateStore: NoopProfileSyncStateStore(),
      preferenceStore: preferenceStore
    )

    #expect(await sync.status() == .localOnly)
    #expect(
      await sync.stageLocalProfiles(
        ProfileSyncSnapshot(generation: 1, profiles: [])
      ) == .localOnly
    )
  }

  @Test("A failed opt-out write remains non-uploading and visible")
  func failedOptOutWriteFailsSafe() async {
    let adapter = RecordingProfileSync(
      status: .recoveryRequired(
        ProfileSyncRecovery(reason: .accountChanged)
      )
    )
    let sync = ProvisionedProfileSync(
      adapter: adapter,
      preferenceStore: FailingProfileSyncPreferenceStore()
    )

    #expect(
      await sync.resolveRecovery(
        .keepLocalOnly,
        localSnapshot: ProfileSyncSnapshot(
          generation: 1,
          profiles: []
        )
      ) == .cloudSyncPreferenceSaveFailed
    )
    #expect(await sync.status() == .cloudSyncPreferenceSaveFailed)
    let exchange = try? await sync.synchronize()
    #expect(exchange == .noChanges)
  }
}

private actor ProfileSyncRepositoryStub:
  ProfileSynchronizingRepositoryProtocol
{
  private var currentStatus: ProfileSyncStatus
  private var recoveryDecisions: [ProfileSyncRecoveryDecision] = []

  init(status: ProfileSyncStatus) {
    currentStatus = status
  }

  func load() -> [RankedBrokerProfile] {
    []
  }

  func replaceAll(_ profiles: [RankedBrokerProfile]) {}

  func syncStatus() -> ProfileSyncStatus {
    currentStatus
  }

  func synchronize() -> ProfileSyncStatus {
    currentStatus
  }

  func resolveSyncRecovery(
    _ decision: ProfileSyncRecoveryDecision,
    expectedRecovery: ProfileSyncRecovery?
  ) -> ProfileSyncStatus {
    recoveryDecisions.append(decision)
    currentStatus =
      decision == .keepLocalOnly ? .localOnly : .available
    return currentStatus
  }

  func cancelSynchronization() {}

  func decisions() -> [ProfileSyncRecoveryDecision] {
    recoveryDecisions
  }
}

private actor RecordingProfileSync: ProfileSyncing {
  private var currentStatus: ProfileSyncStatus
  private var snapshots: [ProfileSyncSnapshot] = []

  init(status: ProfileSyncStatus) {
    currentStatus = status
  }

  func status() -> ProfileSyncStatus {
    currentStatus
  }

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    snapshots.append(snapshot)
    return currentStatus
  }

  func synchronize() -> ProfileSyncExchange {
    .noChanges
  }

  func resolveRecovery(
    _ decision: ProfileSyncRecoveryDecision,
    localSnapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    switch decision {
    case .keepLocalOnly:
      currentStatus = .localOnly
    case .resumeCloudSyncUsingLocalProfiles:
      snapshots.append(localSnapshot)
      currentStatus = .available
    }
    return currentStatus
  }

  func cancel() {}

  func stagedSnapshots() -> [ProfileSyncSnapshot] {
    snapshots
  }
}

private actor NoopProfileSyncStateStore: ProfileSyncStateStoring {
  func loadCandidates() -> ProfileSyncStateCandidates {
    ProfileSyncStateCandidates(primary: nil, backup: nil)
  }

  func restoreBackup() {}

  func save(_ state: Data) {}

  func clear() {}
}

private struct FailingProfileSyncPreferenceStore:
  ProfileSyncPreferenceStoring
{
  func isCloudSyncDisabled() -> Bool {
    false
  }

  func setCloudSyncDisabled(_ isDisabled: Bool) throws {
    throw PreferenceStoreTestError.writeFailed
  }
}

private enum PreferenceStoreTestError: Error {
  case writeFailed
}
