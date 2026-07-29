import Foundation
import JollysMQTTCore
import Synchronization

public final class SQLiteBrokerHistoryRepositoryPool: Sendable {
  private let directoryURL: URL
  private let filePolicy: any HistoryFilePolicy
  private let retentionPolicyProvider: @Sendable (UUID) -> HistoryRetentionPolicy
  private let repositories = Mutex<[UUID: SQLiteBrokerHistoryWriter]>([:])

  public init(
    directoryURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy(),
    retentionPolicyProvider:
      @escaping @Sendable (UUID) -> HistoryRetentionPolicy = { _ in
        .default
      }
  ) {
    self.directoryURL = directoryURL
    self.filePolicy = filePolicy
    self.retentionPolicyProvider = retentionPolicyProvider
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
        filePolicy: filePolicy,
        retentionPolicyProvider: {
          self.retentionPolicyProvider(brokerID)
        }
      )
      repositories[brokerID] = repository
      return repository
    }
  }
}
