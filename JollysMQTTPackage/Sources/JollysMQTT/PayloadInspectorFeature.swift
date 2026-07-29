import Foundation
import JollysMQTTCore
import Observation

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

public enum PayloadInspectorLayout: Equatable, Sendable {
  case compact
  case wide
}

public enum PayloadInspectorJSONMode: Equatable, Sendable {
  case structure
  case raw
}

public enum PayloadInspectorCompactSection: Equatable, Sendable {
  case topics
  case details
  case chart
  case publish
}

public enum PayloadUnavailableReason: Equatable, Sendable {
  case noSelection
  case noCurrentValue
  case stale
}

public enum PayloadCopyAction: Equatable, Sendable {
  case topic
  case rawBytes
  case displayText
  case formattedJSON
  case selectedJSONValue
}

public enum PayloadClipboardContent: Equatable, Sendable {
  case text(String)
  case rawBytes(Data)
}

public enum PayloadCopyOutcome: Equatable, Sendable {
  case succeeded(PayloadCopyAction)
  case failed(PayloadCopyAction)
}

@MainActor
public protocol PayloadClipboardWriting: AnyObject {
  func write(_ content: PayloadClipboardContent) throws
}

@MainActor
public final class ApplePayloadClipboard: PayloadClipboardWriting {
  public init() {}

  public func write(_ content: PayloadClipboardContent) throws {
    #if canImport(AppKit)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      switch content {
      case .text(let text):
        guard pasteboard.setString(text, forType: .string) else {
          throw PayloadClipboardFailure()
        }
      case .rawBytes(let data):
        guard
          pasteboard.setData(
            data,
            forType: NSPasteboard.PasteboardType("public.data")
          )
        else {
          throw PayloadClipboardFailure()
        }
      }
    #elseif canImport(UIKit)
      switch content {
      case .text(let text):
        UIPasteboard.general.string = text
      case .rawBytes(let data):
        UIPasteboard.general.setData(
          data,
          forPasteboardType: "public.data"
        )
      }
    #else
      throw PayloadClipboardFailure()
    #endif
  }
}

private struct PayloadClipboardFailure: Error {}

public enum PayloadInspectorFeature {
  public struct State: Equatable, Sendable {
    public fileprivate(set) var layout: PayloadInspectorLayout
    public fileprivate(set) var jsonMode: PayloadInspectorJSONMode
    public fileprivate(set) var compactSection: PayloadInspectorCompactSection
    public fileprivate(set) var source: PayloadTopicSelection
    public fileprivate(set) var inspection: PayloadInspection?
    public fileprivate(set) var unavailableReason: PayloadUnavailableReason?
    public fileprivate(set) var isInspecting: Bool
    public fileprivate(set) var selectedJSONPointer: PayloadJSONPointer?
    public fileprivate(set) var selectedJSONValueText: String?
    public fileprivate(set) var copyOutcome: PayloadCopyOutcome?
    fileprivate var requestID: UInt64

    public init(layout: PayloadInspectorLayout = .wide) {
      self.layout = layout
      self.jsonMode = .structure
      self.compactSection = .topics
      self.source = .none
      self.inspection = nil
      self.unavailableReason = .noSelection
      self.isInspecting = false
      self.selectedJSONPointer = nil
      self.selectedJSONValueText = nil
      self.copyOutcome = nil
      self.requestID = 0
    }

    public var message: PayloadMessage? {
      inspection?.message
    }

    public func canCopy(_ action: PayloadCopyAction) -> Bool {
      copyContent(for: action) != nil
    }

    fileprivate func copyContent(
      for action: PayloadCopyAction
    ) -> PayloadClipboardContent? {
      switch action {
      case .topic:
        switch source {
        case .none:
          return nil
        case .noCurrentValue(let id), .stale(let id):
          return .text(id.fullTopic)
        case .current(let message):
          return .text(message.topicID.fullTopic)
        }
      case .rawBytes:
        return inspection.map { .rawBytes($0.message.payload) }
      case .displayText:
        switch inspection?.presentation {
        case .json(let document):
          return .text(document.rawText)
        case .text(let text):
          return text.completeText.map(PayloadClipboardContent.text)
        case .bytes, .none:
          return nil
        }
      case .formattedJSON:
        guard case .json(let document) = inspection?.presentation else {
          return nil
        }
        return .text(document.formattedText)
      case .selectedJSONValue:
        return selectedJSONValueText.map(PayloadClipboardContent.text)
      }
    }
  }

  public enum Intent: Equatable, Sendable {
    case selectionChanged(PayloadTopicSelection)
    case setLayout(PayloadInspectorLayout)
    case setJSONMode(PayloadInspectorJSONMode)
    case setCompactSection(PayloadInspectorCompactSection)
    case selectJSONValue(PayloadJSONPointer?)
    case copy(PayloadCopyAction)
    case dismissCopyOutcome
  }

  public enum Action: Equatable, Sendable {
    case inspectionFinished(
      requestID: UInt64,
      messageID: PayloadMessageID,
      inspection: PayloadInspection
    )
    case copyFinished(PayloadCopyOutcome)
  }

  public enum Effect: Equatable, Sendable {
    case inspect(requestID: UInt64, message: PayloadMessage)
    case copy(action: PayloadCopyAction, content: PayloadClipboardContent)
  }

  public static func reduce(
    state: inout State,
    intent: Intent
  ) -> Effect? {
    switch intent {
    case .selectionChanged(let source):
      guard source != state.source else { return nil }
      let preservesStableInspection =
        if case .current(let message) = source,
          let inspectedMessage = state.inspection?.message
        {
          inspectedMessage.topicID == message.topicID
            && inspectedMessage.id.connectionEpoch
              == message.id.connectionEpoch
            && inspectedMessage.direction == message.direction
        } else {
          false
        }
      state.requestID &+= 1
      state.source = source
      state.isInspecting = false
      if !preservesStableInspection {
        state.inspection = nil
        state.selectedJSONPointer = nil
        state.selectedJSONValueText = nil
        state.jsonMode = .structure
      }
      state.copyOutcome = nil
      switch source {
      case .none:
        state.unavailableReason = .noSelection
      case .noCurrentValue:
        state.unavailableReason = .noCurrentValue
      case .stale:
        state.unavailableReason = .stale
      case .current(let message):
        state.unavailableReason = nil
        state.isInspecting = true
        if !preservesStableInspection {
          state.compactSection = .details
        }
        return .inspect(requestID: state.requestID, message: message)
      }
      return nil

    case .setLayout(let layout):
      state.layout = layout
      return nil

    case .setJSONMode(let mode):
      guard case .json = state.inspection?.presentation else {
        return nil
      }
      state.jsonMode = mode
      return nil

    case .setCompactSection(let section):
      state.compactSection = section
      return nil

    case .selectJSONValue(let pointer):
      if let pointer {
        guard
          case .json(let document) = state.inspection?.presentation,
          document.nodes.contains(where: { $0.id == pointer })
        else {
          return nil
        }
      }
      state.selectedJSONPointer = pointer
      if let pointer,
        case .json(let document) = state.inspection?.presentation
      {
        state.selectedJSONValueText = document.formattedValue(at: pointer)
      } else {
        state.selectedJSONValueText = nil
      }
      return nil

    case .copy(let action):
      guard let content = state.copyContent(for: action) else {
        return nil
      }
      state.copyOutcome = nil
      return .copy(action: action, content: content)

    case .dismissCopyOutcome:
      state.copyOutcome = nil
      return nil
    }
  }

  public static func reduce(state: inout State, action: Action) {
    switch action {
    case .inspectionFinished(
      let requestID,
      let messageID,
      let inspection
    ):
      guard requestID == state.requestID,
        case .current(let current) = state.source,
        current.id == messageID,
        inspection.message.id == messageID
      else {
        return
      }
      state.inspection = inspection
      state.isInspecting = false
      if case .json(let document) = inspection.presentation {
        state.selectedJSONPointer = .root
        state.selectedJSONValueText = document.formattedText
      }
    case .copyFinished(let outcome):
      state.copyOutcome = outcome
    }
  }
}

@MainActor
@Observable
public final class PayloadInspectorStore {
  public private(set) var state: PayloadInspectorFeature.State

  private let inspector: any PayloadInspecting
  private let clipboard: any PayloadClipboardWriting
  private var inspectionTask: Task<Void, Never>?

  public init(
    inspector: any PayloadInspecting = PayloadInspector(),
    clipboard: any PayloadClipboardWriting = ApplePayloadClipboard(),
    layout: PayloadInspectorLayout = .wide
  ) {
    self.inspector = inspector
    self.clipboard = clipboard
    self.state = .init(layout: layout)
  }

  public func send(_ intent: PayloadInspectorFeature.Intent) {
    let priorSource = state.source
    let effect = PayloadInspectorFeature.reduce(
      state: &state,
      intent: intent
    )
    if case .selectionChanged = intent, state.source != priorSource {
      inspectionTask?.cancel()
      inspectionTask = nil
    }
    guard let effect else { return }
    switch effect {
    case .inspect(let requestID, let message):
      let inspector = inspector
      inspectionTask = Task { [weak self] in
        let inspection = await inspector.inspect(message)
        guard let self else { return }
        PayloadInspectorFeature.reduce(
          state: &state,
          action: .inspectionFinished(
            requestID: requestID,
            messageID: message.id,
            inspection: inspection
          )
        )
      }
    case .copy(let action, let content):
      do {
        try clipboard.write(content)
        PayloadInspectorFeature.reduce(
          state: &state,
          action: .copyFinished(.succeeded(action))
        )
      } catch {
        PayloadInspectorFeature.reduce(
          state: &state,
          action: .copyFinished(.failed(action))
        )
      }
    }
  }
}
