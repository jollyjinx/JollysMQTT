import Foundation

public struct PayloadComparisonLimits: Equatable, Sendable {
  public let maximumDifferences: Int
  public let maximumValuePreviewCharacters: Int
  public let maximumTextBytes: Int
  public let maximumTextLines: Int
  public let maximumTextLineCharacters: Int
  public let maximumHexBytes: Int

  public init(
    maximumDifferences: Int = 500,
    maximumValuePreviewCharacters: Int = 256,
    maximumTextBytes: Int = 262_144,
    maximumTextLines: Int = 1_000,
    maximumTextLineCharacters: Int = 512,
    maximumHexBytes: Int = 256
  ) {
    precondition(maximumDifferences > 0)
    precondition(maximumValuePreviewCharacters > 0)
    precondition(maximumTextBytes > 0)
    precondition(maximumTextLines > 0)
    precondition(maximumTextLineCharacters > 0)
    precondition(maximumHexBytes > 0)
    self.maximumDifferences = maximumDifferences
    self.maximumValuePreviewCharacters = maximumValuePreviewCharacters
    self.maximumTextBytes = maximumTextBytes
    self.maximumTextLines = maximumTextLines
    self.maximumTextLineCharacters = maximumTextLineCharacters
    self.maximumHexBytes = maximumHexBytes
  }
}

public enum PayloadJSONDifferenceChange: Equatable, Sendable {
  case added
  case removed
  case changed
}

public struct PayloadJSONDifference: Equatable, Identifiable, Sendable {
  public var id: PayloadJSONPointer { path }
  public let path: PayloadJSONPointer
  public let change: PayloadJSONDifferenceChange
  public let baselinePreview: String?
  public let currentPreview: String?
}

public struct PayloadJSONComparison: Equatable, Sendable {
  public let differences: [PayloadJSONDifference]
  public let isTruncated: Bool
}

public enum PayloadTextLineChange: Equatable, Sendable {
  case unchanged
  case removed
  case added
}

public struct PayloadTextLineDifference: Equatable, Identifiable, Sendable {
  public let id: Int
  public let change: PayloadTextLineChange
  public let lineNumber: Int?
  public let text: String
  public let isTruncated: Bool
}

public struct PayloadTextComparison: Equatable, Sendable {
  public let lines: [PayloadTextLineDifference]
  public let isTruncated: Bool
}

public struct PayloadByteComparison: Equatable, Sendable {
  public let baselineHex: String
  public let currentHex: String
  public let baselineByteCount: Int
  public let currentByteCount: Int
  public let comparedByteCount: Int
  public let differingByteCount: Int
  public let isTruncated: Bool
}

public enum PayloadComparisonPresentation: Equatable, Sendable {
  case json(PayloadJSONComparison)
  case text(PayloadTextComparison)
  case bytes(PayloadByteComparison)
}

public enum PayloadComparisonOperandID: Hashable, Sendable {
  case live(PayloadMessageID)
  case durable(Int64)
}

public struct PayloadComparisonOperand: Equatable, Sendable {
  public let id: PayloadComparisonOperandID
  public let direction: PayloadDeliveryDirection
  public let payload: Data

  public init(
    id: PayloadComparisonOperandID,
    direction: PayloadDeliveryDirection,
    payload: Data
  ) {
    self.id = id
    self.direction = direction
    self.payload = payload
  }

  public init(_ message: PayloadMessage) {
    self.init(
      id: .live(message.id),
      direction: message.direction,
      payload: message.payload
    )
  }
}

public struct PayloadComparison: Equatable, Sendable {
  public let currentID: PayloadComparisonOperandID
  public let baselineID: PayloadComparisonOperandID
  public let presentation: PayloadComparisonPresentation
}

public protocol PayloadComparing: Sendable {
  func compare(
    current: PayloadComparisonOperand,
    baseline: PayloadComparisonOperand
  ) async -> PayloadComparison
}

public actor PayloadComparisonEngine: PayloadComparing {
  private let limits: PayloadComparisonLimits
  private let inspector: PayloadInspector

  public init(limits: PayloadComparisonLimits = .init()) {
    self.limits = limits
    self.inspector = PayloadInspector()
  }

  public func compare(
    current: PayloadComparisonOperand,
    baseline: PayloadComparisonOperand
  ) async -> PayloadComparison {
    let currentPresentation = await inspector.presentation(
      for: current.payload
    )
    let baselinePresentation = await inspector.presentation(
      for: baseline.payload
    )
    let presentation: PayloadComparisonPresentation
    if case .json(let currentJSON) = currentPresentation,
      case .json(let baselineJSON) = baselinePresentation
    {
      presentation = .json(
        compareJSON(
          current: currentJSON.root,
          baseline: baselineJSON.root
        )
      )
    } else if case .text = currentPresentation,
      case .text = baselinePresentation
    {
      presentation = .text(
        compareText(current.payload, baseline.payload)
      )
    } else {
      presentation = .bytes(compareBytes(current.payload, baseline.payload))
    }
    return PayloadComparison(
      currentID: current.id,
      baselineID: baseline.id,
      presentation: presentation
    )
  }

  private func compareJSON(
    current: PayloadJSONValue,
    baseline: PayloadJSONValue
  ) -> PayloadJSONComparison {
    var differences: [PayloadJSONDifference] = []
    var isTruncated = false

    func append(
      path: PayloadJSONPointer,
      change: PayloadJSONDifferenceChange,
      baseline: PayloadJSONValue?,
      current: PayloadJSONValue?
    ) {
      guard differences.count < limits.maximumDifferences else {
        isTruncated = true
        return
      }
      differences.append(
        PayloadJSONDifference(
          path: path,
          change: change,
          baselinePreview: baseline.map(preview),
          currentPreview: current.map(preview)
        )
      )
    }

    func walk(
      current: PayloadJSONValue?,
      baseline: PayloadJSONValue?,
      path: PayloadJSONPointer
    ) {
      guard !isTruncated else { return }
      switch (current, baseline) {
      case (.some(let current), .none):
        append(
          path: path,
          change: .added,
          baseline: nil,
          current: current
        )
      case (.none, .some(let baseline)):
        append(
          path: path,
          change: .removed,
          baseline: baseline,
          current: nil
        )
      case (.some(.object(let current)), .some(.object(let baseline))):
        let currentValues = Dictionary(
          uniqueKeysWithValues: current.map { ($0.key, $0.value) }
        )
        let baselineValues = Dictionary(
          uniqueKeysWithValues: baseline.map { ($0.key, $0.value) }
        )
        for key in Set(currentValues.keys).union(baselineValues.keys).sorted() {
          walk(
            current: currentValues[key],
            baseline: baselineValues[key],
            path: path.appendingObjectKey(key)
          )
        }
      case (.some(.array(let current)), .some(.array(let baseline))):
        for index in 0..<max(current.count, baseline.count) {
          walk(
            current: current.indices.contains(index) ? current[index] : nil,
            baseline:
              baseline.indices.contains(index) ? baseline[index] : nil,
            path: path.appendingArrayIndex(index)
          )
        }
      case (.some(let current), .some(let baseline)):
        if current != baseline {
          append(
            path: path,
            change: .changed,
            baseline: baseline,
            current: current
          )
        }
      case (.none, .none):
        break
      }
    }

    walk(current: current, baseline: baseline, path: .root)
    return PayloadJSONComparison(
      differences: differences,
      isTruncated: isTruncated
    )
  }

  private func preview(_ value: PayloadJSONValue) -> String {
    let text =
      switch value {
      case .object(let members):
        "{\(members.count) members}"
      case .array(let values):
        "[\(values.count) items]"
      case .string(let value):
        String(reflecting: value)
      case .number(let value):
        value.foundationDescription
      case .boolean(let value):
        value ? "true" : "false"
      case .null:
        "null"
      }
    return String(text.prefix(limits.maximumValuePreviewCharacters))
  }

  private func compareBytes(
    _ current: Data,
    _ baseline: Data
  ) -> PayloadByteComparison {
    let compared = min(
      max(current.count, baseline.count),
      limits.maximumHexBytes
    )
    var differing = 0
    for index in 0..<compared {
      let currentByte = current.indices.contains(index) ? current[index] : nil
      let baselineByte =
        baseline.indices.contains(index) ? baseline[index] : nil
      if currentByte != baselineByte {
        differing += 1
      }
    }
    return PayloadByteComparison(
      baselineHex: hex(baseline.prefix(limits.maximumHexBytes)),
      currentHex: hex(current.prefix(limits.maximumHexBytes)),
      baselineByteCount: baseline.count,
      currentByteCount: current.count,
      comparedByteCount: compared,
      differingByteCount: differing,
      isTruncated:
        max(current.count, baseline.count) > limits.maximumHexBytes
    )
  }

  private func compareText(
    _ current: Data,
    _ baseline: Data
  ) -> PayloadTextComparison {
    let currentText = boundedText(current)
    let baselineText = boundedText(baseline)
    let currentLines = boundedLines(currentText.text)
    let baselineLines = boundedLines(baselineText.text)
    let difference = currentLines.lines.difference(
      from: baselineLines.lines
    )
    struct Change {
      let offset: Int
      let order: Int
      let lineNumber: Int
      let change: PayloadTextLineChange
      let text: String
    }
    var changes: [Change] = []
    changes.reserveCapacity(difference.count)
    for change in difference {
      switch change {
      case .remove(let offset, let element, _):
        changes.append(
          Change(
            offset: offset,
            order: 0,
            lineNumber: offset + 1,
            change: .removed,
            text: element
          )
        )
      case .insert(let offset, let element, _):
        changes.append(
          Change(
            offset: offset,
            order: 1,
            lineNumber: offset + 1,
            change: .added,
            text: element
          )
        )
      }
    }
    changes.sort {
      ($0.offset, $0.order) < ($1.offset, $1.order)
    }
    let boundedChanges = changes.prefix(limits.maximumDifferences)
    let rows = boundedChanges.enumerated().map { index, change in
      let preview = String(
        change.text.prefix(limits.maximumTextLineCharacters)
      )
      return PayloadTextLineDifference(
        id: index,
        change: change.change,
        lineNumber: change.lineNumber,
        text: preview,
        isTruncated: preview.count < change.text.count
      )
    }
    return PayloadTextComparison(
      lines: rows,
      isTruncated:
        currentText.isTruncated
        || baselineText.isTruncated
        || currentLines.isTruncated
        || baselineLines.isTruncated
        || changes.count > limits.maximumDifferences
        || rows.contains(where: \.isTruncated)
    )
  }

  private func boundedText(
    _ data: Data
  ) -> (text: String, isTruncated: Bool) {
    let prefix = data.prefix(limits.maximumTextBytes)
    var boundary = prefix.endIndex
    while boundary > prefix.startIndex,
      String(data: prefix[..<boundary], encoding: .utf8) == nil
    {
      boundary = prefix.index(before: boundary)
    }
    return (
      String(data: prefix[..<boundary], encoding: .utf8) ?? "",
      boundary < data.endIndex
    )
  }

  private func boundedLines(
    _ text: String
  ) -> (lines: [String], isTruncated: Bool) {
    let lines = text.split(
      separator: "\n",
      omittingEmptySubsequences: false
    )
    return (
      lines.prefix(limits.maximumTextLines).map(String.init),
      lines.count > limits.maximumTextLines
    )
  }

  private func hex(_ data: Data.SubSequence) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
  }
}
