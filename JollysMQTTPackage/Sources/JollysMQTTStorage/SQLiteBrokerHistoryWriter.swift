import Foundation
import JollysMQTTCore

public actor SQLiteBrokerHistoryWriter:
  BrokerHistoryWriting,
  BrokerHistoryReading
{
  private let databaseURL: URL
  private let filePolicy: any HistoryFilePolicy
  private var store: SQLiteHistoryStore?
  private var isOpening = false
  private var isClosing = false
  private var activeOperationCount = 0
  private var availabilityWaiters: [CheckedContinuation<Void, Never>] = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    databaseURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy()
  ) {
    self.databaseURL = databaseURL
    self.filePolicy = filePolicy
  }

  public func append(_ messages: [BrokerHistoryMessage]) async throws {
    guard !messages.isEmpty else { return }
    let store = try await acquireStore()
    do {
      _ = try await store.append(
        messages.map {
          HistoryMessageInput(
            historySourceID: $0.historySourceID,
            connectionEpoch: $0.connectionEpoch?.rawValue,
            connectionOrdinal: $0.ordinal,
            operationID: $0.operationID,
            direction: $0.direction,
            topic: $0.topic,
            qos: $0.qos,
            retained: $0.retained,
            receivedAtMicroseconds: $0.receivedAtMicroseconds,
            payload: $0.payload
          )
        }
      )
      finishOperation()
    } catch {
      finishOperation()
      throw error
    }
  }

  public func recordCoverageGap(
    _ gap: BrokerHistoryCoverageGap
  ) async throws {
    let store = try await acquireStore()
    do {
      _ = try await store.recordCoverageGap(
        HistoryCoverageGapInput(
          historySourceID: gap.historySourceID,
          connectionEpoch: gap.connectionEpoch?.rawValue,
          startedAtMicroseconds: gap.startedAtMicroseconds,
          endedAtMicroseconds: gap.endedAtMicroseconds,
          minimumMissingMessageCount:
            gap.minimumMissingMessageCount,
          reason: gap.reason,
          isOpenEnded: gap.isOpenEnded
        )
      )
      finishOperation()
    } catch {
      finishOperation()
      throw error
    }
  }

  public func page(_ request: HistoryPageRequest) async throws -> HistoryPage {
    let store = try await acquireStore()
    do {
      let page = try await store.page(request)
      finishOperation()
      return page
    } catch {
      finishOperation()
      throw error
    }
  }

  public func shutdown() async throws {
    while isClosing {
      await waitUntilAvailable()
    }
    isClosing = true
    while activeOperationCount > 0 {
      await waitUntilIdle()
    }
    do {
      if let store {
        _ = try await store.checkpoint(.truncate)
        try await store.refreshFilePolicy()
      }
      finishClosing()
    } catch {
      finishClosing()
      throw error
    }
  }

  private func finishClosing() {
    store = nil
    isClosing = false
    resumeAvailabilityWaiters()
  }

  private func acquireStore() async throws -> SQLiteHistoryStore {
    while isClosing || isOpening {
      await waitUntilAvailable()
    }
    activeOperationCount += 1
    if let store {
      return store
    }
    isOpening = true
    do {
      try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let opened = try await SQLiteHistoryStore.open(
        databaseURL: databaseURL,
        filePolicy: filePolicy
      )
      store = opened
      isOpening = false
      resumeAvailabilityWaiters()
      return opened
    } catch {
      isOpening = false
      finishOperation()
      resumeAvailabilityWaiters()
      throw error
    }
  }

  private func finishOperation() {
    precondition(activeOperationCount > 0)
    activeOperationCount -= 1
    if activeOperationCount == 0 {
      let waiters = idleWaiters
      idleWaiters.removeAll(keepingCapacity: true)
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  private func waitUntilAvailable() async {
    await withCheckedContinuation { continuation in
      availabilityWaiters.append(continuation)
    }
  }

  private func waitUntilIdle() async {
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }

  private func resumeAvailabilityWaiters() {
    let waiters = availabilityWaiters
    availabilityWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters {
      waiter.resume()
    }
  }
}
