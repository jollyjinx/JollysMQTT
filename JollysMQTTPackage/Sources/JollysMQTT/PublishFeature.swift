import Foundation
import JollysMQTTCore
import Observation

public enum PublishStatus: Equatable, Sendable {
  case idle
  case publishing(PublishOperationID)
  case succeeded(BrokerPublishSuccess)
  case rejected(BrokerPublishFailure)
}

public enum PublishFeature {
  public struct State: Equatable, Sendable {
    public fileprivate(set) var draft: PublishDraft
    public fileprivate(set) var topicWasManuallyEdited: Bool
    public fileprivate(set) var selectedTopic: String?
    public fileprivate(set) var status: PublishStatus
    public fileprivate(set) var history: PublishDraftHistory
    fileprivate var inFlightOperationID: PublishOperationID?

    public init(
      draft: PublishDraft = PublishDraft(),
      topicWasManuallyEdited: Bool = false,
      selectedTopic: String? = nil,
      status: PublishStatus = .idle,
      history: PublishDraftHistory = PublishDraftHistory()
    ) {
      self.draft = draft
      self.topicWasManuallyEdited = topicWasManuallyEdited
      self.selectedTopic = selectedTopic
      self.status = status
      self.history = history
      if case .publishing(let operationID) = status {
        self.inFlightOperationID = operationID
      } else {
        self.inFlightOperationID = nil
      }
    }

    public var isPublishing: Bool {
      inFlightOperationID != nil
    }

    fileprivate mutating func resetDraftStatus() {
      if !isPublishing {
        status = .idle
      }
    }
  }

  public enum Intent: Equatable, Sendable {
    case selectionChanged(String?)
    case editTopic(String)
    case followSelectedTopic
    case editPayload(String)
    case setInputMode(PublishInputMode)
    case setQoS(MQTTQualityOfService)
    case setRetain(Bool)
    case formatJSON
    case publish(PublishOperationID)
    case restoreHistory(PublishOperationID)
    case dismissStatus
  }

  public enum Action: Equatable, Sendable {
    case publishFinished(
      operationID: PublishOperationID,
      draft: PublishDraft,
      result: BrokerPublishResult
    )
  }

  public enum Effect: Equatable, Sendable {
    case publish(request: BrokerPublishRequest, draft: PublishDraft)
  }

  public static func reduce(
    state: inout State,
    intent: Intent
  ) -> Effect? {
    switch intent {
    case .selectionChanged(let topic):
      state.selectedTopic = topic
      guard let topic, !state.topicWasManuallyEdited else { return nil }
      state.draft = state.draft.replacing(topic: topic)
      return nil

    case .editTopic(let topic):
      state.draft = state.draft.replacing(topic: topic)
      state.topicWasManuallyEdited = true
      state.resetDraftStatus()
      return nil

    case .followSelectedTopic:
      state.topicWasManuallyEdited = false
      if let selectedTopic = state.selectedTopic {
        state.draft = state.draft.replacing(topic: selectedTopic)
      }
      state.resetDraftStatus()
      return nil

    case .editPayload(let source):
      state.draft = state.draft.replacing(payloadSource: source)
      state.resetDraftStatus()
      return nil

    case .setInputMode(let mode):
      state.draft = state.draft.replacing(inputMode: mode)
      state.resetDraftStatus()
      return nil

    case .setQoS(let qos):
      state.draft = state.draft.replacing(qos: qos)
      state.resetDraftStatus()
      return nil

    case .setRetain(let retain):
      state.draft = state.draft.replacing(retain: retain)
      state.resetDraftStatus()
      return nil

    case .formatJSON:
      do {
        state.draft = state.draft.replacing(
          payloadSource: try state.draft.formattedJSON()
        )
        state.resetDraftStatus()
      } catch let validation as PublishDraftValidationError {
        if !state.isPublishing {
          state.status = .rejected(.invalidDraft(validation))
        }
      } catch {
        if !state.isPublishing {
          state.status = .rejected(.invalidDraft(.invalidJSON))
        }
      }
      return nil

    case .publish(let operationID):
      guard !state.isPublishing else { return nil }
      let payload: Data
      do {
        payload = try state.draft.validatedRequestPayload()
      } catch let validation as PublishDraftValidationError {
        state.status = .rejected(.invalidDraft(validation))
        return nil
      } catch {
        state.status = .rejected(.invalidDraft(.invalidJSON))
        return nil
      }
      let request = BrokerPublishRequest(
        operationID: operationID,
        topic: state.draft.topic,
        payload: payload,
        qos: state.draft.qos,
        retain: state.draft.retain
      )
      state.inFlightOperationID = operationID
      state.status = .publishing(operationID)
      return .publish(request: request, draft: state.draft)

    case .restoreHistory(let operationID):
      guard
        let entry = state.history.entries.first(where: {
          $0.id == operationID
        })
      else {
        return nil
      }
      state.draft = entry.draft
      state.topicWasManuallyEdited = true
      state.resetDraftStatus()
      return nil

    case .dismissStatus:
      state.resetDraftStatus()
      return nil
    }
  }

  public static func reduce(
    state: inout State,
    action: Action
  ) {
    switch action {
    case .publishFinished(let operationID, let draft, let result):
      guard state.inFlightOperationID == operationID else { return }
      state.inFlightOperationID = nil
      switch result {
      case .success(let success):
        guard success.operationID == operationID else {
          state.status = .rejected(.transportUnavailable)
          return
        }
        state.history = state.history.recording(
          SuccessfulPublishDraft(
            id: success.operationID,
            draft: draft,
            completedAtMicroseconds: success.completedAtMicroseconds
          )
        )
        state.status = .succeeded(success)
      case .failure(let failure):
        state.status = .rejected(failure)
      }
    }
  }
}

@MainActor
@Observable
public final class PublishStore {
  public private(set) var state: PublishFeature.State

  private let publisher: any BrokerPublishing
  private let operationID: @MainActor @Sendable () -> PublishOperationID
  private var publishTask: Task<Void, Never>?

  public init(
    publisher: any BrokerPublishing,
    historyCapacity: Int = 20,
    operationID:
      @escaping @MainActor @Sendable () -> PublishOperationID = {
        PublishOperationID()
      }
  ) {
    self.publisher = publisher
    self.operationID = operationID
    self.state = PublishFeature.State(
      history: PublishDraftHistory(capacity: historyCapacity)
    )
  }

  public func send(_ intent: PublishFeature.Intent) {
    let effect = PublishFeature.reduce(state: &state, intent: intent)
    guard let effect else { return }
    switch effect {
    case .publish(let request, let draft):
      let publisher = publisher
      publishTask = Task { [weak self] in
        let result = await publisher.publish(request)
        guard let self else { return }
        PublishFeature.reduce(
          state: &state,
          action: .publishFinished(
            operationID: request.operationID,
            draft: draft,
            result: result
          )
        )
        publishTask = nil
      }
    }
  }

  public func publish() {
    send(.publish(operationID()))
  }

  func waitForPublishForTesting() async {
    await publishTask?.value
  }
}

extension PublishDraft {
  fileprivate func replacing(
    topic: String? = nil,
    payloadSource: String? = nil,
    inputMode: PublishInputMode? = nil,
    qos: MQTTQualityOfService? = nil,
    retain: Bool? = nil
  ) -> PublishDraft {
    PublishDraft(
      topic: topic ?? self.topic,
      payloadSource: payloadSource ?? self.payloadSource,
      inputMode: inputMode ?? self.inputMode,
      qos: qos ?? self.qos,
      retain: retain ?? self.retain
    )
  }
}
