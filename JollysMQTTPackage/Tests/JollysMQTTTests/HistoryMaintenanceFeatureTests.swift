import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("History maintenance feature")
struct HistoryMaintenanceFeatureTests {
  @Test("Equivalent live updates preserve drafts and surface external policy changes")
  func equivalentContextPreservesDraft() throws {
    let brokerID = UUID()
    let context = HistoryMaintenanceContext(
      brokerID: brokerID,
      brokerName: "Lab",
      historySourceID: "source",
      topic: "events"
    )
    var state = HistoryMaintenanceFeature.State()
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(context, .default)
    )
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .setTopicMessageLimit(77)
    )
    let external = try HistoryRetentionPolicy(
      topicMessageLimit: 88,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )

    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(context, external)
    )

    #expect(state.draft.topicMessageLimit == 77)
    #expect(state.savedPolicy == external)
    #expect(state.externalPolicyChanged)
  }

  @Test("A clean equivalent context adopts the latest policy")
  func cleanEquivalentContextRefreshesDraft() throws {
    let context = HistoryMaintenanceContext(
      brokerID: UUID(),
      brokerName: "Lab"
    )
    let latest = try HistoryRetentionPolicy(
      topicMessageLimit: 55,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    var state = HistoryMaintenanceFeature.State()
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(context, .default)
    )

    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(context, latest)
    )

    #expect(state.savedPolicy == latest)
    #expect(state.draft == HistoryRetentionDraft(latest))
    #expect(state.externalPolicyChanged == false)
  }

  @Test("Opening the sheet reloads a policy saved by another window")
  @MainActor
  func presentationRefreshesCrossWindowPolicy() throws {
    let brokerID = UUID()
    let settings = MemoryHistoryRetentionSettingsRepository()
    let store = HistoryMaintenanceStore(settings: settings)
    let context = HistoryMaintenanceContext(
      brokerID: brokerID,
      brokerName: "Lab"
    )
    store.updateContext(context)
    let latest = try HistoryRetentionPolicy(
      topicMessageLimit: 66,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    settings.save(latest, for: brokerID)

    store.send(.setPresented(true))

    #expect(store.state.savedPolicy == latest)
    #expect(store.state.draft == HistoryRetentionDraft(latest))
  }

  @Test("An old broker result cannot overwrite a newly selected broker")
  func staleEffectIsScoped() {
    let first = HistoryMaintenanceContext(
      brokerID: UUID(),
      brokerName: "First"
    )
    let second = HistoryMaintenanceContext(
      brokerID: UUID(),
      brokerName: "Second"
    )
    var state = HistoryMaintenanceFeature.State()
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(first, .default)
    )
    let effect = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .save
    )
    guard case .save(let requestID, let brokerID, let policy) = effect else {
      Issue.record("Expected a scoped save effect")
      return
    }
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(second, .default)
    )
    #expect(state.isWorking)
    #expect(
      HistoryMaintenanceFeature.reduce(
        state: &state,
        intent: .save
      ) == nil
    )
    HistoryMaintenanceFeature.reduce(
      state: &state,
      action: .settingsFinished(
        requestID: requestID,
        brokerID: brokerID,
        policy: policy,
        .applied(.empty)
      )
    )

    #expect(state.context == second)
    #expect(state.notice == nil)
    #expect(state.noticesByBroker[first.brokerID] != nil)
    #expect(state.isWorking == false)
  }

  @Test("Offline broker context supports settings and broker clear, not topic clear")
  func offlineBrokerScope() {
    let context = HistoryMaintenanceContext(
      brokerID: UUID(),
      brokerName: "Offline"
    )
    var saveState = HistoryMaintenanceFeature.State()
    _ = HistoryMaintenanceFeature.reduce(
      state: &saveState,
      intent: .contextChanged(context, .default)
    )
    #expect(
      HistoryMaintenanceFeature.reduce(
        state: &saveState,
        intent: .save
      ) != nil
    )

    var clearState = HistoryMaintenanceFeature.State()
    _ = HistoryMaintenanceFeature.reduce(
      state: &clearState,
      intent: .contextChanged(context, .default)
    )
    #expect(
      HistoryMaintenanceFeature.reduce(
        state: &clearState,
        intent: .requestClear(.topic)
      ) == nil
    )
    _ = HistoryMaintenanceFeature.reduce(
      state: &clearState,
      intent: .requestClear(.broker)
    )
    #expect(clearState.confirmation == .broker)
  }

  @Test("A partial clear blocks a fresh cutoff and keeps its continuation")
  func partialClearMustResume() {
    let context = HistoryMaintenanceContext(
      brokerID: UUID(),
      brokerName: "Lab",
      historySourceID: "source",
      topic: "events"
    )
    var state = HistoryMaintenanceFeature.State()
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(context, .default)
    )
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .requestClear(.broker)
    )
    let effect = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .confirmClear
    )
    guard case .clearBroker(let requestID, let brokerID) = effect else {
      Issue.record("Expected broker clear")
      return
    }
    let summary = HistoryClearSummary(
      deletedMessageCount: 1,
      deletedTopicCount: 0,
      deletedCoverageGapCount: 0,
      secureCleanupStatus: .notRequired
    )
    let outcome = HistoryClearOutcome(
      summary: summary,
      continuation: .broker(
        scope: HistoryBrokerClearScope(
          throughMessageOrder: 2,
          throughTopicOrder: 1,
          throughCoverageGapOrder: 0
        ),
        accumulated: summary
      ),
      interruption: .cancelled
    )
    HistoryMaintenanceFeature.reduce(
      state: &state,
      action: .clearFinished(
        requestID: requestID,
        brokerID: brokerID,
        outcome
      )
    )

    #expect(state.clearContinuation == outcome.continuation)
    #expect(
      HistoryMaintenanceFeature.reduce(
        state: &state,
        intent: .requestClear(.broker)
      ) == nil
    )
    #expect(state.confirmation == nil)

    let resume = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .resumeClear
    )
    guard case .resume(_, let resumedBrokerID, let continuation) = resume else {
      Issue.record("Expected the original continuation to resume")
      return
    }
    #expect(resumedBrokerID == context.brokerID)
    #expect(continuation == outcome.continuation)
  }

  @Test("Settings actions preserve committed-versus-precommit distinctions")
  func settingsOutcomeDistinctions() throws {
    let context = HistoryMaintenanceContext(
      brokerID: UUID(),
      brokerName: "Lab"
    )
    let policy = try HistoryRetentionPolicy(
      topicMessageLimit: 44,
      brokerByteLimit: 64 * 1_024 * 1_024,
      payloadByteLimit: 1_024,
      messagePruneBatchLimit: 10,
      vacuumPageLimit: 10
    )
    let outcomes: [HistorySettingsApplyOutcome] = [
      .applied(.empty),
      .appliedFileProtectionPending(.empty),
      .committedMaintenanceFailed(fileProtectionPending: false),
      .failed,
    ]

    for outcome in outcomes {
      var state = HistoryMaintenanceFeature.State()
      _ = HistoryMaintenanceFeature.reduce(
        state: &state,
        intent: .contextChanged(context, .default)
      )
      state.draft = HistoryRetentionDraft(policy)
      let effect = HistoryMaintenanceFeature.reduce(
        state: &state,
        intent: .save
      )
      guard case .save(let requestID, let brokerID, _) = effect else {
        Issue.record("Expected settings effect")
        continue
      }
      HistoryMaintenanceFeature.reduce(
        state: &state,
        action: .settingsFinished(
          requestID: requestID,
          brokerID: brokerID,
          policy: policy,
          outcome
        )
      )
      #expect(state.notice == .settings(outcome))
      if outcome == .failed {
        #expect(state.savedPolicy == .default)
      } else {
        #expect(state.savedPolicy == policy)
      }
    }
  }

  @Test("Secure cleanup retry has an explicit scoped result")
  func secureCleanupRetryResult() {
    let context = HistoryMaintenanceContext(
      brokerID: UUID(),
      brokerName: "Lab"
    )
    var state = HistoryMaintenanceFeature.State()
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(context, .default)
    )
    let effect = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .retrySecureCleanup
    )
    guard case .retrySecureCleanup(let requestID, let brokerID) = effect else {
      Issue.record("Expected secure-cleanup retry")
      return
    }
    HistoryMaintenanceFeature.reduce(
      state: &state,
      action: .secureCleanupFinished(
        requestID: requestID,
        brokerID: brokerID,
        true
      )
    )
    #expect(state.notice == .secureCleanupCompleted)
  }

  @Test("Applying retention reloads open history after committed pruning")
  @MainActor
  func applyRetentionReloadsHistory() async {
    let brokerID = UUID()
    let maintenance = PruningHistoryMaintenance()
    let store = HistoryMaintenanceStore(
      maintenance: BrokerHistoryMaintenanceProvider { _ in maintenance },
      settings: MemoryHistoryRetentionSettingsRepository()
    )
    var reloadedBrokerID: UUID?
    store.onHistoryCleared = { reloadedBrokerID = $0 }
    store.updateContext(
      HistoryMaintenanceContext(
        brokerID: brokerID,
        brokerName: "Lab"
      )
    )

    store.send(.save)
    for _ in 0..<100 where store.state.notice == nil {
      await Task.yield()
    }

    #expect(reloadedBrokerID == brokerID)
    #expect(store.state.notice != nil)
  }
}

extension HistoryMaintenanceReport {
  fileprivate static let empty = HistoryMaintenanceReport(
    deletedForTopicLimit: 0,
    deletedForBrokerLimit: 0,
    deletedOrphanTopicCount: 0,
    finalMessageCount: 0,
    finalSQLiteBytes: 0
  )
}

private actor PruningHistoryMaintenance: BrokerHistoryMaintaining {
  func retentionPolicy() -> HistoryRetentionPolicy { .default }
  func maintenanceStatus() -> HistoryMaintenanceStatus { .notRun }
  func applyRetention() -> HistoryMaintenanceReport {
    HistoryMaintenanceReport(
      deletedForTopicLimit: 1,
      deletedForBrokerLimit: 0,
      deletedOrphanTopicCount: 0,
      finalMessageCount: 0,
      finalSQLiteBytes: 0
    )
  }
  func clearTopicHistory(
    historySourceID: String,
    topic: String
  ) -> HistoryClearOutcome {
    .empty
  }
  func clearBrokerHistory() -> HistoryClearOutcome { .empty }
  func resumeHistoryClear(
    _ continuation: HistoryClearContinuation
  ) -> HistoryClearOutcome {
    .empty
  }
  func retrySecureCleanup() {}
}

extension HistoryClearOutcome {
  fileprivate static let empty = HistoryClearOutcome(
    summary: HistoryClearSummary(
      deletedMessageCount: 0,
      deletedTopicCount: 0,
      deletedCoverageGapCount: 0,
      secureCleanupStatus: .completed
    )
  )
}
