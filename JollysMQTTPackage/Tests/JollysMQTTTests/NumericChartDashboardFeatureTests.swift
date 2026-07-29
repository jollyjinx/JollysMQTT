import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("Numeric chart dashboard feature")
@MainActor
struct NumericChartDashboardFeatureTests {
  @Test("Duplicate series keep distinct IDs and card actions preserve deterministic order")
  func duplicateSeriesAndCardActions() throws {
    let brokerID = UUID()
    let firstID = NumericChartCardID(rawValue: UUID())
    let secondID = NumericChartCardID(rawValue: UUID())
    let series = chartSeries(brokerID: brokerID, topic: "factory/value")
    let dashboard = NumericChartDashboardStore()
    var persisted: [NumericChartDashboardConfiguration] = []
    dashboard.onConfigurationChange = { persisted.append($0) }

    #expect(dashboard.pin(series, id: firstID))
    #expect(dashboard.pin(series, id: secondID))
    #expect(dashboard.state.cards.map(\.id) == [firstID, secondID])

    dashboard.send(.setPresentationStyle(secondID, .step))
    dashboard.send(.setColor(secondID, .orange))
    dashboard.send(.setGridSpan(secondID, .full))
    dashboard.send(.move(secondID, .earlier))

    #expect(dashboard.state.cards.map(\.id) == [secondID, firstID])
    #expect(dashboard.state.cards.first?.presentationStyle == .step)
    #expect(dashboard.state.cards.first?.color == .orange)
    #expect(dashboard.state.cards.first?.gridSpan == .full)

    let firstStore = try #require(dashboard.cardStore(for: firstID))
    let secondStore = try #require(dashboard.cardStore(for: secondID))
    firstStore.send(.setPaused(true))

    #expect(firstStore.state.configuration?.isPaused == true)
    #expect(secondStore.state.configuration?.isPaused == false)
    #expect(
      persisted.last?.cards.first(where: { $0.id == firstID })?
        .chart.isPaused == true
    )

    dashboard.send(.remove(secondID))

    #expect(dashboard.state.cards.map(\.id) == [firstID])
    #expect(dashboard.cardStore(for: secondID) == nil)
  }

  @Test("The fixed card limit creates fixed aggregate sample and query ceilings")
  func cardLimitIsEnforced() {
    let policy = NumericChartDashboardPolicy.default
    let dashboard = NumericChartDashboardStore(policy: policy)
    let brokerID = UUID()

    for index in 0..<policy.maximumCardCount {
      #expect(
        dashboard.pin(
          chartSeries(
            brokerID: brokerID,
            topic: "factory/value/\(index)"
          )
        )
      )
    }

    #expect(
      !dashboard.pin(
        chartSeries(brokerID: brokerID, topic: "factory/overflow")
      )
    )
    #expect(dashboard.state.cards.count == policy.maximumCardCount)
    #expect(
      dashboard.aggregateRawSampleCount
        <= policy.maximumAggregateRawSampleCount
    )
    #expect(
      dashboard.aggregateDisplaySampleCount
        <= policy.maximumAggregateDisplaySampleCount
    )
  }

  @Test("Wide layout packs stable card IDs responsively and honors adaptive spans")
  func responsiveGridPacking() {
    let brokerID = UUID()
    let cards = [
      chartCard(brokerID: brokerID, topic: "one", span: .half),
      chartCard(brokerID: brokerID, topic: "two", span: .third),
      chartCard(brokerID: brokerID, topic: "three", span: .full),
      chartCard(brokerID: brokerID, topic: "four", span: .automatic),
    ]

    let wide = NumericChartDashboardGridLayout(
      cards: cards,
      availableWidth: 1_200
    )
    let compact = NumericChartDashboardGridLayout(
      cards: cards,
      availableWidth: 500
    )

    #expect(wide.columnCount == 3)
    #expect(wide.rows.map(\.placements).flatMap { $0 }.map(\.id) == cards.map(\.id))
    #expect(wide.rows[0].placements.map(\.columnSpan) == [2, 1])
    #expect(wide.rows[1].placements.map(\.columnSpan) == [3])
    #expect(compact.columnCount == 1)
    #expect(
      compact.rows.allSatisfy {
        $0.placements.count == 1 && $0.placements[0].columnSpan == 1
      }
    )
  }

  @Test("A removed queued card never starts and dashboard history concurrency stays bounded")
  func removedQueuedCardCancelsLoad() async throws {
    let brokerID = UUID()
    let repository = BlockingDashboardHistoryRepository()
    let policy = NumericChartDashboardPolicy.default
    let dashboard = NumericChartDashboardStore(
      repositories: .init { _ in repository },
      policy: policy
    )
    let cards = (0..<6).map {
      chartCard(
        brokerID: brokerID,
        topic: "factory/value/\($0)",
        span: .automatic
      )
    }
    dashboard.restore(.init(cards: cards))
    dashboard.updateSnapshot(
      dashboardSnapshot(historySourceID: "source"),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      await repository.startedTopics().count
        == policy.maximumConcurrentHistoryLoads
    }
    let started = await repository.startedTopics()
    let queued = try #require(
      cards.first { !started.contains($0.chart.series.id.topic) }
    )

    dashboard.send(.remove(queued.id))
    await repository.resumeOne()
    await waitUntil {
      await repository.startedTopics().count
        == policy.maximumConcurrentHistoryLoads + 1
    }

    #expect(
      await repository.maximumActiveCount()
        <= policy.maximumConcurrentHistoryLoads
    )
    #expect(
      !repositoryStarted(
        await repository.startedTopics(),
        topic: queued.chart.series.id.topic
      )
    )
    await repository.resumeAll()
  }

  @Test("Twelve busy cards keep aggregate query, raw, and display work bounded")
  func busyDashboardFixtureIsBounded() async {
    let brokerID = UUID()
    let repository = BusyDashboardHistoryRepository()
    let policy = NumericChartDashboardPolicy.default
    let dashboard = NumericChartDashboardStore(
      repositories: .init { _ in repository },
      policy: policy
    )
    let cards = (0..<policy.maximumCardCount).map {
      chartCard(
        brokerID: brokerID,
        topic: "busy/value/\($0)",
        span: .automatic
      )
    }
    dashboard.restore(.init(cards: cards))
    dashboard.updateSnapshot(
      dashboardSnapshot(historySourceID: "busy-source"),
      expectedBrokerID: brokerID
    )

    await waitUntil {
      dashboard.state.cards.allSatisfy {
        dashboard.cardStore(for: $0.id)?.state.loadStatus == .loaded
      }
    }

    #expect(
      dashboard.aggregateRawSampleCount
        <= policy.maximumAggregateRawSampleCount
    )
    #expect(
      dashboard.aggregateDisplaySampleCount
        <= policy.maximumAggregateDisplaySampleCount
    )
    #expect(
      dashboard.aggregateHistoryMessageCountExamined
        <= policy.maximumCardCount
        * policy.cardPolicy.maximumHistoryMessageCount
    )
    if let first = dashboard.state.cards.first,
      let firstStore = dashboard.cardStore(for: first.id)
    {
      #expect(
        firstStore.state.samples.first?.durableOrder
          == Int64(4_096 - policy.cardPolicy.maximumHistoryMessageCount + 1)
      )
      #expect(firstStore.state.samples.last?.durableOrder == 4_096)
    } else {
      Issue.record("Expected the first busy dashboard card")
    }
    let requests = await repository.requests()
    #expect(requests.count == policy.maximumCardCount)
    #expect(
      requests.reduce(0) { $0 + $1.maximumPayloadBytes }
        <= policy.maximumAggregateHistoryPayloadBytes
    )
    #expect(
      requests.allSatisfy {
        $0.maximumMessageCount
          == policy.cardPolicy.maximumHistoryMessageCount
      }
    )
  }

  @Test("Cancellation racing a permit grant does not leak the shared load slot")
  func cancellationGrantRaceDoesNotLeakPermit() async {
    let limiter = NumericChartHistoryLoadLimiter(
      maximumConcurrentLoads: 1
    )
    let probe = BlockingDashboardHistoryRepository()
    let first = Task {
      try await limiter.perform {
        try await probe.numericChartHistory(
          chartRequest(topic: "first")
        )
      }
    }
    await waitUntil {
      await probe.startedTopics() == ["first"]
    }
    let cancelled = Task {
      try await limiter.perform {
        try await probe.numericChartHistory(
          chartRequest(topic: "cancelled")
        )
      }
    }
    for _ in 0..<20 {
      await Task.yield()
    }

    cancelled.cancel()
    await probe.resumeOne()
    _ = await first.result
    _ = await cancelled.result

    let final = Task {
      try await limiter.perform {
        NumericChartHistoryResult(messages: [], payloadByteCount: 0)
      }
    }
    let result = await final.result
    let loaded = try? result.get()

    #expect(
      loaded
        == NumericChartHistoryResult(
          messages: [],
          payloadByteCount: 0
        )
    )
  }

  @Test("A stale removed-card completion cannot cross a same-ID re-add")
  func staleCompletionCannotCrossCardGeneration() async throws {
    let brokerID = UUID()
    let cardID = NumericChartCardID(rawValue: UUID())
    let repository = ControlledDashboardHistoryRepository()
    let dashboard = NumericChartDashboardStore(
      repositories: .init { _ in repository }
    )
    #expect(
      dashboard.pin(
        chartSeries(brokerID: brokerID, topic: "old/topic"),
        id: cardID
      )
    )
    dashboard.updateSnapshot(
      dashboardSnapshot(historySourceID: "source"),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      await repository.requestedTopics().contains("old/topic")
    }

    dashboard.send(.remove(cardID))
    #expect(
      dashboard.pin(
        chartSeries(brokerID: brokerID, topic: "new/topic"),
        id: cardID
      )
    )
    await waitUntil {
      await repository.requestedTopics().contains("new/topic")
    }

    await repository.resume(
      topic: "new/topic",
      value: 9,
      durableOrder: 9
    )
    let newStore = try #require(dashboard.cardStore(for: cardID))
    await waitUntil {
      newStore.state.samples.map(\.value) == [9]
    }
    await repository.resume(
      topic: "old/topic",
      value: 1,
      durableOrder: 1
    )
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(
      dashboard.state.cards.first?.chart.series.id.topic == "new/topic"
    )
    #expect(newStore.state.samples.map(\.value) == [9])
  }

  private func chartSeries(
    brokerID: UUID,
    topic: String
  ) -> NumericChartSeries {
    NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: brokerID,
        topic: topic
      ),
      conversion: NumericChartValueConversion(kind: .number)
    )
  }

  private func chartCard(
    brokerID: UUID,
    topic: String,
    span: NumericChartGridSpan
  ) -> NumericChartCardConfiguration {
    NumericChartCardConfiguration(
      chart: NumericChartConfiguration(
        series: chartSeries(brokerID: brokerID, topic: topic)
      ),
      gridSpan: span
    )
  }

  private func dashboardSnapshot(
    historySourceID: String
  ) -> BrokerTopicTreeSnapshot {
    BrokerTopicTreeSnapshot(
      revision: 1,
      roots: [],
      totalMessageCount: 0,
      valueTopicCount: 0,
      historyIsHealthy: true,
      unpersistedMessageCount: 0,
      historySourceID: historySourceID
    )
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool
  ) async {
    for _ in 0..<2_000 {
      if await condition() { return }
      await Task.yield()
    }
    Issue.record("Timed out waiting for dashboard state")
  }
}

private func chartRequest(topic: String) -> NumericChartHistoryRequest {
  NumericChartHistoryRequest(
    historySourceID: "source",
    topic: topic,
    maximumMessageCount: 4,
    maximumPayloadBytesPerSample: 1,
    maximumPayloadBytes: 4_096
  )
}

private func repositoryStarted(
  _ topics: [String],
  topic: String
) -> Bool {
  topics.contains(topic)
}

private actor BlockingDashboardHistoryRepository: BrokerHistoryReading {
  private var started: [String] = []
  private var activeCount = 0
  private var maximumActive = 0
  private var continuations: [CheckedContinuation<NumericChartHistoryResult, Never>] = []

  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }

  func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) async throws -> NumericChartHistoryResult {
    started.append(request.topic)
    activeCount += 1
    maximumActive = max(maximumActive, activeCount)
    let result = await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    activeCount -= 1
    return result
  }

  func startedTopics() -> [String] {
    started
  }

  func maximumActiveCount() -> Int {
    maximumActive
  }

  func resumeOne() {
    guard !continuations.isEmpty else { return }
    continuations.removeFirst().resume(
      returning: NumericChartHistoryResult(
        messages: [],
        payloadByteCount: 0
      )
    )
  }

  func resumeAll() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume(
        returning: NumericChartHistoryResult(
          messages: [],
          payloadByteCount: 0
        )
      )
    }
  }
}

private actor BusyDashboardHistoryRepository: BrokerHistoryReading {
  private var recordedRequests: [NumericChartHistoryRequest] = []
  private let epoch = UUID()

  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }

  func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) -> NumericChartHistoryResult {
    recordedRequests.append(request)
    let messages = (0..<4_096).map { index in
      StoredHistoryMessage(
        durableOrder: Int64(index + 1),
        historySourceID: request.historySourceID,
        connectionEpoch: epoch,
        connectionOrdinal: UInt64(index + 1),
        operationID: nil,
        direction: .received,
        topic: request.topic,
        qos: .atMostOnce,
        retained: false,
        receivedAtMicroseconds: Int64(index),
        payload: Data("1".utf8)
      )
    }
    return NumericChartHistoryResult(
      messages: messages,
      payloadByteCount: messages.count
    )
  }

  func requests() -> [NumericChartHistoryRequest] {
    recordedRequests
  }
}

private actor ControlledDashboardHistoryRepository:
  BrokerHistoryReading
{
  private var requests: [String] = []
  private var continuations: [String: CheckedContinuation<NumericChartHistoryResult, any Error>] =
    [:]

  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }

  func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) async throws -> NumericChartHistoryResult {
    requests.append(request.topic)
    return try await withCheckedThrowingContinuation { continuation in
      continuations[request.topic] = continuation
    }
  }

  func requestedTopics() -> [String] {
    requests
  }

  func resume(
    topic: String,
    value: Int,
    durableOrder: Int64
  ) {
    let continuation = continuations.removeValue(forKey: topic)
    continuation?.resume(
      returning: NumericChartHistoryResult(
        messages: [
          StoredHistoryMessage(
            durableOrder: durableOrder,
            historySourceID: "source",
            connectionEpoch: UUID(),
            connectionOrdinal: UInt64(durableOrder),
            operationID: nil,
            direction: .received,
            topic: topic,
            qos: .atMostOnce,
            retained: false,
            receivedAtMicroseconds: durableOrder,
            payload: Data(String(value).utf8)
          )
        ],
        payloadByteCount: 1
      )
    )
  }
}
