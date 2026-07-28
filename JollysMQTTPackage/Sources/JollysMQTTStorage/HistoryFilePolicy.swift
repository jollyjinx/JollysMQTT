import Foundation

public enum HistoryFileRole: String, CaseIterable, Sendable {
  case database
  case writeAheadLog
  case sharedMemory

  public func url(for databaseURL: URL) -> URL {
    switch self {
    case .database:
      databaseURL
    case .writeAheadLog:
      URL(filePath: databaseURL.path + "-wal")
    case .sharedMemory:
      URL(filePath: databaseURL.path + "-shm")
    }
  }
}

public protocol HistoryFilePolicy: Sendable {
  func apply(to url: URL, role: HistoryFileRole) async throws
}

public struct SystemHistoryFilePolicy: HistoryFilePolicy {
  public init() {}

  public func apply(to url: URL, role: HistoryFileRole) async throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }

    var mutableURL = url
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try mutableURL.setResourceValues(resourceValues)

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
