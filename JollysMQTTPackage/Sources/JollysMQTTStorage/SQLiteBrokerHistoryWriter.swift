import Foundation
import JollysMQTTCore

public actor SQLiteBrokerHistoryWriter: BrokerHistoryWriting {
  private let databaseURL: URL
  private let filePolicy: any HistoryFilePolicy
  private var store: SQLiteHistoryStore?
  private var isShutdown = false

  public init(
    databaseURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy()
  ) {
    self.databaseURL = databaseURL
    self.filePolicy = filePolicy
  }

  public func append(_ messages: [BrokerHistoryMessage]) async throws {
    guard !isShutdown, !messages.isEmpty else { return }
    let store = try await openStore()
    _ = try await store.append(
      messages.map {
        HistoryMessageInput(
          historySourceID: $0.historySourceID,
          connectionEpoch: $0.connectionEpoch.rawValue,
          connectionOrdinal: $0.ordinal,
          topic: $0.topic,
          receivedAtMicroseconds: $0.receivedAtMicroseconds,
          payload: $0.payload
        )
      }
    )
  }

  public func shutdown() async throws {
    guard !isShutdown else { return }
    isShutdown = true
    if let store {
      _ = try await store.checkpoint(.truncate)
      try await store.refreshFilePolicy()
    }
    store = nil
  }

  private func openStore() async throws -> SQLiteHistoryStore {
    if let store {
      return store
    }
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let opened = try await SQLiteHistoryStore.open(
      databaseURL: databaseURL,
      filePolicy: filePolicy
    )
    store = opened
    return opened
  }
}
