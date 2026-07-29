import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

public enum NumericChartLoadStatus: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed
}

public enum NumericChartPinUnavailableReason: Equatable, Sendable {
  case noCurrentPayload
  case payloadIsNotJSON
  case selectNumericLeaf
  case selectedValueIsNotNumeric
  case invalidJSONPointer
}

public enum NumericChartPinAvailability: Equatable, Sendable {
  case available(NumericChartSeries)
  case unavailable(NumericChartPinUnavailableReason)
}

public enum NumericChartPinEvaluator {
  public static func availability(
    inspection: PayloadInspection?,
    selectedJSONPointer: PayloadJSONPointer?
  ) -> NumericChartPinAvailability {
    guard let inspection else {
      return .unavailable(.noCurrentPayload)
    }
    guard case .json(let document) = inspection.presentation else {
      return .unavailable(.payloadIsNotJSON)
    }
    let pointer = selectedJSONPointer ?? .root
    guard isCanonical(pointer) else {
      return .unavailable(.invalidJSONPointer)
    }
    guard let value = document.value(at: pointer) else {
      return .unavailable(.invalidJSONPointer)
    }
    let kind: NumericChartValueKind
    switch value {
    case .number(let number):
      guard number.doubleValue.isFinite else {
        return .unavailable(.selectedValueIsNotNumeric)
      }
      kind = .number
    case .boolean:
      kind = .booleanAsZeroOrOne
    case .object, .array:
      return .unavailable(.selectNumericLeaf)
    case .string, .null:
      return .unavailable(.selectedValueIsNotNumeric)
    }
    return .available(
      NumericChartSeries(
        id: NumericChartSeriesID(
          brokerID: inspection.message.topicID.brokerID,
          topic: inspection.message.topicID.fullTopic,
          jsonPointer: pointer == .root ? nil : pointer
        ),
        conversion: NumericChartValueConversion(kind: kind)
      )
    )
  }

  private static func isCanonical(_ pointer: PayloadJSONPointer) -> Bool {
    let raw = pointer.rawValue
    if raw.isEmpty { return true }
    guard raw.first == "/" else { return false }
    var index = raw.startIndex
    while index < raw.endIndex {
      if raw[index] == "~" {
        let escaped = raw.index(after: index)
        guard escaped < raw.endIndex,
          raw[escaped] == "0" || raw[escaped] == "1"
        else {
          return false
        }
        index = raw.index(after: escaped)
      } else {
        index = raw.index(after: index)
      }
    }
    return true
  }
}

public enum NumericChartPinStateEvaluator {
  public static func isPinned(
    candidate: NumericChartSeries,
    pinnedSeries: NumericChartSeries?
  ) -> Bool {
    candidate.id == pinnedSeries?.id
      && candidate.conversion.kind == pinnedSeries?.conversion.kind
  }
}

public enum NumericChartFeature {
  public struct State: Equatable, Sendable {
    public fileprivate(set) var configuration: NumericChartConfiguration?
    public fileprivate(set) var samples: [NumericChartSample] = []
    public fileprivate(set) var displaySamples: [NumericChartSample] = []
    public fileprivate(set) var historySourceID: String?
    public fileprivate(set) var loadStatus: NumericChartLoadStatus = .idle
    public fileprivate(set) var historyMessageCountExamined = 0

    fileprivate var expectedBrokerID: UUID?
    fileprivate var latestSnapshotRevision: UInt64 = 0
    fileprivate var pendingLiveMessage: PayloadMessage?
    fileprivate var pixelWidth: Double = 1_024

    public init(configuration: NumericChartConfiguration? = nil) {
      self.configuration = configuration
    }

    public var visibleTimeRangeMicroseconds: ClosedRange<Int64>? {
      guard let configuration,
        let latestArrivalTimestamp = samples.last?.receivedAtMicroseconds
      else {
        return nil
      }
      let upperBound =
        configuration.autoScroll
        ? latestArrivalTimestamp
        : configuration.visibleRange.endingAtMicroseconds
          ?? latestArrivalTimestamp
      let (candidateLowerBound, overflow) =
        upperBound.subtractingReportingOverflow(
          configuration.visibleRange.durationMicroseconds
        )
      return (overflow ? Int64.min : candidateLowerBound)...upperBound
    }
  }

  public enum Intent: Equatable, Sendable {
    case setPaused(Bool)
    case setAutoScroll(Bool)
    case setVisibleRange(NumericChartVisibleRange)
    case setYAxis(NumericChartYAxis)
    case setMultiplier(Double)
    case setPixelWidth(Double)
    case clearDisplayedSamples
    case retry
    case remove
  }
}

public actor NumericChartHistoryLoadLimiter {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let maximumConcurrentLoads: Int
  private var activeLoadCount = 0
  private var waiters: [Waiter] = []

  public init(maximumConcurrentLoads: Int) {
    precondition(maximumConcurrentLoads >= 1)
    self.maximumConcurrentLoads = maximumConcurrentLoads
  }

  public func perform<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    try await acquire()
    do {
      let result = try await operation()
      release()
      return result
    } catch {
      release()
      throw error
    }
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if activeLoadCount < maximumConcurrentLoads {
      activeLoadCount += 1
      return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(
          Waiter(id: waiterID, continuation: continuation)
        )
      }
    } onCancel: {
      Task {
        await self.cancel(waiterID)
      }
    }
    do {
      try Task.checkCancellation()
    } catch {
      release()
      throw error
    }
  }

  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func release() {
    while !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.continuation.resume()
      return
    }
    activeLoadCount -= 1
  }
}

@MainActor
@Observable
public final class NumericChartStore {
  public private(set) var state: NumericChartFeature.State

  public var onConfigurationChange: (@MainActor @Sendable (NumericChartConfiguration?) -> Void)?

  private let repositories: BrokerHistoryRepositoryProvider
  private let policy: NumericChartPolicy
  private let extractor: NumericChartValueExtractor
  private let loadLimiter: NumericChartHistoryLoadLimiter?
  private var loadTask: Task<Void, Never>?
  private var liveExtractionTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var lastSnapshot: BrokerTopicTreeSnapshot?
  private var lastExpectedBrokerID: UUID?

  public init(
    repositories: BrokerHistoryRepositoryProvider = .empty,
    policy: NumericChartPolicy = .default,
    loadLimiter: NumericChartHistoryLoadLimiter? = nil
  ) {
    self.repositories = repositories
    self.policy = policy
    self.extractor = NumericChartValueExtractor(policy: policy)
    self.loadLimiter = loadLimiter
    self.state = .init()
  }

  isolated deinit {
    loadTask?.cancel()
    liveExtractionTask?.cancel()
  }

  public func restore(_ configuration: NumericChartConfiguration?) {
    invalidateWork()
    let normalizedConfiguration =
      configuration?.normalizingAutoScroll()
    state = .init(configuration: normalizedConfiguration)
    guard normalizedConfiguration != nil,
      let lastSnapshot
    else {
      return
    }
    applySnapshot(
      lastSnapshot,
      expectedBrokerID: lastExpectedBrokerID
    )
  }

  public func pin(_ series: NumericChartSeries) {
    restore(NumericChartConfiguration(series: series))
    onConfigurationChange?(state.configuration)
  }

  public func updateSnapshot(
    _ snapshot: BrokerTopicTreeSnapshot,
    expectedBrokerID: UUID?
  ) {
    lastSnapshot = snapshot
    lastExpectedBrokerID = expectedBrokerID
    applySnapshot(snapshot, expectedBrokerID: expectedBrokerID)
  }

  public func send(_ intent: NumericChartFeature.Intent) {
    switch intent {
    case .setPaused(let isPaused):
      guard var configuration = state.configuration,
        configuration.isPaused != isPaused
      else {
        return
      }
      configuration.isPaused = isPaused
      state.configuration = configuration
      onConfigurationChange?(configuration)
      if !isPaused {
        appendPendingLiveIfPossible()
      }

    case .setAutoScroll(let autoScroll):
      guard var configuration = state.configuration,
        configuration.autoScroll != autoScroll
      else {
        return
      }
      if !autoScroll {
        guard let endingAt = state.samples.last?.receivedAtMicroseconds else {
          return
        }
        guard
          let anchoredRange = try? NumericChartVisibleRange(
            durationMicroseconds:
              configuration.visibleRange.durationMicroseconds,
            endingAtMicroseconds: endingAt
          )
        else {
          return
        }
        configuration.visibleRange = anchoredRange
      }
      configuration.autoScroll = autoScroll
      state.configuration = configuration
      refreshDisplaySamples()
      onConfigurationChange?(configuration)

    case .setVisibleRange(let visibleRange):
      guard var configuration = state.configuration else { return }
      configuration.visibleRange = visibleRange
      state.configuration = configuration
      refreshDisplaySamples()
      onConfigurationChange?(configuration)

    case .setYAxis(let yAxis):
      guard var configuration = state.configuration else { return }
      configuration.yAxis = yAxis
      state.configuration = configuration
      onConfigurationChange?(configuration)

    case .setMultiplier(let multiplier):
      guard multiplier.isFinite,
        var configuration = state.configuration,
        configuration.series.conversion.multiplier != multiplier
      else {
        return
      }
      configuration = NumericChartConfiguration(
        series: NumericChartSeries(
          id: configuration.series.id,
          conversion: NumericChartValueConversion(
            kind: configuration.series.conversion.kind,
            multiplier: multiplier
          )
        ),
        isPaused: configuration.isPaused,
        autoScroll: configuration.autoScroll,
        visibleRange: configuration.visibleRange,
        yAxis: configuration.yAxis,
        sampleClearMarker: configuration.sampleClearMarker
      )
      restore(configuration)
      onConfigurationChange?(configuration)

    case .setPixelWidth(let width):
      state.pixelWidth = width.isFinite ? max(0, width) : 0
      refreshDisplaySamples()

    case .clearDisplayedSamples:
      guard var configuration = state.configuration,
        let historySourceID = state.historySourceID,
        !state.samples.isEmpty
      else {
        return
      }
      configuration.sampleClearMarker = NumericChartSampleClearMarker(
        historySourceID: historySourceID,
        throughDurableOrder: state.samples.compactMap(\.durableOrder).max(),
        sampleIDs: state.samples.map(\.id)
      )
      state.configuration = configuration
      state.samples = []
      state.displaySamples = []
      onConfigurationChange?(configuration)

    case .retry:
      guard state.configuration != nil,
        state.historySourceID != nil
      else {
        return
      }
      startHistoryLoad()

    case .remove:
      restore(nil)
      onConfigurationChange?(nil)
    }
  }

  private func applySnapshot(
    _ snapshot: BrokerTopicTreeSnapshot,
    expectedBrokerID: UUID?
  ) {
    guard let configuration = state.configuration,
      expectedBrokerID == configuration.series.id.brokerID,
      let historySourceID = snapshot.historySourceID
    else {
      detach()
      return
    }

    if state.historySourceID == historySourceID,
      snapshot.revision != 0,
      snapshot.revision < state.latestSnapshotRevision
    {
      return
    }

    let sourceChanged = state.historySourceID != historySourceID
    if sourceChanged {
      invalidateWork()
      state.samples = []
      state.displaySamples = []
      state.historySourceID = historySourceID
      state.loadStatus = .idle
      state.historyMessageCountExamined = 0
      state.latestSnapshotRevision = 0
      state.pendingLiveMessage = nil
    }
    state.expectedBrokerID = expectedBrokerID
    state.latestSnapshotRevision = max(
      state.latestSnapshotRevision,
      snapshot.revision
    )
    state.pendingLiveMessage = currentMessage(
      in: snapshot,
      for: configuration.series
    )

    if sourceChanged {
      startHistoryLoad()
    } else if state.loadStatus == .loaded {
      appendPendingLiveIfPossible()
    }
  }

  private func detach() {
    invalidateWork()
    state.samples = []
    state.displaySamples = []
    state.historySourceID = nil
    state.loadStatus = .idle
    state.historyMessageCountExamined = 0
    state.expectedBrokerID = nil
    state.latestSnapshotRevision = 0
    state.pendingLiveMessage = nil
  }

  private func invalidateWork() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    liveExtractionTask?.cancel()
    liveExtractionTask = nil
  }

  private func startHistoryLoad() {
    guard let configuration = state.configuration,
      let historySourceID = state.historySourceID
    else {
      return
    }
    invalidateWork()
    let requestGeneration = generation
    let series = configuration.series
    let request = NumericChartHistoryRequest(
      historySourceID: historySourceID,
      topic: series.id.topic,
      maximumMessageCount: policy.maximumHistoryMessageCount,
      maximumPayloadBytesPerSample:
        policy.maximumPayloadBytesPerSample,
      maximumPayloadBytes: policy.maximumPayloadBytesPerLoad
    )
    let repository = repositories.repository(for: series.id.brokerID)
    let extractor = extractor
    let policy = policy
    let loadLimiter = loadLimiter
    state.samples = []
    state.displaySamples = []
    state.loadStatus = .loading
    state.historyMessageCountExamined = 0

    loadTask = Task { [weak self] in
      do {
        let batch: HistorySampleBatch
        if let loadLimiter {
          batch = try await loadLimiter.perform {
            let result = try await repository.numericChartHistory(request)
            try Task.checkCancellation()
            return await Self.samples(
              from: result,
              request: request,
              series: series,
              clearMarker: configuration.sampleClearMarker,
              extractor: extractor,
              policy: policy
            )
          }
        } else {
          let result = try await repository.numericChartHistory(request)
          try Task.checkCancellation()
          batch = await Self.samples(
            from: result,
            request: request,
            series: series,
            clearMarker: configuration.sampleClearMarker,
            extractor: extractor,
            policy: policy
          )
        }
        try Task.checkCancellation()
        guard let self,
          generation == requestGeneration,
          state.historySourceID == historySourceID,
          state.configuration?.series == series
        else {
          return
        }
        state.samples = batch.samples
        state.historyMessageCountExamined = batch.examinedMessageCount
        state.loadStatus = .loaded
        refreshDisplaySamples()
        appendPendingLiveIfPossible()
      } catch is CancellationError {
        return
      } catch {
        guard let self,
          generation == requestGeneration,
          state.historySourceID == historySourceID,
          state.configuration?.series == series
        else {
          return
        }
        state.loadStatus = .failed
        state.historyMessageCountExamined = 0
        state.samples = []
        state.displaySamples = []
      }
    }
  }

  private struct HistorySampleBatch: Sendable {
    let samples: [NumericChartSample]
    let examinedMessageCount: Int
  }

  private nonisolated static func samples(
    from result: NumericChartHistoryResult,
    request: NumericChartHistoryRequest,
    series: NumericChartSeries,
    clearMarker: NumericChartSampleClearMarker?,
    extractor: NumericChartValueExtractor,
    policy: NumericChartPolicy
  ) async -> HistorySampleBatch {
    var payloadByteCount = 0
    var samples: [NumericChartSample] = []
    samples.reserveCapacity(
      min(result.messages.count, policy.maximumRawSampleCount)
    )
    var seen: Set<NumericChartSampleID> = []
    var examinedMessageCount = 0

    for message in result.messages.suffix(
      request.maximumMessageCount
    ) {
      if Task.isCancelled {
        return HistorySampleBatch(
          samples: [],
          examinedMessageCount: examinedMessageCount
        )
      }
      examinedMessageCount += 1
      guard message.historySourceID == request.historySourceID,
        message.topic == series.id.topic,
        message.direction == .received,
        message.hasStoredPayload,
        let connectionEpoch = message.connectionEpoch,
        let connectionOrdinal = message.connectionOrdinal,
        message.payload.count <= request.maximumPayloadBytesPerSample,
        payloadByteCount
          <= request.maximumPayloadBytes - message.payload.count
      else {
        continue
      }
      payloadByteCount += message.payload.count
      let id = NumericChartSampleID(
        connectionEpoch: connectionEpoch,
        ordinal: connectionOrdinal,
        direction: message.direction
      )
      guard
        !isCleared(
          id: id,
          durableOrder: message.durableOrder,
          marker: clearMarker
        ),
        seen.insert(id).inserted,
        let value = await extractor.value(
          in: message.payload,
          for: series
        )
      else {
        continue
      }
      samples.append(
        NumericChartSample(
          id: id,
          receivedAtMicroseconds: message.receivedAtMicroseconds,
          value: value,
          durableOrder: message.durableOrder
        )
      )
    }
    return HistorySampleBatch(
      samples: Array(samples.suffix(policy.maximumRawSampleCount)),
      examinedMessageCount: examinedMessageCount
    )
  }

  private func appendPendingLiveIfPossible() {
    guard state.loadStatus == .loaded,
      state.configuration?.isPaused == false,
      let message = state.pendingLiveMessage,
      let series = state.configuration?.series,
      message.direction == .received,
      message.topicID.brokerID == series.id.brokerID,
      message.topicID.fullTopic == series.id.topic,
      message.payload.count <= policy.maximumPayloadBytesPerSample
    else {
      return
    }
    let id = NumericChartSampleID(
      connectionEpoch: message.id.connectionEpoch.rawValue,
      ordinal: message.id.ordinal,
      direction: message.direction
    )
    guard !state.samples.contains(where: { $0.id == id }) else {
      return
    }

    liveExtractionTask?.cancel()
    let requestGeneration = generation
    let extractor = extractor
    liveExtractionTask = Task { [weak self] in
      guard
        let value = await extractor.value(
          in: message.payload,
          for: series
        ), !Task.isCancelled,
        let self,
        generation == requestGeneration,
        state.historySourceID != nil,
        state.configuration?.series == series,
        state.configuration?.isPaused == false,
        state.pendingLiveMessage?.id == message.id
      else {
        return
      }
      let sample = NumericChartSample(
        id: id,
        receivedAtMicroseconds: message.receivedAtMicroseconds,
        value: value
      )
      guard
        !Self.isCleared(
          id: sample.id,
          durableOrder: nil,
          marker: state.configuration?.sampleClearMarker
        ),
        !state.samples.contains(where: { $0.id == sample.id })
      else {
        return
      }
      state.samples = Array(
        (state.samples + [sample]).suffix(policy.maximumRawSampleCount)
      )
      refreshDisplaySamples()
    }
  }

  private nonisolated static func isCleared(
    id: NumericChartSampleID,
    durableOrder: Int64?,
    marker: NumericChartSampleClearMarker?
  ) -> Bool {
    guard let marker else { return false }
    if marker.sampleIDs.contains(id) {
      return true
    }
    guard let durableOrder,
      let throughDurableOrder = marker.throughDurableOrder
    else {
      return false
    }
    return durableOrder <= throughDurableOrder
  }

  private func refreshDisplaySamples() {
    guard let visibleRange = state.visibleTimeRangeMicroseconds
    else {
      state.displaySamples = []
      return
    }
    let visible = state.samples.filter {
      visibleRange.contains($0.receivedAtMicroseconds)
    }.enumerated().sorted { lhs, rhs in
      if lhs.element.receivedAtMicroseconds
        == rhs.element.receivedAtMicroseconds
      {
        return lhs.offset < rhs.offset
      }
      return lhs.element.receivedAtMicroseconds
        < rhs.element.receivedAtMicroseconds
    }.map(\.element)
    state.displaySamples = NumericChartDownsampler.downsample(
      visible,
      maximumSampleCount: policy.maximumDisplaySampleCount(
        forPixelWidth: state.pixelWidth
      )
    )
  }

  private func currentMessage(
    in snapshot: BrokerTopicTreeSnapshot,
    for series: NumericChartSeries
  ) -> PayloadMessage? {
    guard
      case .current(let message) = snapshot.payloadSelection(
        brokerID: series.id.brokerID,
        fullTopic: series.id.topic
      ),
      message.direction == .received,
      message.payload.count <= policy.maximumPayloadBytesPerSample
    else {
      return nil
    }
    return message
  }
}
