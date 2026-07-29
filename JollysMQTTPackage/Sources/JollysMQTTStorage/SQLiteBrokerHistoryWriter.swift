import Foundation
import JollysMQTTCore

public actor SQLiteBrokerHistoryWriter:
  BrokerHistoryWriting,
  BrokerHistoryReading,
  BrokerHistoryMaintaining
{
  private let databaseURL: URL
  private let filePolicy: any HistoryFilePolicy
  private let retentionPolicyProvider: @Sendable () -> HistoryRetentionPolicy
  private let clearStepHandler: (@Sendable (HistoryClearContinuation) async throws -> Void)?
  private var store: SQLiteHistoryStore?
  private var currentMaintenanceStatus: HistoryMaintenanceStatus = .notRun
  private var isOpening = false
  private var isClosing = false
  private var activeOperationCount = 0
  private var availabilityWaiters: [CheckedContinuation<Void, Never>] = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    databaseURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy(),
    retentionPolicy: HistoryRetentionPolicy = .default
  ) {
    self.databaseURL = databaseURL
    self.filePolicy = filePolicy
    self.retentionPolicyProvider = { retentionPolicy }
    self.clearStepHandler = nil
  }

  public init(
    databaseURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy(),
    retentionPolicyProvider:
      @escaping @Sendable () -> HistoryRetentionPolicy
  ) {
    self.databaseURL = databaseURL
    self.filePolicy = filePolicy
    self.retentionPolicyProvider = retentionPolicyProvider
    self.clearStepHandler = nil
  }

  init(
    databaseURL: URL,
    filePolicy: any HistoryFilePolicy = SystemHistoryFilePolicy(),
    retentionPolicy: HistoryRetentionPolicy,
    clearStepHandler:
      @escaping @Sendable (HistoryClearContinuation) async throws -> Void
  ) {
    self.databaseURL = databaseURL
    self.filePolicy = filePolicy
    self.retentionPolicyProvider = { retentionPolicy }
    self.clearStepHandler = clearStepHandler
  }

  public func append(_ messages: [BrokerHistoryMessage]) async throws {
    guard !messages.isEmpty else { return }
    let policy = retentionPolicyProvider()
    let inputs = try validatedInputs(messages, policy: policy)
    try Task.checkCancellation()
    let store = try await acquireStore()
    do {
      let before = try await store.diagnostics()
      if before.totalSQLiteBytes > policy.brokerPruneHighWaterBytes {
        _ = try await performMaintenance(
          store: store,
          policy: policy
        )
      }
      _ = try await store.append(inputs)
      do {
        currentMaintenanceStatus = .succeeded(
          try await performMaintenance(
            store: store,
            policy: policy
          )
        )
      } catch is CancellationError {
        currentMaintenanceStatus = .cancelled
      } catch {
        // The append is already committed. Maintenance failure must not be
        // reported as message loss to the feed.
        currentMaintenanceStatus = .failed
      }
      finishOperation()
    } catch {
      finishOperation()
      throw error
    }
  }

  public func retentionPolicy() -> HistoryRetentionPolicy {
    retentionPolicyProvider()
  }

  public func maintenanceStatus() -> HistoryMaintenanceStatus {
    currentMaintenanceStatus
  }

  public func applyRetention() async throws -> HistoryMaintenanceReport {
    let store = try await acquireStore()
    do {
      let report = try await performMaintenance(
        store: store,
        policy: retentionPolicyProvider()
      )
      currentMaintenanceStatus = .succeeded(report)
      finishOperation()
      return report
    } catch is CancellationError {
      currentMaintenanceStatus = .cancelled
      finishOperation()
      throw CancellationError()
    } catch {
      currentMaintenanceStatus = .failed
      finishOperation()
      throw error
    }
  }

  public func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) async throws -> HistoryClearOutcome {
    let store = try await acquireStore()
    do {
      let scope = try await store.prepareTopicHistoryClear(
        historySourceID: historySourceID,
        topic: topic
      )
      let outcome = try await runTopicClear(
        scope: scope,
        accumulated: .empty,
        store: store
      )
      finishOperation()
      return outcome
    } catch {
      finishOperation()
      throw error
    }
  }

  public func clearBrokerHistory() async throws -> HistoryClearOutcome {
    let store = try await acquireStore()
    do {
      let scope = try await store.prepareBrokerHistoryClear()
      let outcome = try await runBrokerClear(
        scope: scope,
        accumulated: .empty,
        store: store
      )
      finishOperation()
      return outcome
    } catch {
      finishOperation()
      throw error
    }
  }

  public func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) async throws -> HistoryClearOutcome {
    let store = try await acquireStore()
    do {
      let outcome =
        switch continuation {
        case .topic(let scope, let accumulated):
          try await runTopicClear(
            scope: scope,
            accumulated: accumulated,
            store: store
          )
        case .broker(let scope, let accumulated):
          try await runBrokerClear(
            scope: scope,
            accumulated: accumulated,
            store: store
          )
        }
      finishOperation()
      return outcome
    } catch {
      finishOperation()
      throw error
    }
  }

  public func retrySecureCleanup() async throws {
    let store = try await acquireStore()
    do {
      try await store.finalizeHistoryClear(
        vacuumPageLimit: retentionPolicyProvider().vacuumPageLimit
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

  public func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) async throws -> NumericChartHistoryResult {
    let store = try await acquireStore()
    do {
      let history = try await store.numericChartHistory(request)
      finishOperation()
      return history
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
        do {
          currentMaintenanceStatus = .succeeded(
            try await performMaintenance(
              store: store,
              policy: retentionPolicyProvider()
            )
          )
        } catch is CancellationError {
          currentMaintenanceStatus = .cancelled
        } catch {
          currentMaintenanceStatus = .failed
          throw error
        }
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

  private func validatedInputs(
    _ messages: [BrokerHistoryMessage],
    policy: HistoryRetentionPolicy
  ) throws -> [HistoryMessageInput] {
    guard
      messages.count <= HistoryRetentionPolicy.maximumAppendMessageCount
    else {
      throw HistoryStorageError.invalidAppendBatch(
        messageCount: messages.count,
        payloadBytes: 0,
        maximumMessageCount:
          HistoryRetentionPolicy.maximumAppendMessageCount,
        maximumPayloadBytes: policy.maximumAppendPayloadBytes
      )
    }
    // Validate the entire batch before deciding payload storage so a malformed
    // later row cannot partially commit valid earlier rows.
    for (index, message) in messages.enumerated() {
      let reason: InvalidHistoryMessageReason?
      if message.historySourceID.isEmpty {
        reason = .emptyHistorySourceID
      } else if message.topic.isEmpty {
        reason = .emptyTopic
      } else if message.historySourceID.contains("\0")
        || message.topic.contains("\0")
      {
        reason = .containsNullCharacter
      } else {
        reason = nil
      }
      if let reason {
        throw HistoryStorageError.invalidMessage(
          index: index,
          reason: reason
        )
      }
    }

    // A settings change may race an already-buffered batch. Preserve every
    // message's metadata and preferentially retain the newest payloads that
    // fit the policy snapshot instead of rejecting the batch and reporting a
    // false coverage gap.
    var remainingPayloadBytes = policy.maximumAppendPayloadBytes
    var storesPayload = Array(repeating: false, count: messages.count)
    for index in messages.indices.reversed() {
      let byteCount = Int64(messages[index].payload.count)
      if byteCount <= Int64(policy.payloadByteLimit),
        byteCount <= remainingPayloadBytes
      {
        storesPayload[index] = true
        remainingPayloadBytes -= byteCount
      }
    }

    var inputs: [HistoryMessageInput] = []
    inputs.reserveCapacity(messages.count)
    for (index, message) in messages.enumerated() {
      let storesPayload = storesPayload[index]
      inputs.append(
        HistoryMessageInput(
          historySourceID: message.historySourceID,
          connectionEpoch: message.connectionEpoch?.rawValue,
          connectionOrdinal: message.ordinal,
          operationID: message.operationID,
          direction: message.direction,
          topic: message.topic,
          qos: message.qos,
          retained: message.retained,
          receivedAtMicroseconds: message.receivedAtMicroseconds,
          payload: storesPayload ? message.payload : Data(),
          payloadStorage:
            storesPayload
            ? .stored
            : .omittedByRetentionLimit(
              originalByteCount: message.payload.count
            )
        )
      )
    }
    return inputs
  }

  private func runTopicClear(
    scope: HistoryTopicClearScope,
    accumulated: HistoryClearSummary,
    store: SQLiteHistoryStore
  ) async throws -> HistoryClearOutcome {
    let policy = retentionPolicyProvider()
    var summary = accumulated
    var committedStep = false
    do {
      while true {
        try Task.checkCancellation()
        let step = try await store.clearTopicHistory(
          scope,
          batchLimit: policy.messagePruneBatchLimit,
          vacuumPageLimit: policy.vacuumPageLimit
        )
        committedStep = true
        summary = summary.adding(
          messages: step.deletedMessageCount,
          topics: step.deletedTopicCount,
          coverageGaps: 0,
          secureCleanupStatus: step.secureCleanupStatus
        )
        guard step.requiresMoreWork else {
          return HistoryClearOutcome(summary: summary)
        }
        try await clearStepHandler?(
          .topic(scope: scope, accumulated: summary)
        )
      }
    } catch {
      guard committedStep || accumulated.hasDeletedRows else {
        throw error
      }
      let interruption: HistoryClearInterruption =
        error is CancellationError ? .cancelled : .storageFailure
      let continuation = HistoryClearContinuation.topic(
        scope: scope,
        accumulated: summary
      )
      return HistoryClearOutcome(
        summary: summary,
        continuation: continuation,
        interruption: interruption
      )
    }
  }

  private func runBrokerClear(
    scope: HistoryBrokerClearScope,
    accumulated: HistoryClearSummary,
    store: SQLiteHistoryStore
  ) async throws -> HistoryClearOutcome {
    let policy = retentionPolicyProvider()
    var summary = accumulated
    var committedStep = false
    do {
      while true {
        try Task.checkCancellation()
        let step = try await store.clearBrokerHistory(
          scope,
          batchLimit: policy.messagePruneBatchLimit,
          vacuumPageLimit: policy.vacuumPageLimit
        )
        committedStep = true
        summary = summary.adding(
          messages: step.deletedMessageCount,
          topics: step.deletedTopicCount,
          coverageGaps: step.deletedCoverageGapCount,
          secureCleanupStatus: step.secureCleanupStatus
        )
        guard step.requiresMoreWork else {
          return HistoryClearOutcome(summary: summary)
        }
        try await clearStepHandler?(
          .broker(scope: scope, accumulated: summary)
        )
      }
    } catch {
      guard committedStep || accumulated.hasDeletedRows else {
        throw error
      }
      let interruption: HistoryClearInterruption =
        error is CancellationError ? .cancelled : .storageFailure
      let continuation = HistoryClearContinuation.broker(
        scope: scope,
        accumulated: summary
      )
      return HistoryClearOutcome(
        summary: summary,
        continuation: continuation,
        interruption: interruption
      )
    }
  }

  private func performMaintenance(
    store: SQLiteHistoryStore,
    policy: HistoryRetentionPolicy
  ) async throws -> HistoryMaintenanceReport {
    let initial = try await store.diagnostics()
    let messageSteps =
      (initial.messageCount + policy.messagePruneBatchLimit - 1)
      / policy.messagePruneBatchLimit
    let topicSteps =
      (initial.topicCount + policy.messagePruneBatchLimit - 1)
      / policy.messagePruneBatchLimit
    let vacuumSteps =
      (initial.freePageCount + policy.vacuumPageLimit - 1)
      / policy.vacuumPageLimit
    let stepLimit = max(
      16,
      messageSteps * 2 + topicSteps + vacuumSteps + 16
    )
    var steps = 0
    var deletedForTopicLimit = 0
    while true {
      try Task.checkCancellation()
      guard steps < stepLimit else {
        throw HistoryStorageError.maintenanceDidNotConverge(
          stepLimit: stepLimit
        )
      }
      steps += 1
      let step = try await store.prune(
        keepingNewestPerTopic: policy.topicMessageLimit,
        batchLimit: policy.messagePruneBatchLimit
      )
      deletedForTopicLimit += step.deletedCount
      if step.deletedCount == 0 {
        break
      }
    }

    var deletedForBrokerLimit = 0
    var deletedOrphanTopics = 0
    var diagnostics = try await store.diagnostics()
    if diagnostics.totalSQLiteBytes > policy.brokerPruneHighWaterBytes {
      while diagnostics.totalSQLiteBytes > policy.brokerPruneTargetBytes {
        try Task.checkCancellation()
        guard steps < stepLimit else {
          throw HistoryStorageError.maintenanceDidNotConverge(
            stepLimit: stepLimit
          )
        }
        steps += 1
        let step = try await store.pruneToMaximumBytes(
          policy.brokerPruneTargetBytes,
          batchLimit: policy.messagePruneBatchLimit,
          vacuumPageLimit: policy.vacuumPageLimit
        )
        deletedForBrokerLimit += step.deletedCount
        deletedOrphanTopics += step.deletedTopicCount
        diagnostics = try await store.diagnostics()
        if step.targetReached {
          break
        }
        guard step.requiresMorePruning else {
          throw HistoryStorageError.maintenanceDidNotConverge(
            stepLimit: stepLimit
          )
        }
      }
    }
    return HistoryMaintenanceReport(
      deletedForTopicLimit: deletedForTopicLimit,
      deletedForBrokerLimit: deletedForBrokerLimit,
      deletedOrphanTopicCount: deletedOrphanTopics,
      finalMessageCount: diagnostics.messageCount,
      finalSQLiteBytes: diagnostics.totalSQLiteBytes
    )
  }
}

extension HistoryClearSummary {
  fileprivate static let empty = HistoryClearSummary(
    deletedMessageCount: 0,
    deletedTopicCount: 0,
    deletedCoverageGapCount: 0,
    secureCleanupStatus: .notRequired
  )

  fileprivate var hasDeletedRows: Bool {
    deletedMessageCount > 0
      || deletedTopicCount > 0
      || deletedCoverageGapCount > 0
  }

  fileprivate func adding(
    messages: Int,
    topics: Int,
    coverageGaps: Int,
    secureCleanupStatus newCleanupStatus: HistorySecureCleanupStatus
  ) -> HistoryClearSummary {
    HistoryClearSummary(
      deletedMessageCount: deletedMessageCount + messages,
      deletedTopicCount: deletedTopicCount + topics,
      deletedCoverageGapCount: deletedCoverageGapCount + coverageGaps,
      secureCleanupStatus:
        newCleanupStatus == .notRequired
        ? secureCleanupStatus : newCleanupStatus
    )
  }
}
