import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

public struct HistoryMaintenanceContext: Equatable, Sendable {
  public let brokerID: UUID
  public let brokerName: String
  public let historySourceID: String?
  public let topic: String?

  public init(
    brokerID: UUID,
    brokerName: String,
    historySourceID: String? = nil,
    topic: String? = nil
  ) {
    self.brokerID = brokerID
    self.brokerName = brokerName
    self.historySourceID = historySourceID
    self.topic = topic
  }
}

public struct HistoryRetentionDraft: Equatable, Sendable {
  public var topicMessageLimit: Int
  public var brokerByteLimit: Int64
  public var payloadByteLimit: Int
  public var messagePruneBatchLimit: Int
  public var vacuumPageLimit: Int

  public init(_ policy: HistoryRetentionPolicy) {
    topicMessageLimit = policy.topicMessageLimit
    brokerByteLimit = policy.brokerByteLimit
    payloadByteLimit = policy.payloadByteLimit
    messagePruneBatchLimit = policy.messagePruneBatchLimit
    vacuumPageLimit = policy.vacuumPageLimit
  }

  public func validatedPolicy() throws -> HistoryRetentionPolicy {
    try HistoryRetentionPolicy(
      topicMessageLimit: topicMessageLimit,
      brokerByteLimit: brokerByteLimit,
      payloadByteLimit: payloadByteLimit,
      messagePruneBatchLimit: messagePruneBatchLimit,
      vacuumPageLimit: vacuumPageLimit
    )
  }
}

public enum HistorySettingsApplyOutcome: Equatable, Sendable {
  case applied(HistoryMaintenanceReport)
  case appliedFileProtectionPending(HistoryMaintenanceReport)
  case committedMaintenanceFailed(fileProtectionPending: Bool)
  case failed
}

public enum HistoryMaintenanceNotice: Equatable, Sendable {
  case settings(HistorySettingsApplyOutcome)
  case clear(HistoryClearOutcome)
  case clearFailed
  case secureCleanupCompleted
  case secureCleanupFailed
}

public enum HistoryClearConfirmation: Equatable, Sendable {
  case topic
  case broker
}

public enum HistoryMaintenanceFeature {
  public struct State: Equatable, Sendable {
    public var context: HistoryMaintenanceContext?
    public var savedPolicy: HistoryRetentionPolicy
    public var draft: HistoryRetentionDraft
    public var isPresented: Bool
    public var validationError: HistoryRetentionPolicyValidationError?
    public var confirmation: HistoryClearConfirmation?
    public var notice: HistoryMaintenanceNotice?
    public var clearContinuation: HistoryClearContinuation?
    public var externalPolicyChanged: Bool
    var nextRequestID: UInt64
    var activeRequest: HistoryMaintenanceRequest?
    var noticesByBroker: [UUID: HistoryMaintenanceNotice]
    var clearOutcomesByBroker: [UUID: HistoryClearOutcome]

    public init(policy: HistoryRetentionPolicy = .default) {
      context = nil
      savedPolicy = policy
      draft = HistoryRetentionDraft(policy)
      isPresented = false
      validationError = nil
      confirmation = nil
      notice = nil
      clearContinuation = nil
      externalPolicyChanged = false
      nextRequestID = 0
      activeRequest = nil
      noticesByBroker = [:]
      clearOutcomesByBroker = [:]
    }

    public var isWorking: Bool {
      activeRequest != nil
    }
  }

  public enum Intent: Equatable, Sendable {
    case contextChanged(
      HistoryMaintenanceContext?,
      HistoryRetentionPolicy
    )
    case setPresented(Bool)
    case setTopicMessageLimit(Int)
    case setBrokerByteLimit(Int64)
    case setPayloadByteLimit(Int)
    case setMessagePruneBatchLimit(Int)
    case setVacuumPageLimit(Int)
    case save
    case requestClear(HistoryClearConfirmation)
    case cancelClear
    case confirmClear
    case resumeClear
    case retrySecureCleanup
    case dismissNotice
  }

  public enum Action: Equatable, Sendable {
    case settingsFinished(
      requestID: UInt64,
      brokerID: UUID,
      policy: HistoryRetentionPolicy,
      HistorySettingsApplyOutcome
    )
    case clearFinished(
      requestID: UInt64,
      brokerID: UUID,
      HistoryClearOutcome
    )
    case clearFailed(requestID: UInt64, brokerID: UUID)
    case secureCleanupFinished(
      requestID: UInt64,
      brokerID: UUID,
      Bool
    )
  }

  public enum Effect: Equatable, Sendable {
    case save(
      requestID: UInt64,
      brokerID: UUID,
      HistoryRetentionPolicy
    )
    case clearTopic(
      requestID: UInt64,
      brokerID: UUID,
      historySourceID: String,
      topic: String
    )
    case clearBroker(requestID: UInt64, brokerID: UUID)
    case resume(
      requestID: UInt64,
      brokerID: UUID,
      HistoryClearContinuation
    )
    case retrySecureCleanup(requestID: UInt64, brokerID: UUID)
  }

  public static func reduce(
    state: inout State,
    intent: Intent
  ) -> Effect? {
    switch intent {
    case .contextChanged(let context, let policy):
      if state.context?.brokerID == context?.brokerID,
        state.context?.historySourceID == context?.historySourceID,
        state.context?.topic == context?.topic
      {
        let draftWasClean =
          state.draft == HistoryRetentionDraft(state.savedPolicy)
        state.context = context
        if policy != state.savedPolicy {
          state.savedPolicy = policy
          if draftWasClean {
            state.draft = HistoryRetentionDraft(policy)
            state.externalPolicyChanged = false
          } else {
            state.externalPolicyChanged = true
          }
        }
        return nil
      }
      state.context = context
      state.savedPolicy = policy
      state.draft = HistoryRetentionDraft(policy)
      state.validationError = nil
      state.confirmation = nil
      state.notice =
        context.flatMap { state.noticesByBroker[$0.brokerID] }
      state.clearContinuation =
        context.flatMap {
          state.clearOutcomesByBroker[$0.brokerID]?.continuation
        }
      state.externalPolicyChanged = false
      if context == nil {
        state.isPresented = false
      }
    case .setPresented(let isPresented):
      state.isPresented = isPresented && state.context != nil
      if !state.isPresented {
        state.confirmation = nil
      }
    case .setTopicMessageLimit(let value):
      state.draft.topicMessageLimit = value
      state.validationError = nil
    case .setBrokerByteLimit(let value):
      state.draft.brokerByteLimit = value
      state.validationError = nil
    case .setPayloadByteLimit(let value):
      state.draft.payloadByteLimit = value
      state.validationError = nil
    case .setMessagePruneBatchLimit(let value):
      state.draft.messagePruneBatchLimit = value
      state.validationError = nil
    case .setVacuumPageLimit(let value):
      state.draft.vacuumPageLimit = value
      state.validationError = nil
    case .save:
      guard let brokerID = state.context?.brokerID, !state.isWorking else {
        return nil
      }
      do {
        let policy = try state.draft.validatedPolicy()
        let requestID = beginRequest(brokerID: brokerID, state: &state)
        state.validationError = nil
        state.notice = nil
        return .save(
          requestID: requestID,
          brokerID: brokerID,
          policy
        )
      } catch let error as HistoryRetentionPolicyValidationError {
        state.validationError = error
      } catch {
        state.notice = .settings(.failed)
      }
    case .requestClear(let confirmation):
      guard state.context != nil, !state.isWorking else { return nil }
      guard state.clearContinuation == nil else { return nil }
      if confirmation == .topic {
        guard state.context?.historySourceID != nil,
          state.context?.topic != nil
        else { return nil }
      }
      state.confirmation = confirmation
    case .cancelClear:
      state.confirmation = nil
    case .confirmClear:
      guard let context = state.context, let confirmation = state.confirmation,
        !state.isWorking
      else { return nil }
      state.confirmation = nil
      let requestID = beginRequest(
        brokerID: context.brokerID,
        state: &state
      )
      state.notice = nil
      switch confirmation {
      case .topic:
        guard let historySourceID = context.historySourceID,
          let topic = context.topic
        else {
          state.activeRequest = nil
          return nil
        }
        return .clearTopic(
          requestID: requestID,
          brokerID: context.brokerID,
          historySourceID: historySourceID,
          topic: topic
        )
      case .broker:
        return .clearBroker(
          requestID: requestID,
          brokerID: context.brokerID
        )
      }
    case .resumeClear:
      guard let brokerID = state.context?.brokerID,
        let continuation = state.clearContinuation,
        !state.isWorking
      else { return nil }
      let requestID = beginRequest(brokerID: brokerID, state: &state)
      state.notice = nil
      return .resume(
        requestID: requestID,
        brokerID: brokerID,
        continuation
      )
    case .retrySecureCleanup:
      guard let brokerID = state.context?.brokerID, !state.isWorking else {
        return nil
      }
      let requestID = beginRequest(brokerID: brokerID, state: &state)
      return .retrySecureCleanup(
        requestID: requestID,
        brokerID: brokerID
      )
    case .dismissNotice:
      state.notice = nil
    }
    return nil
  }

  public static func reduce(
    state: inout State,
    action: Action
  ) {
    switch action {
    case .settingsFinished(
      let requestID,
      let brokerID,
      let policy,
      let outcome
    ):
      guard
        finishRequest(
          requestID: requestID,
          brokerID: brokerID,
          state: &state
        )
      else { return }
      state.noticesByBroker[brokerID] = .settings(outcome)
      guard state.context?.brokerID == brokerID else { return }
      switch outcome {
      case .applied, .appliedFileProtectionPending,
        .committedMaintenanceFailed:
        state.savedPolicy = policy
        state.draft = HistoryRetentionDraft(policy)
        state.externalPolicyChanged = false
      case .failed:
        break
      }
      state.notice = .settings(outcome)
    case .clearFinished(let requestID, let brokerID, let outcome):
      guard
        finishRequest(
          requestID: requestID,
          brokerID: brokerID,
          state: &state
        )
      else { return }
      state.clearOutcomesByBroker[brokerID] = outcome
      state.noticesByBroker[brokerID] = .clear(outcome)
      guard state.context?.brokerID == brokerID else { return }
      state.notice = .clear(outcome)
      state.clearContinuation = outcome.continuation
    case .clearFailed(let requestID, let brokerID):
      guard
        finishRequest(
          requestID: requestID,
          brokerID: brokerID,
          state: &state
        )
      else { return }
      state.noticesByBroker[brokerID] = .clearFailed
      guard state.context?.brokerID == brokerID else { return }
      state.notice = .clearFailed
    case .secureCleanupFinished(
      let requestID,
      let brokerID,
      let succeeded
    ):
      guard
        finishRequest(
          requestID: requestID,
          brokerID: brokerID,
          state: &state
        )
      else { return }
      let notice: HistoryMaintenanceNotice =
        succeeded ? .secureCleanupCompleted : .secureCleanupFailed
      state.noticesByBroker[brokerID] = notice
      guard state.context?.brokerID == brokerID else { return }
      state.notice =
        notice
    }
  }

  private static func beginRequest(
    brokerID: UUID,
    state: inout State
  ) -> UInt64 {
    state.nextRequestID &+= 1
    state.activeRequest = HistoryMaintenanceRequest(
      id: state.nextRequestID,
      brokerID: brokerID
    )
    return state.nextRequestID
  }

  private static func finishRequest(
    requestID: UInt64,
    brokerID: UUID,
    state: inout State
  ) -> Bool {
    guard
      state.activeRequest
        == HistoryMaintenanceRequest(id: requestID, brokerID: brokerID)
    else { return false }
    state.activeRequest = nil
    return true
  }
}

struct HistoryMaintenanceRequest: Equatable, Sendable {
  let id: UInt64
  let brokerID: UUID
}

@MainActor
@Observable
public final class HistoryMaintenanceStore {
  public private(set) var state: HistoryMaintenanceFeature.State
  public var onHistoryCleared: (@MainActor (UUID) -> Void)?

  private let maintenance: BrokerHistoryMaintenanceProvider
  private let settings: any HistoryRetentionSettingsRepositoryProtocol

  public init(
    maintenance: BrokerHistoryMaintenanceProvider = .empty,
    settings: any HistoryRetentionSettingsRepositoryProtocol =
      MemoryHistoryRetentionSettingsRepository()
  ) {
    self.maintenance = maintenance
    self.settings = settings
    state = .init()
  }

  public func updateContext(_ context: HistoryMaintenanceContext?) {
    let policy =
      context.map { settings.policy(for: $0.brokerID) } ?? .default
    _ = HistoryMaintenanceFeature.reduce(
      state: &state,
      intent: .contextChanged(context, policy)
    )
  }

  public func send(_ intent: HistoryMaintenanceFeature.Intent) {
    if case .setPresented(true) = intent, let context = state.context {
      _ = HistoryMaintenanceFeature.reduce(
        state: &state,
        intent: .contextChanged(
          context,
          settings.policy(for: context.brokerID)
        )
      )
    }
    guard
      let effect = HistoryMaintenanceFeature.reduce(
        state: &state,
        intent: intent
      )
    else { return }
    Task { await execute(effect) }
  }

  private func execute(_ effect: HistoryMaintenanceFeature.Effect) async {
    switch effect {
    case .save(let requestID, let brokerID, let policy):
      let protectionPending: Bool
      do {
        try await settings.save(policy, for: brokerID)
        protectionPending = false
      } catch LocalHistoryRetentionSettingsError.filePolicyAfterCommit {
        protectionPending = true
      } catch {
        HistoryMaintenanceFeature.reduce(
          state: &state,
          action: .settingsFinished(
            requestID: requestID,
            brokerID: brokerID,
            policy: policy,
            .failed
          )
        )
        return
      }
      do {
        let report = try await maintenance.repository(
          for: brokerID
        ).applyRetention()
        if report.deletedForTopicLimit > 0
          || report.deletedForBrokerLimit > 0
          || report.deletedOrphanTopicCount > 0
        {
          onHistoryCleared?(brokerID)
        }
        HistoryMaintenanceFeature.reduce(
          state: &state,
          action: .settingsFinished(
            requestID: requestID,
            brokerID: brokerID,
            policy: policy,
            protectionPending
              ? .appliedFileProtectionPending(report)
              : .applied(report)
          )
        )
      } catch {
        // Each retention step commits independently, so a later failure may
        // follow durable pruning.
        onHistoryCleared?(brokerID)
        HistoryMaintenanceFeature.reduce(
          state: &state,
          action: .settingsFinished(
            requestID: requestID,
            brokerID: brokerID,
            policy: policy,
            .committedMaintenanceFailed(
              fileProtectionPending: protectionPending
            )
          )
        )
      }
    case .clearTopic(
      let requestID,
      let brokerID,
      let historySourceID,
      let topic
    ):
      await performClear(requestID: requestID, brokerID: brokerID) {
        try await maintenance.repository(for: brokerID).clearTopicHistory(
          historySourceID: historySourceID,
          topic: topic
        )
      }
    case .clearBroker(let requestID, let brokerID):
      await performClear(requestID: requestID, brokerID: brokerID) {
        try await maintenance.repository(for: brokerID).clearBrokerHistory()
      }
    case .resume(let requestID, let brokerID, let continuation):
      await performClear(requestID: requestID, brokerID: brokerID) {
        try await maintenance.repository(for: brokerID).resumeHistoryClear(
          continuation
        )
      }
    case .retrySecureCleanup(let requestID, let brokerID):
      do {
        try await maintenance.repository(
          for: brokerID
        ).retrySecureCleanup()
        HistoryMaintenanceFeature.reduce(
          state: &state,
          action: .secureCleanupFinished(
            requestID: requestID,
            brokerID: brokerID,
            true
          )
        )
      } catch {
        HistoryMaintenanceFeature.reduce(
          state: &state,
          action: .secureCleanupFinished(
            requestID: requestID,
            brokerID: brokerID,
            false
          )
        )
      }
    }
  }

  private func performClear(
    requestID: UInt64,
    brokerID: UUID,
    _ operation: () async throws -> HistoryClearOutcome
  ) async {
    do {
      let outcome = try await operation()
      HistoryMaintenanceFeature.reduce(
        state: &state,
        action: .clearFinished(
          requestID: requestID,
          brokerID: brokerID,
          outcome
        )
      )
      if outcome.summary.deletedMessageCount > 0
        || outcome.summary.deletedTopicCount > 0
        || outcome.summary.deletedCoverageGapCount > 0
      {
        onHistoryCleared?(brokerID)
      }
    } catch {
      HistoryMaintenanceFeature.reduce(
        state: &state,
        action: .clearFailed(
          requestID: requestID,
          brokerID: brokerID
        )
      )
    }
  }
}
