import Foundation

public struct ProfileSyncStateCandidates: Equatable, Sendable {
  public let primary: Data?
  public let backup: Data?

  public init(primary: Data?, backup: Data?) {
    self.primary = primary
    self.backup = backup
  }
}

public protocol ProfileSyncStateStoring: Sendable {
  func loadCandidates() async throws -> ProfileSyncStateCandidates
  func restoreBackup() async throws
  func save(_ state: Data) async throws
  func clear() async throws
}

public enum ProfileSyncStateFileRole: Sendable {
  case primary
  case backup
}

public protocol ProfileSyncStateFilePolicy: Sendable {
  func apply(
    to url: URL,
    role: ProfileSyncStateFileRole
  ) async throws
}

public struct SystemProfileSyncStateFilePolicy:
  ProfileSyncStateFilePolicy
{
  public init() {}

  public func apply(
    to url: URL,
    role: ProfileSyncStateFileRole
  ) async throws {
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

/// Atomic persistence for CKSyncEngine's opaque serialization. The store does
/// not inspect or expose CloudKit's state type.
public actor LocalProfileSyncStateStore: ProfileSyncStateStoring {
  public let fileURL: URL
  public let backupURL: URL

  private let fileManager: FileManager
  private let filePolicy: any ProfileSyncStateFilePolicy

  public init(
    fileURL: URL,
    fileManager: FileManager = .default,
    filePolicy: any ProfileSyncStateFilePolicy =
      SystemProfileSyncStateFilePolicy()
  ) {
    self.fileURL = fileURL
    self.backupURL = fileURL.appendingPathExtension("backup")
    self.fileManager = fileManager
    self.filePolicy = filePolicy
  }

  public func loadCandidates() async throws -> ProfileSyncStateCandidates {
    let primary =
      fileManager.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    let backup =
      fileManager.fileExists(atPath: backupURL.path)
      ? try Data(contentsOf: backupURL)
      : nil
    if primary != nil {
      try await filePolicy.apply(to: fileURL, role: .primary)
    }
    if backup != nil {
      try await filePolicy.apply(to: backupURL, role: .backup)
    }
    return ProfileSyncStateCandidates(
      primary: primary,
      backup: backup
    )
  }

  public func save(_ state: Data) async throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    var wroteBackup = false
    if fileManager.fileExists(atPath: fileURL.path) {
      let prior = try Data(contentsOf: fileURL)
      try prior.write(to: backupURL, options: [.atomic])
      wroteBackup = true
    } else if !fileManager.fileExists(atPath: backupURL.path) {
      try state.write(to: backupURL, options: [.atomic])
      wroteBackup = true
    }
    try state.write(to: fileURL, options: [.atomic])

    if wroteBackup {
      try await filePolicy.apply(to: backupURL, role: .backup)
    }
    try await filePolicy.apply(to: fileURL, role: .primary)
  }

  public func restoreBackup() async throws {
    guard fileManager.fileExists(atPath: backupURL.path) else {
      return
    }
    let backup = try Data(contentsOf: backupURL)
    try backup.write(to: fileURL, options: [.atomic])
    try await filePolicy.apply(to: fileURL, role: .primary)
    try await filePolicy.apply(to: backupURL, role: .backup)
  }

  public func clear() async throws {
    for url in [fileURL, backupURL]
    where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }
}

struct ProfileSyncStateSelection<State: Sendable>: Sendable {
  let state: State?
  let usedBackup: Bool
}

func selectProfileSyncState<State: Sendable>(
  from candidates: ProfileSyncStateCandidates,
  decode: (Data) -> State?
) -> ProfileSyncStateSelection<State> {
  if let primary = candidates.primary,
    let state = decode(primary)
  {
    return ProfileSyncStateSelection(
      state: state,
      usedBackup: false
    )
  }
  if let backup = candidates.backup,
    let state = decode(backup)
  {
    return ProfileSyncStateSelection(
      state: state,
      usedBackup: true
    )
  }
  return ProfileSyncStateSelection(
    state: nil,
    usedBackup: false
  )
}
