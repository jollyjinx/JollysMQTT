import Foundation

public struct ConnectionEpochID: Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

public struct BrokerInboundMessage: Equatable, Sendable {
  public let connectionEpoch: ConnectionEpochID
  public let ordinal: UInt64
  public let topic: String
  public let payload: Data
  public let qos: MQTTQualityOfService
  public let retained: Bool
  public let duplicate: Bool
  public let receivedAtMicroseconds: Int64

  public init(
    connectionEpoch: ConnectionEpochID,
    ordinal: UInt64,
    topic: String,
    payload: Data,
    qos: MQTTQualityOfService,
    retained: Bool,
    duplicate: Bool,
    receivedAtMicroseconds: Int64
  ) {
    self.connectionEpoch = connectionEpoch
    self.ordinal = ordinal
    self.topic = topic
    self.payload = payload
    self.qos = qos
    self.retained = retained
    self.duplicate = duplicate
    self.receivedAtMicroseconds = receivedAtMicroseconds
  }
}

public struct BrokerHistoryMessage: Equatable, Sendable {
  public let historySourceID: String
  public let connectionEpoch: ConnectionEpochID
  public let ordinal: UInt64
  public let topic: String
  public let payload: Data
  public let receivedAtMicroseconds: Int64

  public init(
    historySourceID: String,
    connectionEpoch: ConnectionEpochID,
    ordinal: UInt64,
    topic: String,
    payload: Data,
    receivedAtMicroseconds: Int64
  ) {
    self.historySourceID = historySourceID
    self.connectionEpoch = connectionEpoch
    self.ordinal = ordinal
    self.topic = topic
    self.payload = payload
    self.receivedAtMicroseconds = receivedAtMicroseconds
  }
}

public enum BrokerHistoryCoverageGapReason:
  String,
  Codable,
  Equatable,
  Sendable
{
  case storageFailure
  case localOverload
}

public struct BrokerHistoryCoverageGap: Equatable, Sendable {
  public let historySourceID: String
  public let connectionEpoch: ConnectionEpochID?
  public let startedAtMicroseconds: Int64
  public let endedAtMicroseconds: Int64?
  public let minimumMissingMessageCount: Int
  public let reason: BrokerHistoryCoverageGapReason
  public let isOpenEnded: Bool

  public init(
    historySourceID: String,
    connectionEpoch: ConnectionEpochID?,
    startedAtMicroseconds: Int64,
    endedAtMicroseconds: Int64?,
    minimumMissingMessageCount: Int,
    reason: BrokerHistoryCoverageGapReason,
    isOpenEnded: Bool
  ) {
    precondition(minimumMissingMessageCount > 0)
    precondition(
      endedAtMicroseconds.map { $0 >= startedAtMicroseconds } ?? true
    )
    self.historySourceID = historySourceID
    self.connectionEpoch = connectionEpoch
    self.startedAtMicroseconds = startedAtMicroseconds
    self.endedAtMicroseconds = endedAtMicroseconds
    self.minimumMissingMessageCount = minimumMissingMessageCount
    self.reason = reason
    self.isOpenEnded = isOpenEnded
  }
}

public protocol BrokerHistoryWriting: Sendable {
  func append(_ messages: [BrokerHistoryMessage]) async throws
  func recordCoverageGap(_ gap: BrokerHistoryCoverageGap) async throws
  func shutdown() async throws
}

public actor DisabledBrokerHistoryWriter: BrokerHistoryWriting {
  public init() {}

  public func append(_ messages: [BrokerHistoryMessage]) {}
  public func recordCoverageGap(_ gap: BrokerHistoryCoverageGap) {}
  public func shutdown() {}
}

public struct BrokerTopicID: Hashable, Sendable {
  public let brokerID: UUID
  public let fullTopic: String

  public init(brokerID: UUID, fullTopic: String) {
    self.brokerID = brokerID
    self.fullTopic = fullTopic
  }
}

public struct BrokerTopicLatestValue: Equatable, Sendable {
  public let connectionEpoch: ConnectionEpochID
  public let ordinal: UInt64
  public let topic: String
  public let payload: Data
  public let qos: MQTTQualityOfService
  public let retained: Bool
  public let duplicate: Bool
  public let receivedAtMicroseconds: Int64

  init(_ message: BrokerInboundMessage) {
    connectionEpoch = message.connectionEpoch
    ordinal = message.ordinal
    topic = message.topic
    payload = message.payload
    qos = message.qos
    retained = message.retained
    duplicate = message.duplicate
    receivedAtMicroseconds = message.receivedAtMicroseconds
  }
}

public struct BrokerTopicPayloadSummary: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case scalar
    case json
  }

  public let kind: Kind
  public let display: String
  public let foldedSearchText: String
  public let isTruncated: Bool

  fileprivate init(
    kind: Kind,
    display: String,
    foldedSearchText: String,
    isTruncated: Bool
  ) {
    self.kind = kind
    self.display = display
    self.foldedSearchText = foldedSearchText
    self.isTruncated = isTruncated
  }
}

private struct BrokerTopicSnapshotRecord: Sendable {
  let id: BrokerTopicID
  let level: String
  let fullTopic: String
  let foldedFullTopicSearchText: String
  let latest: BrokerTopicLatestValue?
  let payloadSummary: BrokerTopicPayloadSummary?
  let messageCount: UInt64
  let subtreeMessageCount: UInt64
  let subtreeValueTopicCount: Int
  let subtreeLatestReceivedAtMicroseconds: Int64?
  let isStale: Bool
  let childIndices: [Int]
}

private final class BrokerTopicSnapshotStorage: Sendable {
  let records: [BrokerTopicSnapshotRecord]

  init(records: [BrokerTopicSnapshotRecord]) {
    self.records = records
  }
}

public struct BrokerTopicNodeSnapshot: Equatable, Identifiable, Sendable {
  private let storage: BrokerTopicSnapshotStorage
  private let index: Int

  public var id: BrokerTopicID { record.id }
  public var level: String { record.level }
  public var fullTopic: String { record.fullTopic }
  public var foldedFullTopicSearchText: String {
    record.foldedFullTopicSearchText
  }
  public var latest: BrokerTopicLatestValue? { record.latest }
  public var payloadSummary: BrokerTopicPayloadSummary? {
    record.payloadSummary
  }
  public var messageCount: UInt64 { record.messageCount }
  public var subtreeMessageCount: UInt64 { record.subtreeMessageCount }
  public var subtreeValueTopicCount: Int { record.subtreeValueTopicCount }
  public var subtreeLatestReceivedAtMicroseconds: Int64? {
    record.subtreeLatestReceivedAtMicroseconds
  }
  public var isStale: Bool { record.isStale }
  public var children: [BrokerTopicNodeSnapshot] {
    record.childIndices.map {
      BrokerTopicNodeSnapshot(storage: storage, index: $0)
    }
  }

  private var record: BrokerTopicSnapshotRecord {
    storage.records[index]
  }

  fileprivate init(storage: BrokerTopicSnapshotStorage, index: Int) {
    self.storage = storage
    self.index = index
  }

  public static func == (
    lhs: BrokerTopicNodeSnapshot,
    rhs: BrokerTopicNodeSnapshot
  ) -> Bool {
    if lhs.storage === rhs.storage, lhs.index == rhs.index {
      return true
    }
    var pending = [(lhs.index, rhs.index)]
    while let (lhsIndex, rhsIndex) = pending.popLast() {
      let lhsRecord = lhs.storage.records[lhsIndex]
      let rhsRecord = rhs.storage.records[rhsIndex]
      guard lhsRecord.id == rhsRecord.id,
        lhsRecord.level == rhsRecord.level,
        lhsRecord.fullTopic == rhsRecord.fullTopic,
        lhsRecord.foldedFullTopicSearchText
          == rhsRecord.foldedFullTopicSearchText,
        lhsRecord.latest == rhsRecord.latest,
        lhsRecord.payloadSummary == rhsRecord.payloadSummary,
        lhsRecord.messageCount == rhsRecord.messageCount,
        lhsRecord.subtreeMessageCount == rhsRecord.subtreeMessageCount,
        lhsRecord.subtreeValueTopicCount
          == rhsRecord.subtreeValueTopicCount,
        lhsRecord.subtreeLatestReceivedAtMicroseconds
          == rhsRecord.subtreeLatestReceivedAtMicroseconds,
        lhsRecord.isStale == rhsRecord.isStale,
        lhsRecord.childIndices.count == rhsRecord.childIndices.count
      else {
        return false
      }
      for offset in lhsRecord.childIndices.indices {
        pending.append(
          (
            lhsRecord.childIndices[offset],
            rhsRecord.childIndices[offset]
          )
        )
      }
    }
    return true
  }
}

public struct BrokerTopicTreeSnapshot: Equatable, Sendable {
  public let revision: UInt64
  public let roots: [BrokerTopicNodeSnapshot]
  public let totalMessageCount: UInt64
  public let valueTopicCount: Int
  public let historyIsHealthy: Bool
  public let unpersistedMessageCount: Int
  public let connectionEpoch: ConnectionEpochID?
  public let activeHistoryGap: BrokerHistoryCoverageGap?

  public var historyDiagnostic: BrokerFeedDiagnostic? {
    historyIsHealthy ? nil : .storageFailure
  }

  public init(
    revision: UInt64,
    roots: [BrokerTopicNodeSnapshot],
    totalMessageCount: UInt64,
    valueTopicCount: Int,
    historyIsHealthy: Bool,
    unpersistedMessageCount: Int,
    connectionEpoch: ConnectionEpochID? = nil,
    activeHistoryGap: BrokerHistoryCoverageGap? = nil
  ) {
    self.revision = revision
    self.roots = roots
    self.totalMessageCount = totalMessageCount
    self.valueTopicCount = valueTopicCount
    self.historyIsHealthy = historyIsHealthy
    self.unpersistedMessageCount = unpersistedMessageCount
    self.connectionEpoch = connectionEpoch
    self.activeHistoryGap = activeHistoryGap
  }

  public static let empty = BrokerTopicTreeSnapshot(
    revision: 0,
    roots: [],
    totalMessageCount: 0,
    valueTopicCount: 0,
    historyIsHealthy: true,
    unpersistedMessageCount: 0,
    connectionEpoch: nil,
    activeHistoryGap: nil
  )
}

public struct BrokerFeedIngestionPolicy: Equatable, Sendable {
  public let historyBatchSize: Int
  public let historyFlushIntervalSeconds: Double
  public let maximumSnapshotRate: Double
  public let maximumPayloadSummaryCharacters: Int

  public init(
    historyBatchSize: Int = 128,
    historyFlushIntervalSeconds: Double = 0.25,
    maximumSnapshotRate: Double = 10,
    maximumPayloadSummaryCharacters: Int = 256
  ) {
    precondition(historyBatchSize > 0)
    precondition(historyFlushIntervalSeconds >= 0)
    precondition(maximumSnapshotRate > 0)
    precondition(maximumPayloadSummaryCharacters > 0)
    self.historyBatchSize = historyBatchSize
    self.historyFlushIntervalSeconds = historyFlushIntervalSeconds
    self.maximumSnapshotRate = maximumSnapshotRate
    self.maximumPayloadSummaryCharacters = maximumPayloadSummaryCharacters
  }
}

public struct BrokerFeedIngestionMetrics: Equatable, Sendable {
  public let snapshotRevision: UInt64
  public let topicNodeCount: Int
  public let retainedPayloadByteCount: Int
  public let pendingHistoryMessageCount: Int
  public let isShutdown: Bool
}

public actor BrokerFeedIngestion {
  private final class Node {
    let level: String
    let fullTopic: String
    let foldedFullTopicSearchText: String
    var latest: BrokerTopicLatestValue?
    var payloadSummary: BrokerTopicPayloadSummary?
    var messageCount: UInt64 = 0
    var subtreeMessageCount: UInt64 = 0
    var subtreeValueTopicCount: Int = 0
    var subtreeLatestReceivedAtMicroseconds: Int64?
    var children: [String: Node] = [:]

    init(level: String, fullTopic: String) {
      self.level = level
      self.fullTopic = fullTopic
      self.foldedFullTopicSearchText = fullTopic.folding(
        options: [
          .caseInsensitive,
          .diacriticInsensitive,
          .widthInsensitive,
        ],
        locale: Locale(identifier: "en_US_POSIX")
      )
    }
  }

  private let brokerID: UUID
  private let historySourceID: String
  private let policy: BrokerFeedIngestionPolicy
  private let clock: BrokerFeedClock
  private let stream: AsyncStream<BrokerTopicTreeSnapshot>
  private let continuation: AsyncStream<BrokerTopicTreeSnapshot>.Continuation

  private var roots: [String: Node] = [:]
  private var historyWriter: (any BrokerHistoryWriting)?
  private var pendingHistory: [BrokerHistoryMessage] = []
  private var historyFlushTask: Task<Void, Never>?
  private var historyFlushWaiters: [CheckedContinuation<Void, Never>] = []
  private var presentationTask: Task<Void, Never>?
  private var revision: UInt64 = 0
  private var totalMessageCount: UInt64 = 0
  private var valueTopicCount = 0
  private var connectionEpoch: ConnectionEpochID?
  private var historyIsHealthy = true
  private var unpersistedMessageCount = 0
  // At most one conservative interval per reason. Repeated failures of the
  // same kind merge, so retries remain bounded without conflating storage
  // failure with transport overload.
  private var pendingHistoryGaps: [BrokerHistoryCoverageGap] = []
  private var isRecoveringHistory = false
  private var historyRecoveryWaiters: [CheckedContinuation<Void, Never>] = []
  private var isFlushingHistory = false
  private var isShutdownRequested = false
  private var isShutdownComplete = false
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    brokerID: UUID,
    historySourceID: String,
    historyWriter: any BrokerHistoryWriting,
    policy: BrokerFeedIngestionPolicy = .init(),
    clock: BrokerFeedClock = .continuous
  ) {
    self.brokerID = brokerID
    self.historySourceID = historySourceID
    self.historyWriter = historyWriter
    self.policy = policy
    self.clock = clock
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerTopicTreeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation.yield(.empty)
  }

  public func snapshots() -> AsyncStream<BrokerTopicTreeSnapshot> {
    stream
  }

  public func beginConnectionEpoch(_ epoch: ConnectionEpochID) {
    guard connectionEpoch != epoch else { return }
    connectionEpoch = epoch
    schedulePresentation()
  }

  public func ingest(_ message: BrokerInboundMessage) async {
    guard !isShutdownRequested else { return }
    if connectionEpoch == nil {
      connectionEpoch = message.connectionEpoch
    }
    insert(message)
    schedulePresentation()
    await waitForHistoryRecoveryIfNeeded()
    if historyIsHealthy {
      pendingHistory.append(
        BrokerHistoryMessage(
          historySourceID: historySourceID,
          connectionEpoch: message.connectionEpoch,
          ordinal: message.ordinal,
          topic: message.topic,
          payload: message.payload,
          receivedAtMicroseconds: message.receivedAtMicroseconds
        )
      )
    } else {
      addMissingHistoryMessage(message)
    }
    schedulePresentation()
    if !historyIsHealthy {
      return
    } else if pendingHistory.count >= policy.historyBatchSize {
      historyFlushTask?.cancel()
      historyFlushTask = nil
      await flushFullHistoryBatch()
    } else {
      scheduleHistoryFlush()
    }
  }

  @discardableResult
  public func flush() async -> BrokerTopicTreeSnapshot {
    if isShutdownRequested {
      await waitForShutdownCompletion()
      return .empty
    }
    presentationTask?.cancel()
    presentationTask = nil
    historyFlushTask?.cancel()
    historyFlushTask = nil
    await forceFlushHistory()
    return publishSnapshot()
  }

  public func shutdown() async {
    if isShutdownComplete {
      return
    }
    if isShutdownRequested {
      await waitForShutdownCompletion()
      return
    }
    isShutdownRequested = true
    presentationTask?.cancel()
    presentationTask = nil
    historyFlushTask?.cancel()
    historyFlushTask = nil
    await acquireHistoryFlush()
    await drainHistory(force: true)
    if let historyWriter {
      try? await historyWriter.shutdown()
    }
    self.historyWriter = nil
    pendingHistory.removeAll(keepingCapacity: false)
    clearTopicTree()
    continuation.finish()
    releaseHistoryFlush()
    isShutdownComplete = true
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  @discardableResult
  public func retryHistoryPersistence(
    recoveredAtMicroseconds: Int64
  ) async -> Bool {
    await acquireHistoryFlush()
    defer { releaseHistoryFlush() }
    guard !historyIsHealthy, !isRecoveringHistory,
      !isShutdownRequested, !pendingHistoryGaps.isEmpty, let historyWriter
    else {
      return historyIsHealthy
    }
    isRecoveringHistory = true
    var succeeded = true
    while let activeHistoryGap = pendingHistoryGaps.first {
      let closedGap = BrokerHistoryCoverageGap(
        historySourceID: activeHistoryGap.historySourceID,
        connectionEpoch: activeHistoryGap.connectionEpoch,
        startedAtMicroseconds: activeHistoryGap.startedAtMicroseconds,
        endedAtMicroseconds:
          activeHistoryGap.isOpenEnded
          ? nil
          : max(
            recoveredAtMicroseconds,
            activeHistoryGap.startedAtMicroseconds
          ),
        minimumMissingMessageCount:
          activeHistoryGap.minimumMissingMessageCount,
        reason: activeHistoryGap.reason,
        isOpenEnded: activeHistoryGap.isOpenEnded
      )
      do {
        try await historyWriter.recordCoverageGap(closedGap)
        pendingHistoryGaps.removeFirst()
      } catch {
        succeeded = false
        break
      }
    }
    historyIsHealthy = pendingHistoryGaps.isEmpty
    isRecoveringHistory = false
    let waiters = historyRecoveryWaiters
    historyRecoveryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    schedulePresentation()
    return succeeded
  }

  @discardableResult
  public func recordLocalOverloadCoverageGap(
    connectionEpoch: ConnectionEpochID,
    detectedAtMicroseconds: Int64,
    minimumMissingMessageCount: Int
  ) async -> Bool {
    await acquireHistoryFlush()
    defer { releaseHistoryFlush() }
    guard !isShutdownRequested, minimumMissingMessageCount > 0,
      let historyWriter
    else {
      return minimumMissingMessageCount == 0
    }
    let gap = BrokerHistoryCoverageGap(
      historySourceID: historySourceID,
      connectionEpoch: connectionEpoch,
      startedAtMicroseconds: detectedAtMicroseconds,
      endedAtMicroseconds: nil,
      minimumMissingMessageCount: minimumMissingMessageCount,
      reason: .localOverload,
      isOpenEnded: true
    )
    unpersistedMessageCount += minimumMissingMessageCount
    do {
      try await historyWriter.recordCoverageGap(gap)
      schedulePresentation()
      return true
    } catch {
      historyIsHealthy = false
      mergePendingHistoryGap(gap)
      schedulePresentation()
      return false
    }
  }

  private func waitForShutdownCompletion() async {
    guard !isShutdownComplete else { return }
    await withCheckedContinuation { continuation in
      shutdownWaiters.append(continuation)
    }
  }

  public func metrics() -> BrokerFeedIngestionMetrics {
    var nodeCount = 0
    var payloadBytes = 0
    var stack = Array(roots.values)
    while let node = stack.popLast() {
      nodeCount += 1
      payloadBytes += node.latest?.payload.count ?? 0
      stack.append(contentsOf: node.children.values)
    }
    return BrokerFeedIngestionMetrics(
      snapshotRevision: revision,
      topicNodeCount: nodeCount,
      retainedPayloadByteCount: payloadBytes,
      pendingHistoryMessageCount: pendingHistory.count,
      isShutdown: isShutdownComplete
    )
  }

  private func insert(_ message: BrokerInboundMessage) {
    let levels = message.topic.split(
      separator: "/",
      omittingEmptySubsequences: false
    ).map(String.init)
    var parent: Node?
    var prefix = ""
    var path: [Node] = []

    for (index, level) in levels.enumerated() {
      if index == 0 {
        prefix = level
      } else {
        prefix += "/\(level)"
      }
      let node: Node
      if let parent {
        if let existing = parent.children[level] {
          node = existing
        } else {
          node = Node(level: level, fullTopic: prefix)
          parent.children[level] = node
        }
      } else if let existing = roots[level] {
        node = existing
      } else {
        node = Node(level: level, fullTopic: prefix)
        roots[level] = node
      }
      path.append(node)
      parent = node
    }

    guard let exact = path.last else { return }
    let becameValueTopic = exact.latest == nil
    exact.latest = BrokerTopicLatestValue(message)
    exact.payloadSummary = makePayloadSummary(message.payload)
    exact.messageCount &+= 1
    totalMessageCount &+= 1
    for node in path {
      node.subtreeMessageCount &+= 1
      node.subtreeLatestReceivedAtMicroseconds = max(
        node.subtreeLatestReceivedAtMicroseconds ?? Int64.min,
        message.receivedAtMicroseconds
      )
      if becameValueTopic {
        node.subtreeValueTopicCount += 1
      }
    }
    if becameValueTopic {
      valueTopicCount += 1
    }
  }

  private func clearTopicTree() {
    var stack = Array(roots.values)
    roots.removeAll(keepingCapacity: false)
    while let node = stack.popLast() {
      stack.append(contentsOf: node.children.values)
      node.children.removeAll(keepingCapacity: false)
      node.latest = nil
      node.payloadSummary = nil
    }
  }

  private func schedulePresentation() {
    guard presentationTask == nil else { return }
    let delay = 1 / policy.maximumSnapshotRate
    let clock = clock
    presentationTask = Task { [weak self] in
      do {
        try await clock.sleep(seconds: delay)
        try Task.checkCancellation()
      } catch {
        return
      }
      await self?.presentationDeadlineReached()
    }
  }

  private func presentationDeadlineReached() {
    presentationTask = nil
    guard !isShutdownRequested else { return }
    _ = publishSnapshot()
  }

  private func scheduleHistoryFlush() {
    guard !isShutdownRequested, historyFlushTask == nil else { return }
    let delay = policy.historyFlushIntervalSeconds
    let clock = clock
    historyFlushTask = Task { [weak self] in
      do {
        try await clock.sleep(seconds: delay)
        try Task.checkCancellation()
      } catch {
        return
      }
      await self?.historyDeadlineReached()
    }
  }

  private func historyDeadlineReached() async {
    historyFlushTask = nil
    await flushHistory(force: true)
  }

  private func flushFullHistoryBatch() async {
    await flushHistory(force: false)
  }

  private func forceFlushHistory() async {
    await flushHistory(force: true)
  }

  private func acquireHistoryFlush() async {
    while isFlushingHistory {
      await withCheckedContinuation { continuation in
        historyFlushWaiters.append(continuation)
      }
    }
    isFlushingHistory = true
  }

  private func flushHistory(force: Bool) async {
    await acquireHistoryFlush()
    defer { releaseHistoryFlush() }
    await drainHistory(force: force)
  }

  private func drainHistory(force: Bool) async {
    guard historyIsHealthy, historyWriter != nil else { return }
    var forceNextBatch = force
    while historyIsHealthy,
      !pendingHistory.isEmpty,
      forceNextBatch || pendingHistory.count >= policy.historyBatchSize
    {
      let count = min(policy.historyBatchSize, pendingHistory.count)
      let batch = Array(pendingHistory.prefix(count))
      pendingHistory.removeFirst(count)
      do {
        try await historyWriter?.append(batch)
      } catch {
        historyIsHealthy = false
        unpersistedMessageCount += batch.count + pendingHistory.count
        if let first = batch.first ?? pendingHistory.first {
          mergePendingHistoryGap(
            BrokerHistoryCoverageGap(
              historySourceID: historySourceID,
              connectionEpoch: first.connectionEpoch,
              startedAtMicroseconds: first.receivedAtMicroseconds,
              endedAtMicroseconds: nil,
              minimumMissingMessageCount:
                batch.count + pendingHistory.count,
              reason: .storageFailure,
              isOpenEnded: false
            )
          )
        }
        pendingHistory.removeAll(keepingCapacity: false)
      }
      forceNextBatch = force
    }

    if historyIsHealthy, !pendingHistory.isEmpty {
      scheduleHistoryFlush()
    }
  }

  private func releaseHistoryFlush() {
    isFlushingHistory = false
    let waiters = historyFlushWaiters
    historyFlushWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func publishSnapshot() -> BrokerTopicTreeSnapshot {
    revision &+= 1
    let sortedRoots = roots.values.sorted(by: Self.nodeOrder)
    let snapshot = BrokerTopicTreeSnapshot(
      revision: revision,
      roots: makeSnapshots(from: sortedRoots),
      totalMessageCount: totalMessageCount,
      valueTopicCount: valueTopicCount,
      historyIsHealthy: historyIsHealthy,
      unpersistedMessageCount:
        unpersistedMessageCount + pendingHistory.count,
      connectionEpoch: connectionEpoch,
      activeHistoryGap: primaryPendingHistoryGap
    )
    continuation.yield(snapshot)
    return snapshot
  }

  private func makeSnapshots(from roots: [Node]) -> [BrokerTopicNodeSnapshot] {
    let snapshotEpoch = connectionEpoch
    var stack: [(node: Node, childrenVisited: Bool)] = []
    stack.reserveCapacity(roots.count)
    for root in roots.reversed() {
      stack.append((root, false))
    }
    var completed: [ObjectIdentifier: Int] = [:]
    var records: [BrokerTopicSnapshotRecord] = []

    while let frame = stack.popLast() {
      if frame.childrenVisited {
        let sortedChildren = frame.node.children.values.sorted(
          by: Self.nodeOrder
        )
        var childIndices: [Int] = []
        childIndices.reserveCapacity(sortedChildren.count)
        for child in sortedChildren {
          let identifier = ObjectIdentifier(child)
          guard let childIndex = completed.removeValue(forKey: identifier) else {
            preconditionFailure("Topic snapshot postorder invariant failed")
          }
          childIndices.append(childIndex)
        }
        let recordIndex = records.count
        let isStale: Bool
        if let snapshotEpoch, let latest = frame.node.latest {
          isStale =
            latest.connectionEpoch != snapshotEpoch
        } else {
          isStale = false
        }
        records.append(
          BrokerTopicSnapshotRecord(
            id: BrokerTopicID(
              brokerID: brokerID,
              fullTopic: frame.node.fullTopic
            ),
            level: frame.node.level,
            fullTopic: frame.node.fullTopic,
            foldedFullTopicSearchText:
              frame.node.foldedFullTopicSearchText,
            latest: frame.node.latest,
            payloadSummary: frame.node.payloadSummary,
            messageCount: frame.node.messageCount,
            subtreeMessageCount: frame.node.subtreeMessageCount,
            subtreeValueTopicCount: frame.node.subtreeValueTopicCount,
            subtreeLatestReceivedAtMicroseconds:
              frame.node.subtreeLatestReceivedAtMicroseconds,
            isStale: isStale,
            childIndices: childIndices
          )
        )
        completed[ObjectIdentifier(frame.node)] = recordIndex
      } else {
        stack.append((frame.node, true))
        for child in frame.node.children.values {
          stack.append((child, false))
        }
      }
    }

    let storage = BrokerTopicSnapshotStorage(records: records)
    return roots.map { root in
      guard
        let index = completed.removeValue(
          forKey: ObjectIdentifier(root)
        )
      else {
        preconditionFailure("Topic root snapshot invariant failed")
      }
      return BrokerTopicNodeSnapshot(storage: storage, index: index)
    }
  }

  private func waitForHistoryRecoveryIfNeeded() async {
    guard isRecoveringHistory else { return }
    await withCheckedContinuation { continuation in
      historyRecoveryWaiters.append(continuation)
    }
  }

  private func addMissingHistoryMessage(
    _ message: BrokerInboundMessage
  ) {
    unpersistedMessageCount += 1
    mergePendingHistoryGap(
      BrokerHistoryCoverageGap(
        historySourceID: historySourceID,
        connectionEpoch: message.connectionEpoch,
        startedAtMicroseconds: message.receivedAtMicroseconds,
        endedAtMicroseconds: nil,
        minimumMissingMessageCount: 1,
        reason: .storageFailure,
        isOpenEnded: false
      )
    )
  }

  private var primaryPendingHistoryGap: BrokerHistoryCoverageGap? {
    pendingHistoryGaps.first { $0.reason == .storageFailure }
      ?? pendingHistoryGaps.first
  }

  private func mergePendingHistoryGap(
    _ newGap: BrokerHistoryCoverageGap
  ) {
    guard
      let index = pendingHistoryGaps.firstIndex(where: {
        $0.reason == newGap.reason
      })
    else {
      pendingHistoryGaps.append(newGap)
      return
    }
    let existing = pendingHistoryGaps[index]
    pendingHistoryGaps[index] = BrokerHistoryCoverageGap(
      historySourceID: existing.historySourceID,
      connectionEpoch:
        existing.connectionEpoch == newGap.connectionEpoch
        ? existing.connectionEpoch : nil,
      startedAtMicroseconds: min(
        existing.startedAtMicroseconds,
        newGap.startedAtMicroseconds
      ),
      endedAtMicroseconds: nil,
      minimumMissingMessageCount: saturatingAdd(
        existing.minimumMissingMessageCount,
        newGap.minimumMissingMessageCount
      ),
      reason: existing.reason,
      isOpenEnded: existing.isOpenEnded || newGap.isOpenEnded
    )
  }

  private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
  }

  private nonisolated static func nodeOrder(
    _ lhs: Node,
    _ rhs: Node
  ) -> Bool {
    if lhs.level != rhs.level {
      return lhs.level < rhs.level
    }
    return lhs.fullTopic < rhs.fullTopic
  }

  private func makePayloadSummary(
    _ payload: Data
  ) -> BrokerTopicPayloadSummary? {
    let characterLimit = policy.maximumPayloadSummaryCharacters
    let byteLimit =
      characterLimit > (Int.max - 4) / 4
      ? Int.max
      : characterLimit * 4 + 4
    let inspectedByteCount = min(payload.count, byteLimit)
    let inspected = payload.prefix(inspectedByteCount)
    var text: String?
    var decodedByteCount = inspectedByteCount
    if inspectedByteCount == payload.count {
      text = String(data: inspected, encoding: .utf8)
    } else {
      for trailingByteCount in 0...min(3, inspectedByteCount) {
        let candidateCount = inspectedByteCount - trailingByteCount
        if let candidate = String(
          data: inspected.prefix(candidateCount),
          encoding: .utf8
        ) {
          text = candidate
          decodedByteCount = candidateCount
          break
        }
      }
    }
    guard let text else {
      return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: BrokerTopicPayloadSummary.Kind =
      trimmed.first == "{" || trimmed.first == "[" ? .json : .scalar
    let isTruncated =
      trimmed.count > characterLimit || payload.count > decodedByteCount
    let display = String(trimmed.prefix(characterLimit))
    return BrokerTopicPayloadSummary(
      kind: kind,
      display: display,
      foldedSearchText: display.folding(
        options: [
          .caseInsensitive,
          .diacriticInsensitive,
          .widthInsensitive,
        ],
        locale: Locale(identifier: "en_US_POSIX")
      ),
      isTruncated: isTruncated
    )
  }
}
