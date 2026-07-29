import Foundation
import Testing

@testable import JollysMQTTCore

@Suite("Bounded numeric charts")
struct NumericChartTests {
  @Test("Series identity includes broker, exact topic, and optional JSON path")
  func stableSeriesIdentity() throws {
    let brokerID = UUID()
    let scalar = NumericChartSeriesID(
      brokerID: brokerID,
      topic: "factory/line/temperature"
    )
    let json = NumericChartSeriesID(
      brokerID: brokerID,
      topic: "factory/line/temperature",
      jsonPointer: PayloadJSONPointer(rawValue: "/sensor/value")
    )

    #expect(scalar != json)
    #expect(
      scalar
        != NumericChartSeriesID(
          brokerID: UUID(),
          topic: scalar.topic
        )
    )
    #expect(
      scalar
        != NumericChartSeriesID(
          brokerID: brokerID,
          topic: "factory/line/Temperature"
        )
    )
    #expect(
      try JSONDecoder().decode(
        NumericChartSeriesID.self,
        from: JSONEncoder().encode(json)
      ) == json
    )
  }

  @Test("Numeric scalar and JSON leaf payloads extract through the configured path")
  func numericExtraction() async {
    let brokerID = UUID()
    let extractor = NumericChartValueExtractor()
    let scalar = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: brokerID,
        topic: "factory/scalar"
      ),
      conversion: NumericChartValueConversion(
        kind: .number,
        multiplier: 2.5
      )
    )
    let leaf = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: brokerID,
        topic: "factory/json",
        jsonPointer: PayloadJSONPointer(rawValue: "/sensor/value")
      ),
      conversion: NumericChartValueConversion(kind: .number)
    )

    #expect(
      await extractor.value(
        in: Data("4".utf8),
        for: scalar
      ) == 10
    )
    #expect(
      await extractor.value(
        in: Data(#"{"sensor":{"value":12.75}}"#.utf8),
        for: leaf
      ) == 12.75
    )
    #expect(
      await extractor.value(
        in: Data(#"{"sensor":{"other":12.75}}"#.utf8),
        for: leaf
      ) == nil
    )
  }

  @Test("Boolean conversion accepts only booleans and maps false and true to zero and one")
  func booleanExtraction() async {
    let extractor = NumericChartValueExtractor()
    let series = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: UUID(),
        topic: "factory/enabled",
        jsonPointer: PayloadJSONPointer(rawValue: "/enabled")
      ),
      conversion: NumericChartValueConversion(
        kind: .booleanAsZeroOrOne,
        multiplier: 3
      )
    )

    #expect(
      await extractor.value(
        in: Data(#"{"enabled":false}"#.utf8),
        for: series
      ) == 0
    )
    #expect(
      await extractor.value(
        in: Data(#"{"enabled":true}"#.utf8),
        for: series
      ) == 3
    )
    #expect(
      await extractor.value(
        in: Data(#"{"enabled":1}"#.utf8),
        for: series
      ) == nil
    )
  }

  @Test("Chart extraction has conservative public work limits and rejects unusable values")
  func boundedExtraction() async {
    let policy = NumericChartPolicy.default
    #expect(policy.maximumHistoryMessageCount == 2_048)
    #expect(policy.maximumPayloadBytesPerSample == 65_536)
    #expect(policy.maximumPayloadBytesPerLoad == 8 * 1_024 * 1_024)
    #expect(policy.maximumJSONDepth == 32)
    #expect(policy.maximumJSONNodeCount == 512)
    #expect(policy.maximumRawSampleCount == 2_048)
    #expect(policy.maximumDisplaySampleCount == 1_024)

    let extractor = NumericChartValueExtractor(policy: policy)
    let numeric = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: UUID(),
        topic: "factory/value"
      ),
      conversion: NumericChartValueConversion(kind: .number)
    )
    var oversized = Data(
      repeating: 0x20,
      count: policy.maximumPayloadBytesPerSample
    )
    oversized.append(contentsOf: Data("1".utf8))

    #expect(await extractor.value(in: oversized, for: numeric) == nil)
    #expect(
      await extractor.value(
        in: Data(#""not a number""#.utf8),
        for: numeric
      ) == nil
    )
    #expect(await extractor.value(in: Data("null".utf8), for: numeric) == nil)
    #expect(await extractor.value(in: Data("[1]".utf8), for: numeric) == nil)

    let overflow = NumericChartSeries(
      id: numeric.id,
      conversion: NumericChartValueConversion(
        kind: .number,
        multiplier: .greatestFiniteMagnitude
      )
    )
    #expect(
      await extractor.value(in: Data("2".utf8), for: overflow) == nil
    )
  }

  @Test("Policy validation enforces every public operational bound")
  func policyValidation() {
    func make(
      history: Int = 8,
      sampleBytes: Int = 64,
      loadBytes: Int = 4_096,
      depth: Int = 8,
      nodes: Int = 32,
      raw: Int = 8,
      display: Int = 4
    ) throws -> NumericChartPolicy {
      try NumericChartPolicy(
        maximumHistoryMessageCount: history,
        maximumPayloadBytesPerSample: sampleBytes,
        maximumPayloadBytesPerLoad: loadBytes,
        maximumJSONDepth: depth,
        maximumJSONNodeCount: nodes,
        maximumRawSampleCount: raw,
        maximumDisplaySampleCount: display
      )
    }

    #expect(throws: NumericChartPolicyValidationError.maximumHistoryMessageCount(3)) {
      try make(history: 3)
    }
    #expect(throws: NumericChartPolicyValidationError.maximumPayloadBytesPerSample(0)) {
      try make(sampleBytes: 0)
    }
    #expect(throws: NumericChartPolicyValidationError.maximumPayloadBytesPerLoad(4_095)) {
      try make(loadBytes: 4_095)
    }
    #expect(throws: NumericChartPolicyValidationError.maximumJSONDepth(0)) {
      try make(depth: 0)
    }
    #expect(throws: NumericChartPolicyValidationError.maximumJSONNodeCount(0)) {
      try make(nodes: 0)
    }
    #expect(throws: NumericChartPolicyValidationError.maximumRawSampleCount(3)) {
      try make(raw: 3)
    }
    #expect(throws: NumericChartPolicyValidationError.maximumDisplaySampleCount(3)) {
      try make(display: 3)
    }
    #expect(throws: NumericChartPolicyValidationError.rawSamplesExceedHistoryMessages) {
      try make(history: 4, raw: 5)
    }
    #expect(throws: NumericChartPolicyValidationError.displaySamplesExceedRawSamples) {
      try make(raw: 4, display: 5)
    }
    #expect(throws: NumericChartPolicyValidationError.samplePayloadExceedsLoadPayload) {
      try make(sampleBytes: 4_097, loadBytes: 4_096)
    }

    #expect(
      NumericChartPolicy.default.maximumDisplaySampleCount(
        forPixelWidth: -1
      ) == 4
    )
    #expect(
      NumericChartPolicy.default.maximumDisplaySampleCount(
        forPixelWidth: .infinity
      ) == NumericChartPolicy.default.maximumDisplaySampleCount
    )
  }

  @Test("Persisted visible and Y-axis bounds are validated")
  func persistedConfigurationBoundsAreValidated() throws {
    #expect(throws: NumericChartConfigurationValidationError.visibleDuration(999_999)) {
      try NumericChartVisibleRange(durationMicroseconds: 999_999)
    }
    #expect(
      throws: NumericChartConfigurationValidationError.fixedVisibleRange(
        lowerBound: 20,
        upperBound: 10
      )
    ) {
      try NumericChartVisibleRange.fixed(
        lowerBoundMicroseconds: 20,
        upperBoundMicroseconds: 10
      )
    }
    #expect(
      throws: NumericChartConfigurationValidationError.fixedYAxis(
        lowerBound: 1,
        upperBound: 1
      )
    ) {
      try NumericChartYAxis.fixed(lowerBound: 1, upperBound: 1)
    }

    let invalidRange = Data(
      #"{"durationMicroseconds":0,"endingAtMicroseconds":10}"#.utf8
    )
    let invalidAxis = Data(
      #"{"mode":"fixed","lowerBound":10,"upperBound":1}"#.utf8
    )
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        NumericChartVisibleRange.self,
        from: invalidRange
      )
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(NumericChartYAxis.self, from: invalidAxis)
    }
  }

  @Test("Auto-scroll off always has a fixed visible-range anchor")
  func autoScrollInvariantIsNormalized() throws {
    let series = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: UUID(),
        topic: "factory/value"
      ),
      conversion: NumericChartValueConversion(kind: .number)
    )
    let constructed = NumericChartConfiguration(
      series: series,
      autoScroll: false
    )
    #expect(constructed.autoScroll)

    var corrupt = NumericChartConfiguration(series: series)
    corrupt.autoScroll = false
    #expect(corrupt.visibleRange.endingAtMicroseconds == nil)
    let decoded = try JSONDecoder().decode(
      NumericChartConfiguration.self,
      from: JSONEncoder().encode(corrupt)
    )
    #expect(decoded.autoScroll)
    #expect(
      decoded.normalizingAutoScroll()
        == NumericChartConfiguration(series: series)
    )
  }

  @Test(
    "Persisted chart series rejects noncanonical or unsafe identity and conversion values",
    arguments: [
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"","jsonPointer":null},"conversion":{"kind":"number","multiplier":1}}"#,
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"bad\u0000topic","jsonPointer":null},"conversion":{"kind":"number","multiplier":1}}"#,
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"bad/+","jsonPointer":null},"conversion":{"kind":"number","multiplier":1}}"#,
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"bad/#","jsonPointer":null},"conversion":{"kind":"number","multiplier":1}}"#,
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"bad/\u0001topic","jsonPointer":null},"conversion":{"kind":"number","multiplier":1}}"#,
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"factory/value","jsonPointer":{"rawValue":""}},"conversion":{"kind":"number","multiplier":1}}"#,
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"factory/value","jsonPointer":{"rawValue":"/bad~2path"}},"conversion":{"kind":"number","multiplier":1}}"#,
      #"{"id":{"brokerID":"00000000-0000-0000-0000-000000000001","topic":"factory/value","jsonPointer":null},"conversion":{"kind":"number","multiplier":"INF"}}"#,
    ]
  )
  func invalidPersistedSeriesIsRejected(_ source: String) {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "INF",
      negativeInfinity: "-INF",
      nan: "NaN"
    )

    #expect(throws: (any Error).self) {
      try decoder.decode(
        NumericChartSeries.self,
        from: Data(source.utf8)
      )
    }
  }

  @Test("Resolution downsampling preserves chronological endpoints and extrema")
  func downsamplingPreservesSignal() {
    let epoch = UUID()
    let values = [0.0, 2, 4, -100, 5, 6, 7, 100, 8, 9, 10, 11]
    let input = values.enumerated().map { index, value in
      NumericChartSample(
        id: NumericChartSampleID(
          connectionEpoch: epoch,
          ordinal: UInt64(index + 1),
          direction: .received
        ),
        receivedAtMicroseconds: index < 8 ? 100 : 101,
        value: value
      )
    }

    let output = NumericChartDownsampler.downsample(
      input,
      maximumSampleCount:
        NumericChartPolicy.default.maximumDisplaySampleCount(
          forPixelWidth: 6
        )
    )

    #expect(output.count <= 6)
    #expect(output.first?.id == input.first?.id)
    #expect(output.last?.id == input.last?.id)
    #expect(output.map(\.value).contains(-100))
    #expect(output.map(\.value).contains(100))
    let ordinals = output.map(\.id.ordinal)
    #expect(ordinals == ordinals.sorted())
  }
}
