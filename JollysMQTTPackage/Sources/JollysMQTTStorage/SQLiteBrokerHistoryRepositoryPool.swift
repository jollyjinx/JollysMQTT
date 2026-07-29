import Foundation
import Synchronization

public final class SQLiteBrokerHistoryRepositoryPool: Sendable {
  private let directoryURL: URL
  private let filePolicy: any HistoryFilePolicy
  private let repositories = Mutex<[UUID: SQLiteBrokerHistoryWriter]>([:])

  public init(
    directoryURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy()
  ) {
    self.directoryURL = directoryURL
    self.filePolicy = filePolicy
  }

  public func repository(
    for brokerID: UUID
  ) -> SQLiteBrokerHistoryWriter {
    repositories.withLock { repositories in
      if let repository = repositories[brokerID] {
        return repository
      }
      let repository = SQLiteBrokerHistoryWriter(
        databaseURL: directoryURL.appending(
          path: "\(brokerID.uuidString.lowercased()).sqlite3"
        ),
        filePolicy: filePolicy
      )
      repositories[brokerID] = repository
      return repository
    }
  }
}
