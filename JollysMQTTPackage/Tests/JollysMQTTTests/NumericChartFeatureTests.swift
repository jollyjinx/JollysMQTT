import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("Numeric chart feature")
@MainActor
struct NumericChartFeatureTests {
  @Test("Pin eligibility accepts numeric and Boolean leaves")
  func pinEligibilityAcceptsSupportedLeaves() async {
    let brokerID = UUID()
    let inspector = PayloadInspector()
    let numberInspection = await inspector.inspect(
      payloadMessage(brokerID: brokerID, payload: Data("12.5".utf8))
    )
    let booleanInspection = await inspector.inspect(
      payloadMessage(
        brokerID: brokerID,
        payload: Data(#"{"enabled":true}"#.utf8)
      )
    )

    guard
      case .available(let numberSeries) =
        NumericChartPinEvaluator.availability(
          inspection: numberInspection,
          selectedJSONPointer: nil
        ),
      case .available(let booleanSeries) =
        NumericChartPinEvaluator.availability(
          inspection: booleanInspection,
          selectedJSONPointer: PayloadJSONPointer(rawValue: "/enabled")
        )
    else {
      Issue.record("Expected supported chart series")
      return
    }
    #expect(numberSeries.id.brokerID == brokerID)
    #expect(numberSeries.id.topic == "devices/pump")
    #expect(numberSeries.id.jsonPointer == nil)
    #expect(numberSeries.conversion.kind == .number)
    #expect(
      booleanSeries.id.jsonPointer
        == PayloadJSONPointer(rawValue: "/enabled")
    )
    #expect(booleanSeries.conversion.kind == .booleanAsZeroOrOne)

    let scaledPinnedSeries = NumericChartSeries(
      id: numberSeries.id,
      conversion: NumericChartValueConversion(
        kind: .number,
        multiplier: 10
      )
    )
    #expect(
      NumericChartPinStateEvaluator.isPinned(
        candidate: numberSeries,
        pinnedSeries: scaledPinnedSeries
      )
    )
  }

  @Test(
    "Pin eligibility rejects unavailable, non-JSON, container, string, null, and malformed selections"
  )
  func pinEligibilityExplainsUnsupportedSelections() async {
    let brokerID = UUID()
    let inspector = PayloadInspector()
    let text = await inspector.inspect(
      payloadMessage(brokerID: brokerID, payload: Data("not JSON".utf8))
    )
    let document = await inspector.inspect(
      payloadMessage(
        brokerID: brokerID,
        payload: Data(#"{"text":"x","nothing":null,"nested":{}}"#.utf8)
      )
    )

    #expect(
      NumericChartPinEvaluator.availability(
        inspection: nil,
        selectedJSONPointer: nil
      ) == .unavailable(.noCurrentPayload)
    )
    #expect(
      NumericChartPinEvaluator.availability(
        inspection: text,
        selectedJSONPointer: nil
      ) == .unavailable(.payloadIsNotJSON)
    )
    #expect(
      NumericChartPinEvaluator.availability(
        inspection: document,
        selectedJSONPointer: nil
      ) == .unavailable(.selectNumericLeaf)
    )
    #expect(
      NumericChartPinEvaluator.availability(
        inspection: document,
        selectedJSONPointer: PayloadJSONPointer(rawValue: "/text")
      ) == .unavailable(.selectedValueIsNotNumeric)
    )
    #expect(
      NumericChartPinEvaluator.availability(
        inspection: document,
        selectedJSONPointer: PayloadJSONPointer(rawValue: "/nothing")
      ) == .unavailable(.selectedValueIsNotNumeric)
    )
    #expect(
      NumericChartPinEvaluator.availability(
        inspection: document,
        selectedJSONPointer: PayloadJSONPointer(rawValue: "/nested")
      ) == .unavailable(.selectNumericLeaf)
    )
    #expect(
      NumericChartPinEvaluator.availability(
        inspection: document,
        selectedJSONPointer: PayloadJSONPointer(rawValue: "/bad~2pointer")
      ) == .unavailable(.invalidJSONPointer)
    )
  }

  @Test("Automatic Y domains stay finite for extreme finite samples")
  func automaticYDomainHandlesFiniteExtremes() {
    let epoch = UUID()
    let positive = NumericChartSample(
      id: NumericChartSampleID(
        connectionEpoch: epoch,
        ordinal: 1,
        direction: .received
      ),
      receivedAtMicroseconds: 1,
      value: .greatestFiniteMagnitude
    )
    let negative = NumericChartSample(
      id: NumericChartSampleID(
        connectionEpoch: epoch,
        ordinal: 2,
        direction: .received
      ),
      receivedAtMicroseconds: 2,
      value: -.greatestFiniteMagnitude
    )

    for samples in [[positive], [negative], [negative, positive]] {
      let domain = NumericChartDomain.automatic(for: samples)
      #expect(domain.lowerBound.isFinite)
      #expect(domain.upperBound.isFinite)
      #expect(domain.lowerBound < domain.upperBound)
      #expect(
        samples.allSatisfy {
          domain.contains($0.value)
        }
      )
    }
  }

  @Test("Auto-scroll advances the time domain while a fixed anchor remains stable")
  func visibleTimeDomainFollowsAutoScrollSetting() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(results: [:])
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    var chart = configuration(brokerID: brokerID)
    chart.visibleRange = try NumericChartVisibleRange(
      durationMicroseconds: 1_000_000
    )
    store.restore(chart)
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 1,
        timestamp: 2_000_000,
        value: 1
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1]
    }
    #expect(
      store.state.visibleTimeRangeMicroseconds
        == (1_000_000...2_000_000)
    )

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 2,
        timestamp: 3_000_000,
        value: 2
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1, 2]
    }
    #expect(
      store.state.visibleTimeRangeMicroseconds
        == (2_000_000...3_000_000)
    )

    store.send(.setAutoScroll(false))
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 3,
        timestamp: 4_000_000,
        value: 3
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1, 2, 3]
    }
    #expect(
      store.state.visibleTimeRangeMicroseconds
        == (2_000_000...3_000_000)
    )
  }

  @Test(
    "Restoration queries the current history source then deduplicates its live current message"
  )
  func restoresFromCurrentSourceWithoutDuplicatingLive() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(
      results: [
        "current-source": .init(
          messages: [
            storedMessage(
              source: "current-source",
              epoch: epoch,
              ordinal: 1,
              timestamp: 10,
              value: 1
            ),
            storedMessage(
              source: "current-source",
              epoch: epoch,
              ordinal: 2,
              timestamp: 10,
              value: 2
            ),
            storedMessage(
              source: "current-source",
              epoch: epoch,
              ordinal: 3,
              timestamp: 20,
              value: 3
            ),
          ],
          payloadByteCount: 3
        )
      ]
    )
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))

    let snapshot = await topicSnapshot(
      brokerID: brokerID,
      historySourceID: "current-source",
      epoch: epoch,
      ordinal: 3,
      timestamp: 20,
      value: 3
    )
    store.updateSnapshot(snapshot, expectedBrokerID: brokerID)

    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1, 2, 3]
    }

    #expect(
      await repository.requests().map(\.historySourceID)
        == ["current-source"]
    )
    #expect(store.state.samples.map(\.value) == [1, 2, 3])
    #expect(
      store.state.samples.map(\.receivedAtMicroseconds) == [10, 10, 20]
    )
    #expect(store.state.historySourceID == "current-source")
  }

  @Test("A history source change discards the prior source and reloads")
  func sourceChangeReplacesSamples() async throws {
    let brokerID = UUID()
    let firstEpoch = ConnectionEpochID()
    let secondEpoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(
      results: [
        "source-a": .init(
          messages: [
            storedMessage(
              source: "source-a",
              epoch: firstEpoch,
              ordinal: 1,
              timestamp: 10,
              value: 1
            )
          ],
          payloadByteCount: 1
        ),
        "source-b": .init(
          messages: [
            storedMessage(
              source: "source-b",
              epoch: secondEpoch,
              ordinal: 7,
              timestamp: 70,
              value: 7
            )
          ],
          payloadByteCount: 1
        ),
      ]
    )
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-a",
        epoch: firstEpoch,
        ordinal: 1,
        timestamp: 10,
        value: 1
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1]
    }

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-b",
        epoch: secondEpoch,
        ordinal: 7,
        timestamp: 70,
        value: 7
      ),
      expectedBrokerID: brokerID
    )
    #expect(store.state.samples.isEmpty)

    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [7]
    }
    #expect(store.state.historySourceID == "source-b")
    #expect(
      await repository.requests().map(\.historySourceID)
        == ["source-a", "source-b"]
    )
  }

  @Test("Paused restoration loads history and defers the cached live point")
  func pausedRestorationDefersLivePoint() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(
      results: [
        "source": .init(
          messages: [
            storedMessage(
              source: "source",
              epoch: epoch,
              ordinal: 1,
              timestamp: 10,
              value: 1
            )
          ],
          payloadByteCount: 1
        )
      ]
    )
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    var restored = configuration(brokerID: brokerID)
    restored.isPaused = true
    store.restore(restored)
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 2,
        timestamp: 20,
        value: 2
      ),
      expectedBrokerID: brokerID
    )

    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1]
    }
    #expect(store.state.configuration?.isPaused == true)

    store.send(.setPaused(false))
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1, 2]
    }

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 2,
        timestamp: 20,
        value: 2
      ),
      expectedBrokerID: brokerID
    )
    await Task.yield()
    #expect(store.state.samples.map(\.id.ordinal) == [1, 2])

    store.send(.setPaused(true))
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 4,
        timestamp: 40,
        value: 4
      ),
      expectedBrokerID: brokerID
    )
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 5,
        timestamp: 50,
        value: 5
      ),
      expectedBrokerID: brokerID
    )
    #expect(store.state.samples.map(\.id.ordinal) == [1, 2])

    store.send(.setPaused(false))
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1, 2, 5]
    }
  }

  @Test("A snapshot from another broker cannot attach the restored chart")
  func brokerMismatchDoesNotLoadOrAppend() async {
    let chartBrokerID = UUID()
    let repository = NumericChartHistoryRepository(results: [:])
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: chartBrokerID))

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: UUID(),
        historySourceID: "wrong-source",
        epoch: ConnectionEpochID(),
        ordinal: 1,
        timestamp: 10,
        value: 1
      ),
      expectedBrokerID: UUID()
    )
    await Task.yield()

    #expect(store.state.samples.isEmpty)
    #expect(store.state.historySourceID == nil)
    #expect(await repository.requests().isEmpty)
  }

  @Test("A stale delayed load cannot replace a newer history source")
  func staleLoadCompletionIsIgnored() async throws {
    let brokerID = UUID()
    let firstEpoch = ConnectionEpochID()
    let secondEpoch = ConnectionEpochID()
    let repository = ControlledNumericChartHistoryRepository()
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-a",
        epoch: firstEpoch,
        ordinal: 1,
        timestamp: 10,
        value: 1
      ),
      expectedBrokerID: brokerID
    )
    await waitUntilAsync {
      await repository.requestedSources() == ["source-a"]
    }

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-b",
        epoch: secondEpoch,
        ordinal: 7,
        timestamp: 70,
        value: 7
      ),
      expectedBrokerID: brokerID
    )
    await waitUntilAsync {
      await repository.requestedSources() == ["source-a", "source-b"]
    }

    await repository.complete(
      source: "source-b",
      result: .init(
        messages: [
          storedMessage(
            source: "source-b",
            epoch: secondEpoch,
            ordinal: 6,
            timestamp: 60,
            value: 6
          )
        ],
        payloadByteCount: 1
      )
    )
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [6, 7]
    }

    await repository.complete(
      source: "source-a",
      result: .init(
        messages: [
          storedMessage(
            source: "source-a",
            epoch: firstEpoch,
            ordinal: 1,
            timestamp: 10,
            value: 1
          )
        ],
        payloadByteCount: 1
      )
    )
    await Task.yield()
    #expect(store.state.historySourceID == "source-b")
    #expect(store.state.samples.map(\.id.ordinal) == [6, 7])
  }

  @Test("Unpinning or changing series invalidates an in-flight load")
  func configurationChangeInvalidatesLoad() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = ControlledNumericChartHistoryRepository()
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 2,
        timestamp: 20,
        value: 2
      ),
      expectedBrokerID: brokerID
    )
    await waitUntilAsync {
      await repository.requestedSources() == ["source"]
    }

    store.restore(nil)
    await repository.complete(
      source: "source",
      result: .init(
        messages: [
          storedMessage(
            source: "source",
            epoch: epoch,
            ordinal: 1,
            timestamp: 10,
            value: 1
          )
        ],
        payloadByteCount: 1
      )
    )
    await Task.yield()
    #expect(store.state.configuration == nil)
    #expect(store.state.samples.isEmpty)

    store.restore(configuration(brokerID: brokerID))
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-2",
        epoch: epoch,
        ordinal: 3,
        timestamp: 30,
        value: 3
      ),
      expectedBrokerID: brokerID
    )
    await waitUntilAsync {
      await repository.requestedSources().filter { $0 == "source-2" }.count
        == 1
    }
    var changed = configuration(brokerID: brokerID)
    changed = NumericChartConfiguration(
      series: NumericChartSeries(
        id: changed.series.id,
        conversion: NumericChartValueConversion(
          kind: .number,
          multiplier: 10
        )
      )
    )
    store.restore(changed)
    await waitUntilAsync {
      await repository.requestedSources().filter { $0 == "source-2" }.count
        == 2
    }
    await repository.complete(
      source: "source-2",
      result: .init(
        messages: [
          storedMessage(
            source: "source-2",
            epoch: epoch,
            ordinal: 2,
            timestamp: 20,
            value: 2
          )
        ],
        payloadByteCount: 1
      )
    )
    await Task.yield()
    #expect(store.state.samples.isEmpty)
    #expect(store.state.loadStatus == .loading)

    await repository.complete(
      source: "source-2",
      result: .init(
        messages: [
          storedMessage(
            source: "source-2",
            epoch: epoch,
            ordinal: 2,
            timestamp: 20,
            value: 2
          )
        ],
        payloadByteCount: 1
      )
    )
    await waitUntil {
      store.state.samples.map(\.value) == [20, 30]
    }
  }

  @Test("Only the newest pending live point survives a delayed history load")
  func delayedLoadKeepsOneNewestPendingPoint() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = ControlledNumericChartHistoryRepository()
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))

    for ordinal in 1...3 {
      store.updateSnapshot(
        await topicSnapshot(
          brokerID: brokerID,
          historySourceID: "source",
          epoch: epoch,
          ordinal: UInt64(ordinal),
          timestamp: Int64(ordinal * 10),
          value: ordinal
        ),
        expectedBrokerID: brokerID
      )
    }
    await waitUntilAsync {
      await repository.requestedSources() == ["source"]
    }
    await repository.complete(
      source: "source",
      result: .init(
        messages: [
          storedMessage(
            source: "source",
            epoch: epoch,
            ordinal: 1,
            timestamp: 10,
            value: 1
          )
        ],
        payloadByteCount: 1
      )
    )

    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1, 3]
    }
  }

  @Test("Losing the current history source detaches and clears samples")
  func nilHistorySourceDetachesChart() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(
      results: [
        "source": .init(
          messages: [
            storedMessage(
              source: "source",
              epoch: epoch,
              ordinal: 1,
              timestamp: 10,
              value: 1
            )
          ],
          payloadByteCount: 1
        )
      ]
    )
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 1,
        timestamp: 10,
        value: 1
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil { !store.state.samples.isEmpty }

    store.updateSnapshot(.empty, expectedBrokerID: nil)

    #expect(store.state.historySourceID == nil)
    #expect(store.state.samples.isEmpty)
  }

  @Test("Load failure is visible and a later snapshot can retry")
  func loadFailureAndRetry() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = FailingNumericChartHistoryRepository()
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))
    let snapshot = await topicSnapshot(
      brokerID: brokerID,
      historySourceID: "source",
      epoch: epoch,
      ordinal: 1,
      timestamp: 10,
      value: 1
    )

    store.updateSnapshot(snapshot, expectedBrokerID: brokerID)
    await waitUntil { store.state.loadStatus == .failed }
    #expect(store.state.samples.isEmpty)

    await repository.allowSuccess()
    store.send(.retry)
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1]
    }
    #expect(store.state.loadStatus == .loaded)
  }

  @Test("The empty repository supports a chart with no durable samples")
  func emptyRepositoryLoadsSafely() async throws {
    let brokerID = UUID()
    let store = NumericChartStore()
    store.restore(configuration(brokerID: brokerID))
    store.updateSnapshot(
      BrokerTopicTreeSnapshot(
        revision: 1,
        roots: [],
        totalMessageCount: 0,
        valueTopicCount: 0,
        historyIsHealthy: true,
        unpersistedMessageCount: 0,
        historySourceID: "source"
      ),
      expectedBrokerID: brokerID
    )

    await waitUntil { store.state.loadStatus == .loaded }
    #expect(store.state.samples.isEmpty)
  }

  @Test("Auto-scroll cannot be disabled before a fixed anchor exists")
  func autoScrollNeedsSampleAnchor() {
    let store = NumericChartStore()
    store.restore(configuration(brokerID: UUID()))

    store.send(.setAutoScroll(false))

    #expect(store.state.configuration?.autoScroll == true)
    #expect(
      store.state.configuration?.visibleRange.endingAtMicroseconds == nil
    )
  }

  @Test("History restores even when the pinned topic has no live current value")
  func historyLoadsWithoutCurrentValue() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(
      results: [
        "source": .init(
          messages: [
            storedMessage(
              source: "source",
              epoch: epoch,
              ordinal: 1,
              timestamp: 10,
              value: 1
            )
          ],
          payloadByteCount: 1
        )
      ]
    )
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))
    store.updateSnapshot(
      BrokerTopicTreeSnapshot(
        revision: 1,
        roots: [],
        totalMessageCount: 0,
        valueTopicCount: 0,
        historyIsHealthy: true,
        unpersistedMessageCount: 0,
        historySourceID: "source"
      ),
      expectedBrokerID: brokerID
    )

    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1]
    }
  }

  @Test("History and live buffers obey raw and visible-resolution caps")
  func rawAndDisplayBuffersAreBounded() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let policy = try NumericChartPolicy(
      maximumHistoryMessageCount: 8,
      maximumPayloadBytesPerSample: 64,
      maximumPayloadBytesPerLoad: 4_096,
      maximumJSONDepth: 8,
      maximumJSONNodeCount: 32,
      maximumRawSampleCount: 8,
      maximumDisplaySampleCount: 4
    )
    let repository = NumericChartHistoryRepository(results: [:])
    let store = NumericChartStore(
      repositories: .init { _ in repository },
      policy: policy
    )
    store.restore(configuration(brokerID: brokerID))
    store.send(.setPixelWidth(2))

    for ordinal in 1...20 {
      store.updateSnapshot(
        await topicSnapshot(
          brokerID: brokerID,
          historySourceID: "source",
          epoch: epoch,
          ordinal: UInt64(ordinal),
          timestamp: Int64(ordinal),
          value: ordinal
        ),
        expectedBrokerID: brokerID
      )
      await waitUntil {
        store.state.samples.last?.id.ordinal == UInt64(ordinal)
      }
    }
    await waitUntil {
      store.state.samples.last?.id.ordinal == 20
    }

    #expect(store.state.samples.count == 8)
    #expect(store.state.samples.map(\.id.ordinal) == Array(13...20))
    #expect(store.state.displaySamples.count <= 4)
    #expect(store.state.displaySamples.first?.id.ordinal == 13)
    #expect(store.state.displaySamples.last?.id.ordinal == 20)
  }

  @Test("The raw cap retains newest arrivals when the wall clock regresses")
  func rawCapUsesArrivalOrderBeforeChartOrdering() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let policy = try NumericChartPolicy(
      maximumHistoryMessageCount: 8,
      maximumPayloadBytesPerSample: 64,
      maximumPayloadBytesPerLoad: 4_096,
      maximumJSONDepth: 8,
      maximumJSONNodeCount: 32,
      maximumRawSampleCount: 8,
      maximumDisplaySampleCount: 8
    )
    let repository = NumericChartHistoryRepository(results: [:])
    let store = NumericChartStore(
      repositories: .init { _ in repository },
      policy: policy
    )
    store.restore(configuration(brokerID: brokerID))

    for ordinal in 1...8 {
      store.updateSnapshot(
        await topicSnapshot(
          brokerID: brokerID,
          historySourceID: "source",
          epoch: epoch,
          ordinal: UInt64(ordinal),
          timestamp: Int64(ordinal),
          value: ordinal
        ),
        expectedBrokerID: brokerID
      )
      await waitUntil {
        store.state.samples.last?.id.ordinal == UInt64(ordinal)
      }
    }
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 9,
        timestamp: 0,
        value: 9
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      store.state.samples.last?.id.ordinal == 9
    }

    #expect(store.state.samples.map(\.id.ordinal) == Array(2...9))
    #expect(
      store.state.visibleTimeRangeMicroseconds?.contains(0) == true
    )
    #expect(store.state.displaySamples.map(\.id.ordinal) == [9])
  }

  @Test("Wrong-topic history and snapshots cannot append")
  func onlyExactTopicCanAppend() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(
      results: [
        "source": .init(
          messages: [
            storedMessage(
              source: "source",
              epoch: epoch,
              ordinal: 1,
              timestamp: 10,
              value: 1,
              topic: "other/topic"
            )
          ],
          payloadByteCount: 1
        )
      ]
    )
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source",
        epoch: epoch,
        ordinal: 2,
        timestamp: 20,
        value: 2,
        topic: "other/topic"
      ),
      expectedBrokerID: brokerID
    )

    await waitUntil { store.state.loadStatus == .loaded }
    #expect(store.state.samples.isEmpty)
  }

  @Test("Older snapshot revisions cannot replace the newest pending live point")
  func staleSnapshotRevisionIsIgnored() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(results: [:])
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))
    let newest = await topicSnapshot(
      brokerID: brokerID,
      historySourceID: "source",
      epoch: epoch,
      ordinal: 2,
      timestamp: 20,
      value: 2,
      revision: 2
    )
    let stale = await topicSnapshot(
      brokerID: brokerID,
      historySourceID: "source",
      epoch: epoch,
      ordinal: 1,
      timestamp: 10,
      value: 1,
      revision: 1
    )

    store.updateSnapshot(newest, expectedBrokerID: brokerID)
    store.updateSnapshot(stale, expectedBrokerID: brokerID)

    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [2]
    }
  }

  @Test(
    "A persisted clear boundary rejects cleared durable and live samples while accepting newer clock-regressed arrivals"
  )
  func clearMarkerUsesDurableArrivalBoundary() async throws {
    let brokerID = UUID()
    let epoch = ConnectionEpochID()
    let repository = NumericChartHistoryRepository(
      results: [
        "source-a": .init(
          messages: [
            storedMessage(
              source: "source-a",
              epoch: epoch,
              ordinal: 1,
              timestamp: 100,
              value: 1
            ),
            storedMessage(
              source: "source-a",
              epoch: epoch,
              ordinal: 2,
              timestamp: 200,
              value: 2
            ),
          ],
          payloadByteCount: 2
        ),
        "source-b": .init(
          messages: [
            storedMessage(
              source: "source-b",
              epoch: epoch,
              ordinal: 1,
              timestamp: 100,
              value: 1
            ),
            storedMessage(
              source: "source-b",
              epoch: epoch,
              ordinal: 3,
              timestamp: 50,
              value: 3
            ),
            storedMessage(
              source: "source-b",
              epoch: epoch,
              ordinal: 4,
              timestamp: 25,
              value: 4
            ),
          ],
          payloadByteCount: 3
        ),
      ]
    )
    let store = NumericChartStore(
      repositories: .init { _ in repository }
    )
    store.restore(configuration(brokerID: brokerID))
    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-a",
        epoch: epoch,
        ordinal: 3,
        timestamp: 50,
        value: 3
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [1, 2, 3]
    }

    store.send(.clearDisplayedSamples)

    let cleared = try #require(store.state.configuration)
    #expect(store.state.samples.isEmpty)
    #expect(cleared.sampleClearMarker?.throughDurableOrder == 2)
    #expect(
      cleared.sampleClearMarker?.sampleIDs.map(\.ordinal) == [1, 2, 3]
    )

    store.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-a",
        epoch: epoch,
        ordinal: 4,
        timestamp: 25,
        value: 4
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      store.state.samples.map(\.id.ordinal) == [4]
    }

    let restored = NumericChartStore(
      repositories: .init { _ in repository }
    )
    restored.restore(cleared)
    restored.updateSnapshot(
      await topicSnapshot(
        brokerID: brokerID,
        historySourceID: "source-b",
        epoch: epoch,
        ordinal: 4,
        timestamp: 25,
        value: 4
      ),
      expectedBrokerID: brokerID
    )
    await waitUntil {
      restored.state.loadStatus == .loaded
    }

    #expect(restored.state.samples.map(\.id.ordinal) == [4])
    #expect(restored.state.samples.map(\.receivedAtMicroseconds) == [25])
  }

  private func configuration(
    brokerID: UUID
  ) -> NumericChartConfiguration {
    NumericChartConfiguration(
      series: NumericChartSeries(
        id: NumericChartSeriesID(
          brokerID: brokerID,
          topic: "devices/pump"
        ),
        conversion: NumericChartValueConversion(kind: .number)
      )
    )
  }

  private func payloadMessage(
    brokerID: UUID,
    payload: Data
  ) -> PayloadMessage {
    PayloadMessage(
      id: PayloadMessageID(
        connectionEpoch: ConnectionEpochID(),
        ordinal: 1,
        direction: .received
      ),
      topicID: BrokerTopicID(
        brokerID: brokerID,
        fullTopic: "devices/pump"
      ),
      receivedAtMicroseconds: 1,
      qos: .atMostOnce,
      retained: false,
      payload: payload
    )
  }

  private func storedMessage(
    source: String,
    epoch: ConnectionEpochID,
    ordinal: UInt64,
    timestamp: Int64,
    value: Int,
    topic: String = "devices/pump"
  ) -> StoredHistoryMessage {
    StoredHistoryMessage(
      durableOrder: Int64(ordinal),
      historySourceID: source,
      connectionEpoch: epoch.rawValue,
      connectionOrdinal: ordinal,
      operationID: nil,
      direction: .received,
      topic: topic,
      qos: .atMostOnce,
      retained: false,
      receivedAtMicroseconds: timestamp,
      payload: Data(String(value).utf8)
    )
  }

  private func topicSnapshot(
    brokerID: UUID,
    historySourceID: String,
    epoch: ConnectionEpochID,
    ordinal: UInt64,
    timestamp: Int64,
    value: Int,
    topic: String = "devices/pump",
    revision: UInt64? = nil
  ) async -> BrokerTopicTreeSnapshot {
    let ingestion = BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: historySourceID,
      historyWriter: DisabledBrokerHistoryWriter()
    )
    await ingestion.ingest(
      BrokerInboundMessage(
        connectionEpoch: epoch,
        ordinal: ordinal,
        topic: topic,
        payload: Data(String(value).utf8),
        qos: .atMostOnce,
        retained: false,
        duplicate: false,
        receivedAtMicroseconds: timestamp
      )
    )
    let snapshot = await ingestion.flush()
    guard let revision else { return snapshot }
    return BrokerTopicTreeSnapshot(
      revision: revision,
      roots: snapshot.roots,
      totalMessageCount: snapshot.totalMessageCount,
      valueTopicCount: snapshot.valueTopicCount,
      historyIsHealthy: snapshot.historyIsHealthy,
      unpersistedMessageCount: snapshot.unpersistedMessageCount,
      historySourceID: snapshot.historySourceID,
      connectionEpoch: snapshot.connectionEpoch,
      activeHistoryGap: snapshot.activeHistoryGap
    )
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("Timed out waiting for chart state")
  }

  private func waitUntilAsync(
    _ condition: @escaping @MainActor () async -> Bool
  ) async {
    for _ in 0..<1_000 {
      if await condition() { return }
      await Task.yield()
    }
    Issue.record("Timed out waiting for asynchronous chart state")
  }
}

private actor NumericChartHistoryRepository: BrokerHistoryReading {
  private let results: [String: NumericChartHistoryResult]
  private var recordedRequests: [NumericChartHistoryRequest] = []

  init(results: [String: NumericChartHistoryResult]) {
    self.results = results
  }

  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }

  func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) throws -> NumericChartHistoryResult {
    recordedRequests.append(request)
    return results[request.historySourceID]
      ?? NumericChartHistoryResult(messages: [], payloadByteCount: 0)
  }

  func requests() -> [NumericChartHistoryRequest] {
    recordedRequests
  }
}

private actor ControlledNumericChartHistoryRepository:
  BrokerHistoryReading
{
  private var continuations: [String: [CheckedContinuation<NumericChartHistoryResult, any Error>]] =
    [:]
  private var sources: [String] = []

  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }

  func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) async throws -> NumericChartHistoryResult {
    sources.append(request.historySourceID)
    return try await withCheckedThrowingContinuation { continuation in
      continuations[request.historySourceID, default: []].append(
        continuation
      )
    }
  }

  func requestedSources() -> [String] {
    sources
  }

  func complete(
    source: String,
    result: NumericChartHistoryResult
  ) {
    guard var pending = continuations[source],
      !pending.isEmpty
    else {
      return
    }
    let continuation = pending.removeFirst()
    continuations[source] = pending
    continuation.resume(returning: result)
  }
}

private actor FailingNumericChartHistoryRepository:
  BrokerHistoryReading
{
  private var shouldFail = true

  func page(_ request: HistoryPageRequest) -> HistoryPage {
    HistoryPage(messages: [], nextCursor: nil)
  }

  func numericChartHistory(
    _ request: NumericChartHistoryRequest
  ) throws -> NumericChartHistoryResult {
    if shouldFail {
      throw NumericChartHistoryTestFailure()
    }
    return NumericChartHistoryResult(messages: [], payloadByteCount: 0)
  }

  func allowSuccess() {
    shouldFail = false
  }
}

private struct NumericChartHistoryTestFailure: Error {}
