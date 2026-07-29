import Foundation

public enum NumericChartPolicyValidationError:
  Error,
  Equatable,
  Sendable
{
  case maximumHistoryMessageCount(Int)
  case maximumPayloadBytesPerSample(Int)
  case maximumPayloadBytesPerLoad(Int)
  case maximumJSONDepth(Int)
  case maximumJSONNodeCount(Int)
  case maximumRawSampleCount(Int)
  case maximumDisplaySampleCount(Int)
  case rawSamplesExceedHistoryMessages
  case displaySamplesExceedRawSamples
  case samplePayloadExceedsLoadPayload
}

public struct NumericChartPolicy: Equatable, Sendable {
  public static let maximumHistoryMessageCountBounds = 4...4_096
  public static let maximumPayloadBytesPerSampleBounds =
    1...65_536
  public static let maximumPayloadBytesPerLoadBounds =
    4_096...(16 * 1_024 * 1_024)
  public static let maximumJSONDepthBounds = 1...64
  public static let maximumJSONNodeCountBounds = 1...10_000
  public static let maximumRawSampleCountBounds = 4...10_000
  public static let maximumDisplaySampleCountBounds = 4...4_096

  public static let `default` = NumericChartPolicy(
    uncheckedMaximumHistoryMessageCount: 2_048,
    maximumPayloadBytesPerSample: 65_536,
    maximumPayloadBytesPerLoad: 8 * 1_024 * 1_024,
    maximumJSONDepth: 32,
    maximumJSONNodeCount: 512,
    maximumRawSampleCount: 2_048,
    maximumDisplaySampleCount: 1_024
  )

  public let maximumHistoryMessageCount: Int
  public let maximumPayloadBytesPerSample: Int
  public let maximumPayloadBytesPerLoad: Int
  public let maximumJSONDepth: Int
  public let maximumJSONNodeCount: Int
  public let maximumRawSampleCount: Int
  public let maximumDisplaySampleCount: Int

  public init(
    maximumHistoryMessageCount: Int,
    maximumPayloadBytesPerSample: Int,
    maximumPayloadBytesPerLoad: Int,
    maximumJSONDepth: Int,
    maximumJSONNodeCount: Int,
    maximumRawSampleCount: Int,
    maximumDisplaySampleCount: Int
  ) throws {
    guard
      Self.maximumHistoryMessageCountBounds.contains(
        maximumHistoryMessageCount
      )
    else {
      throw NumericChartPolicyValidationError.maximumHistoryMessageCount(
        maximumHistoryMessageCount
      )
    }
    guard
      Self.maximumPayloadBytesPerSampleBounds.contains(
        maximumPayloadBytesPerSample
      )
    else {
      throw NumericChartPolicyValidationError.maximumPayloadBytesPerSample(
        maximumPayloadBytesPerSample
      )
    }
    guard
      Self.maximumPayloadBytesPerLoadBounds.contains(
        maximumPayloadBytesPerLoad
      )
    else {
      throw NumericChartPolicyValidationError.maximumPayloadBytesPerLoad(
        maximumPayloadBytesPerLoad
      )
    }
    guard Self.maximumJSONDepthBounds.contains(maximumJSONDepth) else {
      throw NumericChartPolicyValidationError.maximumJSONDepth(
        maximumJSONDepth
      )
    }
    guard Self.maximumJSONNodeCountBounds.contains(maximumJSONNodeCount) else {
      throw NumericChartPolicyValidationError.maximumJSONNodeCount(
        maximumJSONNodeCount
      )
    }
    guard Self.maximumRawSampleCountBounds.contains(maximumRawSampleCount) else {
      throw NumericChartPolicyValidationError.maximumRawSampleCount(
        maximumRawSampleCount
      )
    }
    guard
      Self.maximumDisplaySampleCountBounds.contains(
        maximumDisplaySampleCount
      )
    else {
      throw NumericChartPolicyValidationError.maximumDisplaySampleCount(
        maximumDisplaySampleCount
      )
    }
    guard maximumRawSampleCount <= maximumHistoryMessageCount else {
      throw NumericChartPolicyValidationError.rawSamplesExceedHistoryMessages
    }
    guard maximumDisplaySampleCount <= maximumRawSampleCount else {
      throw NumericChartPolicyValidationError.displaySamplesExceedRawSamples
    }
    guard maximumPayloadBytesPerSample <= maximumPayloadBytesPerLoad else {
      throw NumericChartPolicyValidationError.samplePayloadExceedsLoadPayload
    }
    self.init(
      uncheckedMaximumHistoryMessageCount: maximumHistoryMessageCount,
      maximumPayloadBytesPerSample: maximumPayloadBytesPerSample,
      maximumPayloadBytesPerLoad: maximumPayloadBytesPerLoad,
      maximumJSONDepth: maximumJSONDepth,
      maximumJSONNodeCount: maximumJSONNodeCount,
      maximumRawSampleCount: maximumRawSampleCount,
      maximumDisplaySampleCount: maximumDisplaySampleCount
    )
  }

  private init(
    uncheckedMaximumHistoryMessageCount maximumHistoryMessageCount: Int,
    maximumPayloadBytesPerSample: Int,
    maximumPayloadBytesPerLoad: Int,
    maximumJSONDepth: Int,
    maximumJSONNodeCount: Int,
    maximumRawSampleCount: Int,
    maximumDisplaySampleCount: Int
  ) {
    self.maximumHistoryMessageCount = maximumHistoryMessageCount
    self.maximumPayloadBytesPerSample = maximumPayloadBytesPerSample
    self.maximumPayloadBytesPerLoad = maximumPayloadBytesPerLoad
    self.maximumJSONDepth = maximumJSONDepth
    self.maximumJSONNodeCount = maximumJSONNodeCount
    self.maximumRawSampleCount = maximumRawSampleCount
    self.maximumDisplaySampleCount = maximumDisplaySampleCount
  }

  public func maximumDisplaySampleCount(
    forPixelWidth pixelWidth: Double
  ) -> Int {
    guard pixelWidth.isFinite else {
      return maximumDisplaySampleCount
    }
    let boundedWidth = max(
      4,
      min(Double(maximumDisplaySampleCount), pixelWidth.rounded(.down))
    )
    return Int(boundedWidth)
  }
}

public struct NumericChartSeriesID:
  Codable,
  Equatable,
  Hashable,
  Sendable
{
  public let brokerID: UUID
  public let topic: String
  public let jsonPointer: PayloadJSONPointer?

  public init(
    brokerID: UUID,
    topic: String,
    jsonPointer: PayloadJSONPointer? = nil
  ) {
    precondition(Self.isValidTopic(topic))
    precondition(jsonPointer.map(Self.isCanonicalJSONLeafPointer) ?? true)
    self.brokerID = brokerID
    self.topic = topic
    self.jsonPointer = jsonPointer
  }

  private enum CodingKeys: String, CodingKey {
    case brokerID
    case topic
    case jsonPointer
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let brokerID = try values.decode(UUID.self, forKey: .brokerID)
    let topic = try values.decode(String.self, forKey: .topic)
    let jsonPointer = try values.decodeIfPresent(
      PayloadJSONPointer.self,
      forKey: .jsonPointer
    )
    guard Self.isValidTopic(topic) else {
      throw DecodingError.dataCorruptedError(
        forKey: .topic,
        in: values,
        debugDescription: "A chart topic must be a valid MQTT publication topic."
      )
    }
    guard jsonPointer.map(Self.isCanonicalJSONLeafPointer) ?? true else {
      throw DecodingError.dataCorruptedError(
        forKey: .jsonPointer,
        in: values,
        debugDescription:
          "A chart JSON pointer must be a nonroot canonical JSON Pointer."
      )
    }
    self.brokerID = brokerID
    self.topic = topic
    self.jsonPointer = jsonPointer
  }

  private static func isValidTopic(_ topic: String) -> Bool {
    MQTTTopicValidator.isValidPublicationTopic(topic)
  }

  private static func isCanonicalJSONLeafPointer(
    _ pointer: PayloadJSONPointer
  ) -> Bool {
    let raw = pointer.rawValue
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

public enum NumericChartValueKind:
  String,
  Codable,
  Equatable,
  Sendable
{
  case number
  case booleanAsZeroOrOne
}

public struct NumericChartValueConversion:
  Codable,
  Equatable,
  Sendable
{
  public let kind: NumericChartValueKind
  public let multiplier: Double

  public init(
    kind: NumericChartValueKind,
    multiplier: Double = 1
  ) {
    precondition(multiplier.isFinite)
    self.kind = kind
    self.multiplier = multiplier
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case multiplier
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try values.decode(NumericChartValueKind.self, forKey: .kind)
    let multiplier = try values.decode(Double.self, forKey: .multiplier)
    guard multiplier.isFinite else {
      throw DecodingError.dataCorruptedError(
        forKey: .multiplier,
        in: values,
        debugDescription: "A chart multiplier must be finite."
      )
    }
    self.kind = kind
    self.multiplier = multiplier
  }
}

public struct NumericChartSeries:
  Codable,
  Equatable,
  Sendable
{
  public let id: NumericChartSeriesID
  public let conversion: NumericChartValueConversion

  public init(
    id: NumericChartSeriesID,
    conversion: NumericChartValueConversion
  ) {
    self.id = id
    self.conversion = conversion
  }
}

public enum NumericChartConfigurationValidationError:
  Error,
  Equatable,
  Sendable
{
  case visibleDuration(Int64)
  case fixedVisibleRange(lowerBound: Int64, upperBound: Int64)
  case fixedYAxis(lowerBound: Double, upperBound: Double)
}

public struct NumericChartVisibleRange:
  Codable,
  Equatable,
  Sendable
{
  public static let durationBounds: ClosedRange<Int64> =
    1_000_000...(30 * 24 * 60 * 60 * 1_000_000)
  public static let `default` = NumericChartVisibleRange(
    uncheckedDurationMicroseconds: 5 * 60 * 1_000_000,
    endingAtMicroseconds: nil
  )

  public let durationMicroseconds: Int64
  public let endingAtMicroseconds: Int64?

  public init(
    durationMicroseconds: Int64,
    endingAtMicroseconds: Int64? = nil
  ) throws {
    guard Self.durationBounds.contains(durationMicroseconds) else {
      throw NumericChartConfigurationValidationError.visibleDuration(
        durationMicroseconds
      )
    }
    self.durationMicroseconds = durationMicroseconds
    self.endingAtMicroseconds = endingAtMicroseconds
  }

  public static func fixed(
    lowerBoundMicroseconds: Int64,
    upperBoundMicroseconds: Int64
  ) throws -> Self {
    let (duration, overflow) =
      upperBoundMicroseconds.subtractingReportingOverflow(
        lowerBoundMicroseconds
      )
    guard !overflow,
      Self.durationBounds.contains(duration)
    else {
      throw NumericChartConfigurationValidationError.fixedVisibleRange(
        lowerBound: lowerBoundMicroseconds,
        upperBound: upperBoundMicroseconds
      )
    }
    return try Self(
      durationMicroseconds: duration,
      endingAtMicroseconds: upperBoundMicroseconds
    )
  }

  private init(
    uncheckedDurationMicroseconds durationMicroseconds: Int64,
    endingAtMicroseconds: Int64?
  ) {
    self.durationMicroseconds = durationMicroseconds
    self.endingAtMicroseconds = endingAtMicroseconds
  }

  private enum CodingKeys: String, CodingKey {
    case durationMicroseconds
    case endingAtMicroseconds
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      durationMicroseconds: values.decode(
        Int64.self,
        forKey: .durationMicroseconds
      ),
      endingAtMicroseconds: values.decodeIfPresent(
        Int64.self,
        forKey: .endingAtMicroseconds
      )
    )
  }
}

public struct NumericChartYAxis:
  Codable,
  Equatable,
  Sendable
{
  public enum Mode: String, Codable, Equatable, Sendable {
    case automatic
    case fixed
  }

  public static let automatic = NumericChartYAxis(
    uncheckedMode: .automatic,
    lowerBound: nil,
    upperBound: nil
  )

  public let mode: Mode
  public let lowerBound: Double?
  public let upperBound: Double?

  public static func fixed(
    lowerBound: Double,
    upperBound: Double
  ) throws -> Self {
    guard lowerBound.isFinite,
      upperBound.isFinite,
      lowerBound < upperBound
    else {
      throw NumericChartConfigurationValidationError.fixedYAxis(
        lowerBound: lowerBound,
        upperBound: upperBound
      )
    }
    return Self(
      uncheckedMode: .fixed,
      lowerBound: lowerBound,
      upperBound: upperBound
    )
  }

  private init(
    uncheckedMode mode: Mode,
    lowerBound: Double?,
    upperBound: Double?
  ) {
    self.mode = mode
    self.lowerBound = lowerBound
    self.upperBound = upperBound
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case lowerBound
    case upperBound
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try values.decode(Mode.self, forKey: .mode)
    switch mode {
    case .automatic:
      self = .automatic
    case .fixed:
      self = try Self.fixed(
        lowerBound: values.decode(Double.self, forKey: .lowerBound),
        upperBound: values.decode(Double.self, forKey: .upperBound)
      )
    }
  }
}

public struct NumericChartConfiguration:
  Codable,
  Equatable,
  Sendable
{
  public let series: NumericChartSeries
  public var isPaused: Bool
  public var autoScroll: Bool
  public var visibleRange: NumericChartVisibleRange
  public var yAxis: NumericChartYAxis

  public init(
    series: NumericChartSeries,
    isPaused: Bool = false,
    autoScroll: Bool = true,
    visibleRange: NumericChartVisibleRange = .default,
    yAxis: NumericChartYAxis = .automatic
  ) {
    self.series = series
    self.isPaused = isPaused
    self.autoScroll =
      autoScroll || visibleRange.endingAtMicroseconds == nil
    self.visibleRange = visibleRange
    self.yAxis = yAxis
  }

  public func normalizingAutoScroll() -> Self {
    guard !autoScroll,
      visibleRange.endingAtMicroseconds == nil
    else {
      return self
    }
    return Self(
      series: series,
      isPaused: isPaused,
      autoScroll: true,
      visibleRange: visibleRange,
      yAxis: yAxis
    )
  }

  private enum CodingKeys: String, CodingKey {
    case series
    case isPaused
    case autoScroll
    case visibleRange
    case yAxis
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      series: try values.decode(NumericChartSeries.self, forKey: .series),
      isPaused: try values.decode(Bool.self, forKey: .isPaused),
      autoScroll: try values.decode(Bool.self, forKey: .autoScroll),
      visibleRange: try values.decode(
        NumericChartVisibleRange.self,
        forKey: .visibleRange
      ),
      yAxis: try values.decode(NumericChartYAxis.self, forKey: .yAxis)
    )
  }
}

public struct NumericChartSampleID:
  Codable,
  Equatable,
  Hashable,
  Sendable
{
  public let connectionEpoch: UUID
  public let ordinal: UInt64
  public let direction: PayloadDeliveryDirection

  public init(
    connectionEpoch: UUID,
    ordinal: UInt64,
    direction: PayloadDeliveryDirection
  ) {
    self.connectionEpoch = connectionEpoch
    self.ordinal = ordinal
    self.direction = direction
  }
}

public struct NumericChartSample:
  Equatable,
  Identifiable,
  Sendable
{
  public let id: NumericChartSampleID
  public let receivedAtMicroseconds: Int64
  public let value: Double

  public init(
    id: NumericChartSampleID,
    receivedAtMicroseconds: Int64,
    value: Double
  ) {
    precondition(value.isFinite)
    self.id = id
    self.receivedAtMicroseconds = receivedAtMicroseconds
    self.value = value
  }
}

public enum NumericChartDownsampler {
  public static func downsample(
    _ samples: [NumericChartSample],
    maximumSampleCount: Int
  ) -> [NumericChartSample] {
    precondition(maximumSampleCount >= 4)
    guard samples.count > maximumSampleCount else { return samples }

    let interiorCount = samples.count - 2
    let bucketCount = max(1, (maximumSampleCount - 2) / 2)
    var result: [NumericChartSample] = []
    result.reserveCapacity(maximumSampleCount)
    result.append(samples[0])

    for bucket in 0..<bucketCount {
      let start = 1 + bucket * interiorCount / bucketCount
      let end = 1 + (bucket + 1) * interiorCount / bucketCount
      guard start < end else { continue }
      var minimumIndex = start
      var maximumIndex = start
      for index in (start + 1)..<end {
        if samples[index].value < samples[minimumIndex].value {
          minimumIndex = index
        }
        if samples[index].value > samples[maximumIndex].value {
          maximumIndex = index
        }
      }
      if minimumIndex == maximumIndex {
        result.append(samples[minimumIndex])
      } else if minimumIndex < maximumIndex {
        result.append(samples[minimumIndex])
        result.append(samples[maximumIndex])
      } else {
        result.append(samples[maximumIndex])
        result.append(samples[minimumIndex])
      }
    }
    result.append(samples[samples.count - 1])
    return result
  }
}

public struct NumericChartValueExtractor: Sendable {
  private let policy: NumericChartPolicy
  private let inspector: PayloadInspector

  public init(policy: NumericChartPolicy = .default) {
    self.policy = policy
    self.inspector = PayloadInspector(
      limits: PayloadInspectionLimits(
        maximumJSONBytes: policy.maximumPayloadBytesPerSample,
        maximumJSONDepth: policy.maximumJSONDepth,
        maximumJSONNodeCount: policy.maximumJSONNodeCount,
        maximumJSONNodePreviewCharacters: 128,
        maximumTextPreviewBytes: policy.maximumPayloadBytesPerSample,
        maximumHexBytes: min(
          policy.maximumPayloadBytesPerSample,
          4_096
        )
      )
    )
  }

  public func value(
    in payload: Data,
    for series: NumericChartSeries
  ) async -> Double? {
    guard payload.count <= policy.maximumPayloadBytesPerSample else {
      return nil
    }
    guard
      case .json(let document) =
        await inspector.presentation(for: payload)
    else {
      return nil
    }
    let pointer = series.id.jsonPointer ?? .root
    guard let value = document.value(at: pointer) else { return nil }
    let rawValue: Double
    switch (series.conversion.kind, value) {
    case (.number, .number(let number)):
      rawValue = number.doubleValue
    case (.booleanAsZeroOrOne, .boolean(let boolean)):
      rawValue = boolean ? 1 : 0
    default:
      return nil
    }
    let converted = rawValue * series.conversion.multiplier
    return converted.isFinite ? converted : nil
  }
}
