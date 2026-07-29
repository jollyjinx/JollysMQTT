import CoreFoundation
import Foundation

public enum PayloadDeliveryDirection: String, Codable, Equatable, Sendable {
  case received
  case published
}

public struct PayloadMessageID: Hashable, Sendable {
  public let connectionEpoch: ConnectionEpochID
  public let ordinal: UInt64
  public let direction: PayloadDeliveryDirection

  public init(
    connectionEpoch: ConnectionEpochID,
    ordinal: UInt64,
    direction: PayloadDeliveryDirection
  ) {
    self.connectionEpoch = connectionEpoch
    self.ordinal = ordinal
    self.direction = direction
  }
}

public struct PayloadMessage: Equatable, Sendable {
  public let id: PayloadMessageID
  public let topicID: BrokerTopicID
  public let receivedAtMicroseconds: Int64
  public let qos: MQTTQualityOfService
  public let retained: Bool
  public let payload: Data

  public var direction: PayloadDeliveryDirection { id.direction }
  public var payloadByteCount: Int { payload.count }

  public init(
    id: PayloadMessageID,
    topicID: BrokerTopicID,
    receivedAtMicroseconds: Int64,
    qos: MQTTQualityOfService,
    retained: Bool,
    payload: Data
  ) {
    self.id = id
    self.topicID = topicID
    self.receivedAtMicroseconds = receivedAtMicroseconds
    self.qos = qos
    self.retained = retained
    self.payload = payload
  }
}

public enum PayloadTopicSelection: Equatable, Sendable {
  case none
  case noCurrentValue(BrokerTopicID)
  case stale(BrokerTopicID)
  case current(PayloadMessage)

  public var topic: String? {
    switch self {
    case .none:
      nil
    case .noCurrentValue(let id), .stale(let id):
      id.fullTopic
    case .current(let message):
      message.topicID.fullTopic
    }
  }
}

extension BrokerTopicTreeSnapshot {
  public func payloadSelection(
    for topicID: BrokerTopicID?
  ) -> PayloadTopicSelection {
    guard let topicID else { return .none }
    return payloadSelection(
      brokerID: topicID.brokerID,
      fullTopic: topicID.fullTopic
    )
  }

  public func payloadSelection(
    brokerID: UUID?,
    fullTopic: String?
  ) -> PayloadTopicSelection {
    guard let fullTopic else { return .none }
    var pending = Array(roots.reversed())
    while let node = pending.popLast() {
      if node.fullTopic == fullTopic,
        brokerID == nil || node.id.brokerID == brokerID
      {
        if node.isStale {
          return .stale(node.id)
        }
        guard let latest = node.latest else {
          return .noCurrentValue(node.id)
        }
        return .current(
          PayloadMessage(
            id: PayloadMessageID(
              connectionEpoch: latest.connectionEpoch,
              ordinal: latest.ordinal,
              direction: .received
            ),
            topicID: node.id,
            receivedAtMicroseconds: latest.receivedAtMicroseconds,
            qos: latest.qos,
            retained: latest.retained,
            payload: latest.payload
          )
        )
      }
      pending.append(contentsOf: node.children.reversed())
    }
    return .none
  }
}

public struct PayloadInspectionLimits: Equatable, Sendable {
  public let maximumJSONBytes: Int
  public let maximumJSONDepth: Int
  public let maximumJSONNodeCount: Int
  public let maximumJSONNodePreviewCharacters: Int
  public let maximumTextPreviewBytes: Int
  public let maximumHexBytes: Int

  public init(
    maximumJSONBytes: Int = 1_048_576,
    maximumJSONDepth: Int = 64,
    maximumJSONNodeCount: Int = 10_000,
    maximumJSONNodePreviewCharacters: Int = 256,
    maximumTextPreviewBytes: Int = 65_536,
    maximumHexBytes: Int = 4_096
  ) {
    precondition(maximumJSONBytes >= 0)
    precondition(maximumJSONDepth > 0)
    precondition(maximumJSONNodeCount > 0)
    precondition(maximumJSONNodePreviewCharacters > 0)
    precondition(maximumTextPreviewBytes > 0)
    precondition(maximumHexBytes > 0)
    self.maximumJSONBytes = maximumJSONBytes
    self.maximumJSONDepth = maximumJSONDepth
    self.maximumJSONNodeCount = maximumJSONNodeCount
    self.maximumJSONNodePreviewCharacters =
      maximumJSONNodePreviewCharacters
    self.maximumTextPreviewBytes = maximumTextPreviewBytes
    self.maximumHexBytes = maximumHexBytes
  }
}

public enum PayloadInspectionNotice: Equatable, Sendable {
  case jsonByteLimitExceeded(limit: Int)
  case jsonDepthLimitExceeded(limit: Int)
  case jsonNodeLimitExceeded(limit: Int)
}

public struct PayloadTextPresentation: Equatable, Sendable {
  public let text: String
  public let completeText: String?
  public let isPreviewTruncated: Bool
  public let notice: PayloadInspectionNotice?

  public init(
    text: String,
    completeText: String? = nil,
    isPreviewTruncated: Bool = false,
    notice: PayloadInspectionNotice? = nil
  ) {
    self.text = text
    self.completeText = completeText ?? (isPreviewTruncated ? nil : text)
    self.isPreviewTruncated = isPreviewTruncated
    self.notice = notice
  }
}

public struct PayloadHexPresentation: Equatable, Sendable {
  public let text: String
  public let presentedByteCount: Int
  public let totalByteCount: Int

  public var isTruncated: Bool {
    presentedByteCount < totalByteCount
  }

  public init(
    text: String,
    presentedByteCount: Int,
    totalByteCount: Int
  ) {
    self.text = text
    self.presentedByteCount = presentedByteCount
    self.totalByteCount = totalByteCount
  }
}

public struct PayloadJSONPointer:
  RawRepresentable,
  Codable,
  Hashable,
  Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let root = PayloadJSONPointer(rawValue: "")

  public func appendingObjectKey(_ key: String) -> Self {
    let escaped =
      key
      .replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
    return .init(rawValue: rawValue + "/" + escaped)
  }

  public func appendingArrayIndex(_ index: Int) -> Self {
    .init(rawValue: rawValue + "/" + String(index))
  }
}

public struct PayloadJSONNumber: Equatable, Sendable {
  public let foundationDescription: String
  public let decimalValue: Decimal
  public let doubleValue: Double

  public init(
    foundationDescription: String,
    decimalValue: Decimal,
    doubleValue: Double
  ) {
    self.foundationDescription = foundationDescription
    self.decimalValue = decimalValue
    self.doubleValue = doubleValue
  }
}

public struct PayloadJSONObjectMember: Equatable, Sendable {
  public let key: String
  public let value: PayloadJSONValue

  public init(key: String, value: PayloadJSONValue) {
    self.key = key
    self.value = value
  }
}

public indirect enum PayloadJSONValue: Equatable, Sendable {
  case object([PayloadJSONObjectMember])
  case array([PayloadJSONValue])
  case string(String)
  case number(PayloadJSONNumber)
  case boolean(Bool)
  case null
}

public enum PayloadJSONNodeKind: Equatable, Sendable {
  case object
  case array
  case string
  case number
  case boolean
  case null
}

public struct PayloadJSONNode: Equatable, Identifiable, Sendable {
  public let id: PayloadJSONPointer
  public let parentID: PayloadJSONPointer?
  public let label: String
  public let labelIsTruncated: Bool
  public let pathPreview: String
  public let pathPreviewIsTruncated: Bool
  public let kind: PayloadJSONNodeKind
  public let depth: Int
  public let childCount: Int
  public let displayValue: String?
  public let displayValueIsTruncated: Bool

  public init(
    id: PayloadJSONPointer,
    parentID: PayloadJSONPointer?,
    label: String,
    labelIsTruncated: Bool,
    pathPreview: String,
    pathPreviewIsTruncated: Bool,
    kind: PayloadJSONNodeKind,
    depth: Int,
    childCount: Int,
    displayValue: String?,
    displayValueIsTruncated: Bool
  ) {
    self.id = id
    self.parentID = parentID
    self.label = label
    self.labelIsTruncated = labelIsTruncated
    self.pathPreview = pathPreview
    self.pathPreviewIsTruncated = pathPreviewIsTruncated
    self.kind = kind
    self.depth = depth
    self.childCount = childCount
    self.displayValue = displayValue
    self.displayValueIsTruncated = displayValueIsTruncated
  }
}

public struct PayloadJSONNumericPath: Equatable, Identifiable, Sendable {
  public var id: PayloadJSONPointer { path }
  public let path: PayloadJSONPointer
  public let value: PayloadJSONNumber

  public init(path: PayloadJSONPointer, value: PayloadJSONNumber) {
    self.path = path
    self.value = value
  }
}

public struct PayloadJSONDocument: Equatable, Sendable {
  public let rawText: String
  public let rawTextIsOriginalUTF8: Bool
  public let formattedText: String
  public let root: PayloadJSONValue
  public let nodes: [PayloadJSONNode]
  public let numericPaths: [PayloadJSONNumericPath]

  public init(
    rawText: String,
    rawTextIsOriginalUTF8: Bool,
    formattedText: String,
    root: PayloadJSONValue,
    nodes: [PayloadJSONNode],
    numericPaths: [PayloadJSONNumericPath]
  ) {
    self.rawText = rawText
    self.rawTextIsOriginalUTF8 = rawTextIsOriginalUTF8
    self.formattedText = formattedText
    self.root = root
    self.nodes = nodes
    self.numericPaths = numericPaths
  }

  public func formattedValue(at pointer: PayloadJSONPointer) -> String? {
    guard let value = value(at: pointer) else { return nil }
    return Self.formatted(value)
  }

  public func value(at pointer: PayloadJSONPointer) -> PayloadJSONValue? {
    if pointer == .root { return root }
    guard pointer.rawValue.first == "/" else { return nil }
    let components = pointer.rawValue.dropFirst().split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    var value = root
    for component in components {
      let decoded =
        component
        .replacingOccurrences(of: "~1", with: "/")
        .replacingOccurrences(of: "~0", with: "~")
      switch value {
      case .object(let members):
        guard let next = members.first(where: { $0.key == decoded })?.value
        else { return nil }
        value = next
      case .array(let values):
        guard let index = Int(decoded), values.indices.contains(index)
        else { return nil }
        value = values[index]
      case .string, .number, .boolean, .null:
        return nil
      }
    }
    return value
  }

  private static func formatted(_ value: PayloadJSONValue) -> String? {
    let object = foundationObject(value)
    guard
      JSONSerialization.isValidJSONObject(object)
        || !(value.isContainer),
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]
      )
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  fileprivate static func foundationObject(_ value: PayloadJSONValue) -> Any {
    switch value {
    case .object(let members):
      return Dictionary(
        uniqueKeysWithValues: members.map {
          ($0.key, foundationObject($0.value))
        }
      )
    case .array(let values):
      return values.map(foundationObject)
    case .string(let value):
      return value
    case .number(let number):
      return NSDecimalNumber(string: number.foundationDescription)
    case .boolean(let value):
      return value
    case .null:
      return NSNull()
    }
  }
}

extension PayloadJSONValue {
  fileprivate var isContainer: Bool {
    switch self {
    case .object, .array:
      true
    case .string, .number, .boolean, .null:
      false
    }
  }
}

public enum PayloadPresentation: Equatable, Sendable {
  case json(PayloadJSONDocument)
  case text(PayloadTextPresentation)
  case bytes(PayloadHexPresentation)
}

public struct PayloadInspection: Equatable, Sendable {
  public let message: PayloadMessage
  public let presentation: PayloadPresentation

  public init(message: PayloadMessage, presentation: PayloadPresentation) {
    self.message = message
    self.presentation = presentation
  }
}

public protocol PayloadInspecting: Sendable {
  func inspect(_ message: PayloadMessage) async -> PayloadInspection
}

public actor PayloadInspector: PayloadInspecting {
  private let limits: PayloadInspectionLimits

  public init(limits: PayloadInspectionLimits = .init()) {
    self.limits = limits
  }

  public func inspect(_ message: PayloadMessage) -> PayloadInspection {
    let presentation = presentation(for: message.payload)
    return PayloadInspection(message: message, presentation: presentation)
  }

  public func presentation(for data: Data) -> PayloadPresentation {
    var notice: PayloadInspectionNotice?
    if data.count <= limits.maximumJSONBytes {
      switch JSONNestingScanner.scan(
        data,
        maximumDepth: limits.maximumJSONDepth
      ) {
      case .withinLimit:
        switch makeJSONDocument(data) {
        case .document(let document):
          return .json(document)
        case .nodeLimitExceeded:
          notice = .jsonNodeLimitExceeded(
            limit: limits.maximumJSONNodeCount
          )
        case .notJSON:
          break
        }
      case .exceeded:
        notice = .jsonDepthLimitExceeded(
          limit: limits.maximumJSONDepth
        )
      }
    } else {
      notice = .jsonByteLimitExceeded(limit: limits.maximumJSONBytes)
    }

    if UTF8Validator.isValid(data) {
      let previewData = data.prefix(limits.maximumTextPreviewBytes)
      var boundary = previewData.endIndex
      while boundary > previewData.startIndex,
        String(data: previewData[..<boundary], encoding: .utf8) == nil
      {
        boundary = previewData.index(before: boundary)
      }
      let preview =
        String(data: previewData[..<boundary], encoding: .utf8) ?? ""
      let isTruncated = boundary < data.endIndex
      let completeText =
        data.count <= limits.maximumJSONBytes
        ? String(data: data, encoding: .utf8)
        : nil
      return .text(
        PayloadTextPresentation(
          text: preview,
          completeText: completeText,
          isPreviewTruncated: isTruncated,
          notice: notice
        )
      )
    }
    return .bytes(makeHex(data))
  }

  private enum JSONDocumentResult {
    case document(PayloadJSONDocument)
    case nodeLimitExceeded
    case notJSON
  }

  private func makeJSONDocument(_ data: Data) -> JSONDocumentResult {
    guard
      let object = try? JSONSerialization.jsonObject(
        with: data,
        options: [.fragmentsAllowed]
      )
    else {
      return .notJSON
    }
    var nodeCount = 0
    var nodes: [PayloadJSONNode] = []
    var numbers: [PayloadJSONNumericPath] = []
    guard
      let root = convert(
        object,
        path: .root,
        parentPath: nil,
        label: "$",
        depth: 0,
        nodeCount: &nodeCount,
        nodes: &nodes,
        numbers: &numbers
      )
    else {
      return .nodeLimitExceeded
    }
    let formattedData = try? JSONSerialization.data(
      withJSONObject: object,
      options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]
    )
    guard let formattedData,
      let formatted = String(data: formattedData, encoding: .utf8)
    else {
      return .notJSON
    }
    let sourceText = decodeJSONSourceText(data)
    let raw =
      sourceText?.text ?? String(decoding: formattedData, as: UTF8.self)
    return .document(
      PayloadJSONDocument(
        rawText: raw,
        rawTextIsOriginalUTF8: sourceText?.isUTF8 == true,
        formattedText: formatted,
        root: root,
        nodes: nodes,
        numericPaths: numbers
      ))
  }

  private func decodeJSONSourceText(
    _ data: Data
  ) -> (text: String, isUTF8: Bool)? {
    let prefix = Array(data.prefix(4))
    if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
      return String(data: data, encoding: .utf32BigEndian).map { ($0, false) }
    }
    if prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
      return String(data: data, encoding: .utf32LittleEndian).map {
        ($0, false)
      }
    }
    if prefix.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16BigEndian).map { ($0, false) }
    }
    if prefix.starts(with: [0xFF, 0xFE]) {
      return String(data: data, encoding: .utf16LittleEndian).map {
        ($0, false)
      }
    }
    if prefix.count >= 4 {
      if prefix[0] == 0, prefix[1] == 0, prefix[2] == 0 {
        return String(data: data, encoding: .utf32BigEndian).map { ($0, false) }
      }
      if prefix[1] == 0, prefix[2] == 0, prefix[3] == 0 {
        return String(data: data, encoding: .utf32LittleEndian).map {
          ($0, false)
        }
      }
      if prefix[0] == 0, prefix[2] == 0 {
        return String(data: data, encoding: .utf16BigEndian).map { ($0, false) }
      }
      if prefix[1] == 0, prefix[3] == 0 {
        return String(data: data, encoding: .utf16LittleEndian).map {
          ($0, false)
        }
      }
    }
    return String(data: data, encoding: .utf8).map { ($0, true) }
  }

  private func convert(
    _ object: Any,
    path: PayloadJSONPointer,
    parentPath: PayloadJSONPointer?,
    label: String,
    depth: Int,
    nodeCount: inout Int,
    nodes: inout [PayloadJSONNode],
    numbers: inout [PayloadJSONNumericPath]
  ) -> PayloadJSONValue? {
    nodeCount += 1
    guard nodeCount <= limits.maximumJSONNodeCount else { return nil }

    if let dictionary = object as? [String: Any] {
      let sorted = dictionary.keys.sorted()
      let nodeIndex = nodes.count
      nodes.append(
        makeNode(
          path: path,
          parentPath: parentPath,
          label: label,
          kind: .object,
          depth: depth,
          childCount: sorted.count,
          displayValue: nil
        )
      )
      var members: [PayloadJSONObjectMember] = []
      for key in sorted {
        guard
          let value = convert(
            dictionary[key] as Any,
            path: path.appendingObjectKey(key),
            parentPath: path,
            label: key,
            depth: depth + 1,
            nodeCount: &nodeCount,
            nodes: &nodes,
            numbers: &numbers
          )
        else {
          nodes.removeSubrange(nodeIndex...)
          return nil
        }
        members.append(.init(key: key, value: value))
      }
      return .object(members)
    }
    if let array = object as? [Any] {
      let nodeIndex = nodes.count
      nodes.append(
        makeNode(
          path: path,
          parentPath: parentPath,
          label: label,
          kind: .array,
          depth: depth,
          childCount: array.count,
          displayValue: nil
        )
      )
      var values: [PayloadJSONValue] = []
      for (index, object) in array.enumerated() {
        guard
          let value = convert(
            object,
            path: path.appendingArrayIndex(index),
            parentPath: path,
            label: String(index),
            depth: depth + 1,
            nodeCount: &nodeCount,
            nodes: &nodes,
            numbers: &numbers
          )
        else {
          nodes.removeSubrange(nodeIndex...)
          return nil
        }
        values.append(value)
      }
      return .array(values)
    }
    if object is NSNull {
      nodes.append(
        makeNode(
          path: path,
          parentPath: parentPath,
          label: label,
          kind: .null,
          depth: depth,
          childCount: 0,
          displayValue: "null"
        )
      )
      return .null
    }
    if let number = object as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        let value = number.boolValue
        nodes.append(
          makeNode(
            path: path,
            parentPath: parentPath,
            label: label,
            kind: .boolean,
            depth: depth,
            childCount: 0,
            displayValue: value ? "true" : "false"
          )
        )
        return .boolean(value)
      }
      let value = PayloadJSONNumber(
        foundationDescription: number.stringValue,
        decimalValue: number.decimalValue,
        doubleValue: number.doubleValue
      )
      nodes.append(
        makeNode(
          path: path,
          parentPath: parentPath,
          label: label,
          kind: .number,
          depth: depth,
          childCount: 0,
          displayValue: value.foundationDescription
        )
      )
      numbers.append(.init(path: path, value: value))
      return .number(value)
    }
    if let string = object as? String {
      nodes.append(
        makeNode(
          path: path,
          parentPath: parentPath,
          label: label,
          kind: .string,
          depth: depth,
          childCount: 0,
          displayValue: string
        )
      )
      return .string(string)
    }
    return nil
  }

  private func makeNode(
    path: PayloadJSONPointer,
    parentPath: PayloadJSONPointer?,
    label: String,
    kind: PayloadJSONNodeKind,
    depth: Int,
    childCount: Int,
    displayValue: String?
  ) -> PayloadJSONNode {
    let labelPreview = boundedNodePreview(label)
    let pathPreview = boundedNodePreview(path.rawValue)
    let valuePreview = displayValue.map(boundedNodePreview)
    return PayloadJSONNode(
      id: path,
      parentID: parentPath,
      label: labelPreview.text,
      labelIsTruncated: labelPreview.isTruncated,
      pathPreview: pathPreview.text,
      pathPreviewIsTruncated: pathPreview.isTruncated,
      kind: kind,
      depth: depth,
      childCount: childCount,
      displayValue: valuePreview?.text,
      displayValueIsTruncated: valuePreview?.isTruncated ?? false
    )
  }

  private func boundedNodePreview(
    _ value: String
  ) -> (text: String, isTruncated: Bool) {
    let limit = limits.maximumJSONNodePreviewCharacters
    let prefix = value.prefix(limit + 1)
    if prefix.count <= limit {
      return (value, false)
    }
    return (String(prefix.prefix(limit)), true)
  }

  private func makeHex(_ data: Data) -> PayloadHexPresentation {
    let bytes = data.prefix(limits.maximumHexBytes)
    var lines: [String] = []
    lines.reserveCapacity((bytes.count + 15) / 16)
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + 16, bytes.count)
      let values = bytes[offset..<end]
      let hex = values.map { String(format: "%02x", $0) }.joined(
        separator: " "
      )
      lines.append(String(format: "%08x  %@", offset, hex))
      offset = end
    }
    return PayloadHexPresentation(
      text: lines.joined(separator: "\n"),
      presentedByteCount: bytes.count,
      totalByteCount: data.count
    )
  }
}

private enum UTF8Validator {
  static func isValid(_ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
      validate(bytes)
    }
  }

  private static func validate(_ bytes: UnsafeRawBufferPointer) -> Bool {
    var index = 0
    while index < bytes.count {
      let first: UInt8 = bytes[index]
      if first <= 0x7F {
        index += 1
        continue
      }
      if first >= 0xC2, first <= 0xDF {
        guard continuation(bytes, at: index + 1) else { return false }
        index += 2
        continue
      }
      if first == 0xE0 {
        guard byte(bytes, at: index + 1, isIn: 0xA0...0xBF),
          continuation(bytes, at: index + 2)
        else { return false }
        index += 3
        continue
      }
      if (0xE1...0xEC).contains(first) || (0xEE...0xEF).contains(first) {
        guard continuation(bytes, at: index + 1),
          continuation(bytes, at: index + 2)
        else { return false }
        index += 3
        continue
      }
      if first == 0xED {
        guard byte(bytes, at: index + 1, isIn: 0x80...0x9F),
          continuation(bytes, at: index + 2)
        else { return false }
        index += 3
        continue
      }
      if first == 0xF0 {
        guard byte(bytes, at: index + 1, isIn: 0x90...0xBF),
          continuation(bytes, at: index + 2),
          continuation(bytes, at: index + 3)
        else { return false }
        index += 4
        continue
      }
      if (0xF1...0xF3).contains(first) {
        guard continuation(bytes, at: index + 1),
          continuation(bytes, at: index + 2),
          continuation(bytes, at: index + 3)
        else { return false }
        index += 4
        continue
      }
      if first == 0xF4 {
        guard byte(bytes, at: index + 1, isIn: 0x80...0x8F),
          continuation(bytes, at: index + 2),
          continuation(bytes, at: index + 3)
        else { return false }
        index += 4
        continue
      }
      return false
    }
    return true
  }

  private static func continuation(
    _ bytes: UnsafeRawBufferPointer,
    at index: Int
  ) -> Bool {
    byte(bytes, at: index, isIn: 0x80...0xBF)
  }

  private static func byte(
    _ bytes: UnsafeRawBufferPointer,
    at index: Int,
    isIn range: ClosedRange<UInt8>
  ) -> Bool {
    index >= 0 && index < bytes.count && range.contains(bytes[index])
  }
}

private enum JSONNestingScanner {
  enum Result {
    case withinLimit
    case exceeded
  }

  static func scan(_ data: Data, maximumDepth: Int) -> Result {
    var depth = 0
    var inString = false
    var isEscaped = false
    for byte in data {
      if inString {
        if isEscaped {
          isEscaped = false
        } else if byte == 0x5C {
          isEscaped = true
        } else if byte == 0x22 {
          inString = false
        }
        continue
      }
      if byte == 0x22 {
        inString = true
      } else if byte == 0x7B || byte == 0x5B {
        depth += 1
        if depth > maximumDepth { return .exceeded }
      } else if byte == 0x7D || byte == 0x5D {
        depth = max(0, depth - 1)
      }
    }
    return .withinLimit
  }
}
