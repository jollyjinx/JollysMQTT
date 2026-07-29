import Foundation
import JollysMQTTStorage

public enum ProfileSyncBuildSelection: Equatable, Sendable {
  public static let modeKey = "JollysMQTTProfileSyncMode"
  public static let containerIdentifierKey =
    "JollysMQTTCloudKitContainerIdentifier"
  public static let zoneNameKey = "JollysMQTTCloudKitZoneName"

  case localOnly
  case cloudKit(CloudKitProfileSyncConfiguration)

  public init(values: [String: String]) {
    guard values[Self.modeKey] == "cloudKit",
      let containerIdentifier = values[
        Self.containerIdentifierKey
      ]?.trimmingCharacters(in: .whitespacesAndNewlines),
      containerIdentifier.hasPrefix("iCloud."),
      containerIdentifier.count > "iCloud.".count,
      let zoneName = values[
        Self.zoneNameKey
      ]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !zoneName.isEmpty
    else {
      self = .localOnly
      return
    }
    self = .cloudKit(
      CloudKitProfileSyncConfiguration(
        containerIdentifier: containerIdentifier,
        zoneName: zoneName
      )
    )
  }

  public static func current(
    bundle: Bundle = .main
  ) -> ProfileSyncBuildSelection {
    var values: [String: String] = [:]
    for key in [
      modeKey,
      containerIdentifierKey,
      zoneNameKey,
    ] {
      if let value = bundle.object(
        forInfoDictionaryKey: key
      ) as? String {
        values[key] = value
      }
    }
    return ProfileSyncBuildSelection(values: values)
  }
}

protocol ProfileSyncPreferenceStoring: Sendable {
  func isCloudSyncDisabled() async -> Bool
  func setCloudSyncDisabled(_ isDisabled: Bool) async throws
}

actor LocalProfileSyncPreferenceStore:
  ProfileSyncPreferenceStoring
{
  private struct Document: Codable {
    let version: Int
    let isCloudSyncDisabled: Bool
  }

  private let fileURL: URL
  private let fileManager: FileManager
  private let filePolicy: any ProfileSyncStateFilePolicy

  init(
    fileURL: URL,
    fileManager: FileManager = .default,
    filePolicy: any ProfileSyncStateFilePolicy =
      SystemProfileSyncStateFilePolicy()
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.filePolicy = filePolicy
  }

  func isCloudSyncDisabled() -> Bool {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return false
    }
    guard
      let data = try? Data(contentsOf: fileURL),
      let document = try? JSONDecoder().decode(
        Document.self,
        from: data
      ),
      document.version == 1
    else {
      // A damaged preference must never silently turn remote sync back on.
      return true
    }
    return document.isCloudSyncDisabled
  }

  func setCloudSyncDisabled(_ isDisabled: Bool) async throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let document = Document(
      version: 1,
      isCloudSyncDisabled: isDisabled
    )
    let data = try JSONEncoder().encode(document)
    try data.write(to: fileURL, options: .atomic)
    try await filePolicy.apply(to: fileURL, role: .primary)
  }
}

actor ProvisionedProfileSync: ProfileSyncing {
  private enum Source: Sendable {
    case localOnly
    case adapter(any ProfileSyncing)
    case cloudKit(
      CloudKitProfileSyncConfiguration,
      any ProfileSyncStateStoring
    )
  }

  private let source: Source
  private let preferenceStore: any ProfileSyncPreferenceStoring
  private var resolved: (any ProfileSyncing)?
  private var cachedCloudSyncDisabled: Bool?
  private var sessionCloudSyncDisabled = false
  private var preferenceSaveFailed = false

  init(
    selection: ProfileSyncBuildSelection,
    stateStore: any ProfileSyncStateStoring,
    preferenceStore: any ProfileSyncPreferenceStoring
  ) {
    self.preferenceStore = preferenceStore
    switch selection {
    case .localOnly:
      source = .localOnly
    case .cloudKit(let configuration):
      source = .cloudKit(configuration, stateStore)
    }
  }

  init(
    adapter: any ProfileSyncing,
    preferenceStore: any ProfileSyncPreferenceStoring
  ) {
    self.source = .adapter(adapter)
    self.preferenceStore = preferenceStore
  }

  func status() async -> ProfileSyncStatus {
    guard hasCloudSyncSource else {
      return .localOnly
    }
    if preferenceSaveFailed {
      return .cloudSyncPreferenceSaveFailed
    }
    guard !(await isCloudSyncDisabled()) else {
      return .cloudSyncDisabled
    }
    return await adapter().status()
  }

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) async -> ProfileSyncStatus {
    guard hasCloudSyncSource else {
      return .localOnly
    }
    if preferenceSaveFailed {
      return .cloudSyncPreferenceSaveFailed
    }
    guard !(await isCloudSyncDisabled()) else {
      return .cloudSyncDisabled
    }
    return await adapter().stageLocalProfiles(snapshot)
  }

  func synchronize() async throws -> ProfileSyncExchange {
    guard hasCloudSyncSource else {
      return .noChanges
    }
    guard !(await isCloudSyncDisabled()) else {
      return .noChanges
    }
    return try await adapter().synchronize()
  }

  func resolveRecovery(
    _ decision: ProfileSyncRecoveryDecision,
    localSnapshot: ProfileSyncSnapshot
  ) async -> ProfileSyncStatus {
    guard hasCloudSyncSource else {
      return .localOnly
    }
    switch decision {
    case .keepLocalOnly:
      sessionCloudSyncDisabled = true
      cachedCloudSyncDisabled = true
      if let resolved {
        _ = await resolved.resolveRecovery(
          decision,
          localSnapshot: localSnapshot
        )
      }
      do {
        try await preferenceStore.setCloudSyncDisabled(true)
        preferenceSaveFailed = false
      } catch {
        preferenceSaveFailed = true
        return .cloudSyncPreferenceSaveFailed
      }
      return .cloudSyncDisabled
    case .resumeCloudSyncUsingLocalProfiles:
      do {
        try await preferenceStore.setCloudSyncDisabled(false)
      } catch {
        preferenceSaveFailed = true
        return .cloudSyncPreferenceSaveFailed
      }
      sessionCloudSyncDisabled = false
      cachedCloudSyncDisabled = false
      preferenceSaveFailed = false
      return await adapter().resolveRecovery(
        decision,
        localSnapshot: localSnapshot
      )
    }
  }

  func cancel() async {
    guard hasCloudSyncSource else {
      return
    }
    let cloudSyncDisabled = await isCloudSyncDisabled()
    if preferenceSaveFailed || cloudSyncDisabled {
      if let resolved {
        await resolved.cancel()
      }
      return
    }
    await adapter().cancel()
  }

  private func adapter() async -> any ProfileSyncing {
    if let resolved {
      return resolved
    }
    let adapter: any ProfileSyncing
    switch source {
    case .localOnly:
      adapter = LocalOnlyProfileSync()
    case .adapter(let supplied):
      adapter = supplied
    case .cloudKit(let configuration, let stateStore):
      do {
        adapter = try await CloudKitProfileSync.configured(
          configuration,
          stateStore: stateStore
        )
      } catch {
        adapter = UnavailableProfileSync()
      }
    }
    resolved = adapter
    return adapter
  }

  private func isCloudSyncDisabled() async -> Bool {
    if sessionCloudSyncDisabled {
      return true
    }
    if let cachedCloudSyncDisabled {
      return cachedCloudSyncDisabled
    }
    let disabled = await preferenceStore.isCloudSyncDisabled()
    cachedCloudSyncDisabled = disabled
    return disabled
  }

  private var hasCloudSyncSource: Bool {
    if case .localOnly = source {
      return false
    }
    return true
  }
}

private actor UnavailableProfileSync: ProfileSyncing {
  private let failure = ProfileSyncFailure(
    kind: .unavailable,
    isRetryable: false
  )
  private var isLocalOnly = false

  func status() -> ProfileSyncStatus {
    isLocalOnly ? .localOnly : .failed(failure)
  }

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    isLocalOnly ? .localOnly : .failed(failure)
  }

  func synchronize() throws -> ProfileSyncExchange {
    if isLocalOnly {
      return ProfileSyncExchange(remoteRecords: [])
    }
    throw failure
  }

  func resolveRecovery(
    _ decision: ProfileSyncRecoveryDecision,
    localSnapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    guard decision == .keepLocalOnly else {
      return .failed(failure)
    }
    isLocalOnly = true
    return .localOnly
  }

  func cancel() {
    isLocalOnly = true
  }
}
