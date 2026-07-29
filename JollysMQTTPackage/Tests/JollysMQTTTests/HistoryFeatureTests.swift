import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("History feature")
struct HistoryFeatureTests {
  @Test("Default baseline skips the durable copy of the live current message")
  func defaultBaselineAccountsForFlushing() throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 2,
      payload: Data("current".utf8)
    )
    var state = HistoryFeature.State(pageSize: 20)

    let load = HistoryFeature.reduce(
      state: &state,
      intent: .contextChanged(
        HistoryContext(
          brokerID: brokerID,
          historySourceID: "source-a",
          current: current
        )
      )
    )
    guard case .loadPage(let requestID, let request) = load else {
      Issue.record("Expected initial page load")
      return
    }
    let compare = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: requestID,
        request: request,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 2,
              epoch: epoch,
              ordinal: 2,
              payload: current.payload
            ),
            storedMessage(
              durableOrder: 1,
              epoch: epoch,
              ordinal: 1,
              payload: Data("previous".utf8)
            ),
          ],
          nextCursor: nil
        )
      )
    )

    #expect(state.rows.map(\.id) == [2, 1])
    #expect(state.selectedBaselineID == nil)
    #expect(state.effectiveBaselineID == .durable(1))
    guard case .compare(let comparisonRequest) = compare else {
      Issue.record("Expected default comparison")
      return
    }
    #expect(comparisonRequest.current.id == .live(current.id))
    #expect(comparisonRequest.baseline.id == .durable(1))
  }

  @Test("Selecting a row overrides the baseline and selecting it again clears")
  func baselineSelectionToggle() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 3,
      payload: Data("live".utf8)
    )
    var state = HistoryFeature.State(pageSize: 20)
    guard
      case .loadPage(let requestID, let request) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-a",
            current: current
          )
        )
      )
    else {
      Issue.record("Expected initial load")
      return
    }
    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: requestID,
        request: request,
        page: HistoryPage(
          messages: [
            storedPublishedMessage(
              durableOrder: 3,
              payload: Data("published".utf8)
            ),
            storedMessage(
              durableOrder: 2,
              epoch: epoch,
              ordinal: 2,
              payload: Data("older".utf8)
            ),
          ],
          nextCursor: nil
        )
      )
    )
    #expect(state.effectiveBaselineID == .durable(3))

    let selected = HistoryFeature.reduce(
      state: &state,
      intent: .toggleBaseline(2)
    )
    #expect(state.selectedBaselineID == 2)
    #expect(state.effectiveBaselineID == .durable(2))
    guard case .compare(let selectedComparison) = selected else {
      Issue.record("Expected selected comparison")
      return
    }
    #expect(selectedComparison.baseline.id == .durable(2))

    let cleared = HistoryFeature.reduce(
      state: &state,
      intent: .toggleBaseline(2)
    )
    #expect(state.selectedBaselineID == nil)
    #expect(state.effectiveBaselineID == .durable(3))
    guard case .compare(let defaultComparison) = cleared else {
      Issue.record("Expected restored default comparison")
      return
    }
    #expect(defaultComparison.baseline.id == .durable(3))
    #expect(defaultComparison.baseline.direction == .published)
  }

  @Test("A stale page cannot replace a newer topic and source context")
  func stalePageIsIgnored() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let firstCurrent = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 1,
      payload: Data("first".utf8)
    )
    let secondCurrent = PayloadMessage(
      id: PayloadMessageID(
        connectionEpoch: epoch,
        ordinal: 2,
        direction: .received
      ),
      topicID: BrokerTopicID(
        brokerID: brokerID,
        fullTopic: "devices/other"
      ),
      receivedAtMicroseconds: 20,
      qos: .atLeastOnce,
      retained: false,
      payload: Data("second".utf8)
    )
    var state = HistoryFeature.State()
    guard
      case .loadPage(let firstID, let firstRequest) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-a",
            current: firstCurrent
          )
        )
      ),
      case .loadPage(let secondID, let secondRequest) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-b",
            current: secondCurrent
          )
        )
      )
    else {
      Issue.record("Expected both context loads")
      return
    }

    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: firstID,
        request: firstRequest,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 1,
              epoch: epoch,
              ordinal: 1,
              payload: Data("stale".utf8)
            )
          ],
          nextCursor: nil
        )
      )
    )
    #expect(state.rows.isEmpty)
    #expect(state.isLoading)

    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: secondID,
        request: secondRequest,
        page: HistoryPage(messages: [], nextCursor: nil)
      )
    )
    #expect(!state.isLoading)
    #expect(state.context?.historySourceID == "source-b")
    #expect(state.context?.current.topicID.fullTopic == "devices/other")
  }

  @Test("A stale diff cannot replace a newer baseline selection")
  func staleComparisonIsIgnored() async {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 3,
      payload: Data("current".utf8)
    )
    var state = HistoryFeature.State()
    guard
      case .loadPage(let pageRequestID, let pageRequest) =
        HistoryFeature.reduce(
          state: &state,
          intent: .contextChanged(
            HistoryContext(
              brokerID: brokerID,
              historySourceID: "source-a",
              current: current
            )
          )
        ),
      case .compare(let firstComparison) = HistoryFeature.reduce(
        state: &state,
        action: .pageLoaded(
          requestID: pageRequestID,
          request: pageRequest,
          page: HistoryPage(
            messages: [
              storedMessage(
                durableOrder: 2,
                epoch: epoch,
                ordinal: 2,
                payload: Data("previous".utf8)
              ),
              storedMessage(
                durableOrder: 1,
                epoch: epoch,
                ordinal: 1,
                payload: Data("oldest".utf8)
              ),
            ],
            nextCursor: nil
          )
        )
      ),
      case .compare(let secondComparison) = HistoryFeature.reduce(
        state: &state,
        intent: .toggleBaseline(1)
      )
    else {
      Issue.record("Expected page and comparison effects")
      return
    }
    let engine = PayloadComparisonEngine()
    let stale = await engine.compare(
      current: firstComparison.current,
      baseline: firstComparison.baseline
    )

    _ = HistoryFeature.reduce(
      state: &state,
      action: .comparisonFinished(
        requestID: firstComparison.requestID,
        selectionRevision: firstComparison.selectionRevision,
        comparison: stale
      )
    )
    #expect(state.comparison == nil)

    let newest = await engine.compare(
      current: secondComparison.current,
      baseline: secondComparison.baseline
    )
    _ = HistoryFeature.reduce(
      state: &state,
      action: .comparisonFinished(
        requestID: secondComparison.requestID,
        selectionRevision: secondComparison.selectionRevision,
        comparison: newest
      )
    )
    #expect(state.comparison?.baselineID == .durable(1))
  }

  @Test("A new live value preserves an explicit baseline without reloading")
  func liveUpdatePreservesExplicitBaseline() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 3,
      payload: Data("current".utf8)
    )
    var state = HistoryFeature.State()
    guard
      case .loadPage(let requestID, let request) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-a",
            current: current
          )
        )
      )
    else {
      Issue.record("Expected initial load")
      return
    }
    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: requestID,
        request: request,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 2,
              epoch: epoch,
              ordinal: 2,
              payload: Data("previous".utf8)
            ),
            storedMessage(
              durableOrder: 1,
              epoch: epoch,
              ordinal: 1,
              payload: Data("chosen".utf8)
            ),
          ],
          nextCursor: nil
        )
      )
    )
    _ = HistoryFeature.reduce(
      state: &state,
      intent: .toggleBaseline(1)
    )
    let newer = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 4,
      payload: Data("newer".utf8)
    )

    let effect = HistoryFeature.reduce(
      state: &state,
      intent: .contextChanged(
        HistoryContext(
          brokerID: brokerID,
          historySourceID: "source-a",
          current: newer
        )
      )
    )

    #expect(state.rows.map(\.id) == [2, 1])
    #expect(state.selectedBaselineID == 1)
    guard case .compare(let comparison) = effect else {
      Issue.record("Expected comparison without page reload")
      return
    }
    #expect(comparison.current.id == .live(newer.id))
    #expect(comparison.baseline.id == .durable(1))
  }

  @Test("Clearing an override after live updates uses the immediately prior live value")
  func clearingOverrideUsesLatestLatentDefault() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let first = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 3,
      payload: Data("first".utf8)
    )
    var state = HistoryFeature.State()
    guard
      case .loadPage(let requestID, let request) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-a",
            current: first
          )
        )
      )
    else {
      Issue.record("Expected initial load")
      return
    }
    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: requestID,
        request: request,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 2,
              epoch: epoch,
              ordinal: 2,
              payload: Data("chosen".utf8)
            )
          ],
          nextCursor: nil
        )
      )
    )
    _ = HistoryFeature.reduce(state: &state, intent: .toggleBaseline(2))
    let second = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 4,
      payload: Data("second".utf8)
    )
    _ = HistoryFeature.reduce(
      state: &state,
      intent: .contextChanged(
        HistoryContext(
          brokerID: brokerID,
          historySourceID: "source-a",
          current: second
        )
      )
    )
    let third = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 5,
      payload: Data("third".utf8)
    )
    _ = HistoryFeature.reduce(
      state: &state,
      intent: .contextChanged(
        HistoryContext(
          brokerID: brokerID,
          historySourceID: "source-a",
          current: third
        )
      )
    )

    let cleared = HistoryFeature.reduce(
      state: &state,
      intent: .toggleBaseline(2)
    )

    #expect(state.selectedBaselineID == nil)
    #expect(state.effectiveBaselineID == .live(second.id))
    guard case .compare(let comparison) = cleared else {
      Issue.record("Expected restored latent comparison")
      return
    }
    #expect(comparison.current.id == .live(third.id))
    #expect(comparison.baseline.id == .live(second.id))
    #expect(comparison.baseline.payload == second.payload)
  }

  @Test("Without an override a new live value compares to the prior live value")
  func liveUpdateUsesPriorLiveDefault() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 3,
      payload: Data("current".utf8)
    )
    var state = HistoryFeature.State()
    guard
      case .loadPage(let requestID, let request) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-a",
            current: current
          )
        )
      )
    else {
      Issue.record("Expected initial load")
      return
    }
    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: requestID,
        request: request,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 2,
              epoch: epoch,
              ordinal: 2,
              payload: Data("previous".utf8)
            )
          ],
          nextCursor: nil
        )
      )
    )
    let newer = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 4,
      payload: Data("newer".utf8)
    )

    let effect = HistoryFeature.reduce(
      state: &state,
      intent: .contextChanged(
        HistoryContext(
          brokerID: brokerID,
          historySourceID: "source-a",
          current: newer
        )
      )
    )

    #expect(state.selectedBaselineID == nil)
    #expect(state.effectiveBaselineID == .live(current.id))
    guard case .compare(let comparison) = effect else {
      Issue.record("Expected prior-live comparison")
      return
    }
    #expect(comparison.baseline.id == .live(current.id))
    #expect(comparison.baseline.payload == current.payload)
  }

  @Test("Paging keeps one bounded page and preserves elapsed-time boundaries")
  func boundedBidirectionalPaging() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 7,
      payload: Data("current".utf8)
    )
    var state = HistoryFeature.State(pageSize: 2)
    guard
      case .loadPage(let newestRequestID, let newestRequest) =
        HistoryFeature.reduce(
          state: &state,
          intent: .contextChanged(
            HistoryContext(
              brokerID: brokerID,
              historySourceID: "source-a",
              current: current
            )
          )
        )
    else {
      Issue.record("Expected newest-page request")
      return
    }
    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: newestRequestID,
        request: newestRequest,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 6,
              epoch: epoch,
              ordinal: 6,
              payload: Data("six".utf8)
            ),
            storedMessage(
              durableOrder: 5,
              epoch: epoch,
              ordinal: 5,
              payload: Data("five".utf8)
            ),
          ],
          nextCursor: 5
        )
      )
    )

    guard
      case .loadPage(let olderRequestID, let olderRequest) =
        HistoryFeature.reduce(state: &state, intent: .loadOlder)
    else {
      Issue.record("Expected older-page request")
      return
    }
    #expect(olderRequest.beforeDurableOrder == 5)
    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: olderRequestID,
        request: olderRequest,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 4,
              epoch: epoch,
              ordinal: 4,
              payload: Data("four".utf8)
            ),
            storedMessage(
              durableOrder: 3,
              epoch: epoch,
              ordinal: 3,
              payload: Data("three".utf8)
            ),
          ],
          nextCursor: 3
        )
      )
    )

    #expect(state.rows.map(\.id) == [4, 3])
    #expect(
      state.rows.map(\.elapsedToNewerMicroseconds) == [10, 10]
    )
    #expect(state.canLoadNewer)
    #expect(state.newerPagePositions.count == 1)

    guard
      case .loadPage(let newerRequestID, let newerRequest) =
        HistoryFeature.reduce(state: &state, intent: .loadNewer)
    else {
      Issue.record("Expected newer-page request")
      return
    }
    #expect(newerRequest.beforeDurableOrder == nil)
    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: newerRequestID,
        request: newerRequest,
        page: HistoryPage(
          messages: [
            storedMessage(
              durableOrder: 6,
              epoch: epoch,
              ordinal: 6,
              payload: Data("six".utf8)
            ),
            storedMessage(
              durableOrder: 5,
              epoch: epoch,
              ordinal: 5,
              payload: Data("five".utf8)
            ),
          ],
          nextCursor: 5
        )
      )
    )

    #expect(state.rows.map(\.id) == [6, 5])
    #expect(!state.canLoadNewer)
    #expect(state.newerPagePositions.isEmpty)
  }

  @Test("A wall-clock regression does not produce a negative elapsed interval")
  func clockRegressionHasUnknownElapsedInterval() {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 2,
      payload: Data("current".utf8)
    )
    var state = HistoryFeature.State()
    guard
      case .loadPage(let requestID, let request) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-a",
            current: current
          )
        )
      )
    else {
      Issue.record("Expected initial page request")
      return
    }
    let futureDatedRow = StoredHistoryMessage(
      durableOrder: 1,
      historySourceID: "source-a",
      connectionEpoch: epoch.rawValue,
      connectionOrdinal: 1,
      operationID: nil,
      direction: .received,
      topic: "devices/pump",
      qos: .atLeastOnce,
      retained: false,
      receivedAtMicroseconds: 30,
      payload: Data("future-dated".utf8)
    )

    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: requestID,
        request: request,
        page: HistoryPage(
          messages: [futureDatedRow],
          nextCursor: nil
        )
      )
    )

    #expect(state.rows.first?.elapsedToNewerMicroseconds == nil)
  }

  @Test(
    "Extreme timestamps cannot overflow elapsed calculation",
    arguments: [
      ExtremeTimestampCase(
        newer: .max,
        row: .min
      ),
      ExtremeTimestampCase(
        newer: .min,
        row: .max
      ),
    ]
  )
  fileprivate func extremeTimestampOverflow(testCase: ExtremeTimestampCase) {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = PayloadMessage(
      id: PayloadMessageID(
        connectionEpoch: epoch,
        ordinal: 2,
        direction: .received
      ),
      topicID: BrokerTopicID(
        brokerID: brokerID,
        fullTopic: "devices/pump"
      ),
      receivedAtMicroseconds: testCase.newer,
      qos: .atLeastOnce,
      retained: false,
      payload: Data("current".utf8)
    )
    let row = StoredHistoryMessage(
      durableOrder: 1,
      historySourceID: "source-a",
      connectionEpoch: epoch.rawValue,
      connectionOrdinal: 1,
      operationID: nil,
      direction: .received,
      topic: "devices/pump",
      qos: .atLeastOnce,
      retained: false,
      receivedAtMicroseconds: testCase.row,
      payload: Data("row".utf8)
    )
    var state = HistoryFeature.State()
    guard
      case .loadPage(let requestID, let request) = HistoryFeature.reduce(
        state: &state,
        intent: .contextChanged(
          HistoryContext(
            brokerID: brokerID,
            historySourceID: "source-a",
            current: current
          )
        )
      )
    else {
      Issue.record("Expected initial page request")
      return
    }

    _ = HistoryFeature.reduce(
      state: &state,
      action: .pageLoaded(
        requestID: requestID,
        request: request,
        page: HistoryPage(messages: [row], nextCursor: nil)
      )
    )

    #expect(state.rows.first?.elapsedToNewerMicroseconds == nil)
  }

  @MainActor
  @Test("The store loads a repository page and compares it asynchronously")
  func storeLoadsAndCompares() async {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 2,
      payload: Data("current".utf8)
    )
    let repository = FixedHistoryRepository(
      page: HistoryPage(
        messages: [
          storedMessage(
            durableOrder: 1,
            epoch: epoch,
            ordinal: 1,
            payload: Data("baseline".utf8)
          )
        ],
        nextCursor: nil
      )
    )
    let comparer = RecordingHistoryComparer()
    let store = HistoryStore(
      repositories: BrokerHistoryRepositoryProvider { _ in repository },
      comparer: comparer,
      clipboard: HistoryRecordingClipboard()
    )

    store.updateContext(
      HistoryContext(
        brokerID: brokerID,
        historySourceID: "source-a",
        current: current
      )
    )
    await waitUntil {
      store.state.comparison != nil
    }

    #expect(store.state.rows.map(\.id) == [1])
    #expect(store.state.comparison?.currentID == .live(current.id))
    #expect(store.state.comparison?.baselineID == .durable(1))
    #expect(
      await repository.requests() == [
        HistoryPageRequest(
          historySourceID: "source-a",
          topic: "devices/pump",
          limit: 50
        )
      ])
    #expect(await comparer.requests().map(\.baseline.id) == [.durable(1)])
  }

  @MainActor
  @Test("The store copies exact history bytes and exposes clipboard failure")
  func storeCopiesExactBytes() async {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let payload = Data([0, 255, 10, 42])
    let clipboard = HistoryRecordingClipboard()
    let repository = FixedHistoryRepository(
      page: HistoryPage(
        messages: [
          storedMessage(
            durableOrder: 1,
            epoch: epoch,
            ordinal: 1,
            payload: payload
          )
        ],
        nextCursor: nil
      )
    )
    let store = HistoryStore(
      repositories: BrokerHistoryRepositoryProvider { _ in repository },
      clipboard: clipboard
    )
    store.updateContext(
      HistoryContext(
        brokerID: brokerID,
        historySourceID: "source-a",
        current: payloadMessage(
          brokerID: brokerID,
          epoch: epoch,
          ordinal: 2,
          payload: Data("current".utf8)
        )
      )
    )
    await waitUntil {
      !store.state.rows.isEmpty
    }

    store.send(.copy(1))
    #expect(clipboard.contents == [.rawBytes(payload)])
    #expect(store.state.copyOutcome == .succeeded(1))

    clipboard.shouldFail = true
    store.send(.copy(1))
    #expect(clipboard.contents == [.rawBytes(payload)])
    #expect(store.state.copyOutcome == .failed(1))
  }

  @MainActor
  @Test("An equivalent context does not cancel the in-flight comparison")
  func equivalentContextKeepsComparison() async {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let current = payloadMessage(
      brokerID: brokerID,
      epoch: epoch,
      ordinal: 2,
      payload: Data("current".utf8)
    )
    let context = HistoryContext(
      brokerID: brokerID,
      historySourceID: "source-a",
      current: current
    )
    let repository = FixedHistoryRepository(
      page: HistoryPage(
        messages: [
          storedMessage(
            durableOrder: 1,
            epoch: epoch,
            ordinal: 1,
            payload: Data("baseline".utf8)
          )
        ],
        nextCursor: nil
      )
    )
    let comparer = SuspendedHistoryComparer()
    let store = HistoryStore(
      repositories: BrokerHistoryRepositoryProvider { _ in repository },
      comparer: comparer,
      clipboard: HistoryRecordingClipboard()
    )

    store.updateContext(context)
    for _ in 0..<10_000 {
      if await comparer.requestCount() == 1 {
        break
      }
      await Task.yield()
    }
    #expect(await comparer.requestCount() == 1)

    store.updateContext(context)
    await comparer.complete()
    await waitUntil {
      store.state.comparison != nil
    }

    #expect(store.state.comparison?.currentID == .live(current.id))
    #expect(store.state.comparison?.baselineID == .durable(1))
    #expect(await comparer.requestCount() == 1)
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<10_000 {
      if condition() {
        return
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for asynchronous history state")
  }

  private func payloadMessage(
    brokerID: UUID,
    epoch: ConnectionEpochID,
    ordinal: UInt64,
    payload: Data
  ) -> PayloadMessage {
    PayloadMessage(
      id: PayloadMessageID(
        connectionEpoch: epoch,
        ordinal: ordinal,
        direction: .received
      ),
      topicID: BrokerTopicID(
        brokerID: brokerID,
        fullTopic: "devices/pump"
      ),
      receivedAtMicroseconds: Int64(ordinal * 10),
      qos: .atLeastOnce,
      retained: false,
      payload: payload
    )
  }

  private func storedMessage(
    durableOrder: Int64,
    epoch: ConnectionEpochID,
    ordinal: UInt64,
    payload: Data
  ) -> StoredHistoryMessage {
    StoredHistoryMessage(
      durableOrder: durableOrder,
      historySourceID: "source-a",
      connectionEpoch: epoch.rawValue,
      connectionOrdinal: ordinal,
      operationID: nil,
      direction: .received,
      topic: "devices/pump",
      qos: .atLeastOnce,
      retained: false,
      receivedAtMicroseconds: Int64(ordinal * 10),
      payload: payload
    )
  }

  private func storedPublishedMessage(
    durableOrder: Int64,
    payload: Data
  ) -> StoredHistoryMessage {
    StoredHistoryMessage(
      durableOrder: durableOrder,
      historySourceID: "source-a",
      connectionEpoch: nil,
      connectionOrdinal: nil,
      operationID: PublishOperationID(),
      direction: .published,
      topic: "devices/pump",
      qos: .atLeastOnce,
      retained: false,
      receivedAtMicroseconds: durableOrder * 10,
      payload: payload
    )
  }
}

private actor FixedHistoryRepository: BrokerHistoryReading {
  private let result: HistoryPage
  private var recordedRequests: [HistoryPageRequest] = []

  init(page: HistoryPage) {
    self.result = page
  }

  func page(_ request: HistoryPageRequest) -> HistoryPage {
    recordedRequests.append(request)
    return result
  }

  func requests() -> [HistoryPageRequest] {
    recordedRequests
  }
}

private actor RecordingHistoryComparer: PayloadComparing {
  private let engine = PayloadComparisonEngine()
  private var recordedRequests:
    [(current: PayloadComparisonOperand, baseline: PayloadComparisonOperand)] =
      []

  func compare(
    current: PayloadComparisonOperand,
    baseline: PayloadComparisonOperand
  ) async -> PayloadComparison {
    recordedRequests.append((current, baseline))
    return await engine.compare(current: current, baseline: baseline)
  }

  func requests() -> [(current: PayloadComparisonOperand, baseline: PayloadComparisonOperand)] {
    recordedRequests
  }
}

private actor SuspendedHistoryComparer: PayloadComparing {
  private let engine = PayloadComparisonEngine()
  private var recordedCount = 0
  private var pending:
    (
      current: PayloadComparisonOperand,
      baseline: PayloadComparisonOperand,
      continuation: CheckedContinuation<PayloadComparison, Never>
    )?

  func compare(
    current: PayloadComparisonOperand,
    baseline: PayloadComparisonOperand
  ) async -> PayloadComparison {
    recordedCount += 1
    return await withCheckedContinuation { continuation in
      pending = (current, baseline, continuation)
    }
  }

  func requestCount() -> Int {
    recordedCount
  }

  func complete() async {
    guard let pending else { return }
    self.pending = nil
    let comparison = await engine.compare(
      current: pending.current,
      baseline: pending.baseline
    )
    pending.continuation.resume(returning: comparison)
  }
}

@MainActor
private final class HistoryRecordingClipboard: PayloadClipboardWriting {
  var contents: [PayloadClipboardContent] = []
  var shouldFail = false

  func write(_ content: PayloadClipboardContent) throws {
    if shouldFail {
      throw HistoryClipboardTestFailure()
    }
    contents.append(content)
  }
}

private struct HistoryClipboardTestFailure: Error {}

private struct ExtremeTimestampCase:
  Sendable,
  CustomTestStringConvertible
{
  let newer: Int64
  let row: Int64

  var testDescription: String {
    "newer-\(newer)-row-\(row)"
  }
}
