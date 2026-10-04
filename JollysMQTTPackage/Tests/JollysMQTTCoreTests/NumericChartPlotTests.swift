import Foundation
import JollysMQTTCore
import Testing

@Suite("Numeric chart bounds and plotting")
struct NumericChartPlotTests {
  @Test("Old axes decode as linear and new independent bounds round-trip")
  func persistedAxisCompatibility() throws {
    let decoder = JSONDecoder()
    let automatic = try decoder.decode(
      NumericChartYAxis.self, from: Data(#"{"mode":"automatic"}"#.utf8))
    let fixed = try decoder.decode(
      NumericChartYAxis.self, from: Data(#"{"mode":"fixed","lowerBound":0,"upperBound":100}"#.utf8))
    #expect(automatic == .automatic)
    #expect(fixed == (try .fixed(lowerBound: 0, upperBound: 100)))

    for axis in [
      try NumericChartYAxis.bounded(lowerBound: 0),
      try .bounded(upperBound: 100),
      try .bounded(scale: .logarithmic),
      try .bounded(lowerBound: 1, scale: .logarithmic),
      try .bounded(upperBound: 1_000, scale: .logarithmic),
    ] {
      #expect(try decoder.decode(NumericChartYAxis.self, from: JSONEncoder().encode(axis)) == axis)
    }
  }

  @Test("Each automatic bound tracks new data while its fixed neighbor stays put")
  func independentBounds() throws {
    let minimum = try NumericChartYAxis.bounded(lowerBound: 0)
    let maximum = try NumericChartYAxis.bounded(upperBound: 100)
    let first = samples([20, 50])
    let later = samples([-20, 200])
    let firstMinDomain = NumericChartDomain.domain(yAxis: minimum, samples: first)
    let laterMinDomain = NumericChartDomain.domain(yAxis: minimum, samples: later)
    let firstMaxDomain = NumericChartDomain.domain(yAxis: maximum, samples: first)
    let laterMaxDomain = NumericChartDomain.domain(yAxis: maximum, samples: later)
    #expect(firstMinDomain.lowerBound == 0)
    #expect(laterMinDomain.lowerBound == 0)
    #expect(laterMinDomain.upperBound > firstMinDomain.upperBound)
    #expect(firstMaxDomain.upperBound == 100)
    #expect(laterMaxDomain.upperBound == 100)
    #expect(laterMaxDomain.lowerBound < firstMaxDomain.lowerBound)
  }

  @Test("Bounds beyond all data still produce a usable domain and edge markers")
  func boundsBeyondData() throws {
    let minimum = try NumericChartYAxis.bounded(lowerBound: 100)
    let maximum = try NumericChartYAxis.bounded(upperBound: -100)
    for axis in [minimum, maximum] {
      let data = NumericChartPlotData(
        samples: samples([10, 20]), yAxis: axis, presentationStyle: .line)
      #expect(data.domain.lowerBound < data.domain.upperBound)
      #expect(data.clippedSampleCount == 2)
      #expect(data.points.allSatisfy { data.domain.contains($0.value) })
      #expect(data.segments.allSatisfy { $0.isClipped })
    }
  }

  @Test(
    "Clipping preserves readings and highlights both edges in every style",
    arguments: NumericChartPresentationStyle.allCases)
  func clippingPreservesSamples(style: NumericChartPresentationStyle) throws {
    let original = samples([-10, 0, 50, 100, 110])
    let data = NumericChartPlotData(
      samples: original, yAxis: try .fixed(lowerBound: 0, upperBound: 100), presentationStyle: style
    )
    #expect(data.points.map(\.sample) == original)
    #expect(data.points.map(\.value) == [0, 0, 50, 100, 100])
    #expect(data.points.map(\.isClipped) == [true, false, false, false, true])
    #expect(data.clippedSampleCount == 2)
    #expect(
      data.segments.allSatisfy {
        data.domain.contains($0.startValue) && data.domain.contains($0.endValue)
      })
  }

  @Test("Lines crossing both bounds show only their missing portions in red")
  func lineCrossings() throws {
    let data = NumericChartPlotData(
      samples: samples([-50, 150]), yAxis: try .fixed(lowerBound: 0, upperBound: 100),
      presentationStyle: .line
    )
    #expect(data.segments.map(\.isClipped) == [true, false, true])
    #expect(data.segments.map(\.startValue) == [0, 0, 100])
    #expect(data.segments.map(\.endValue) == [0, 100, 100])
    #expect(data.segments[0].endTime.timeIntervalSince1970 == 0.25)
    #expect(data.segments[2].startTime.timeIntervalSince1970 == 0.75)
    #expect(Set(data.segments.map(\.id)).count == data.segments.count)
  }

  @Test("Step lines hold the preceding value and highlight clipped plateaus")
  func stepClipping() throws {
    let data = NumericChartPlotData(
      samples: samples([150, 50, -50]), yAxis: try .fixed(lowerBound: 0, upperBound: 100),
      presentationStyle: .step
    )
    #expect(data.segments.count == 4)
    #expect(data.segments[0].startValue == 100)
    #expect(data.segments[0].endValue == 100)
    #expect(data.segments[0].isClipped)
    #expect(data.segments[1].startTime == data.segments[1].endTime)
    #expect(data.segments[2].startValue == 50)
    #expect(!data.segments[2].isClipped)
  }

  @Test("Logarithmic autoscaling includes positive samples and marks nonpositive readings")
  func logarithmicAutoDomain() throws {
    let axis = try NumericChartYAxis.bounded(scale: .logarithmic)
    let data = NumericChartPlotData(
      samples: samples([-10, 0, 1, 1_000]), yAxis: axis, presentationStyle: .line)
    #expect(data.domain.lowerBound > 0)
    #expect(data.domain.lowerBound < 1)
    #expect(data.domain.upperBound > 1_000)
    #expect(data.clippedSampleCount == 2)
    #expect(data.points[0].value == data.domain.lowerBound)
    #expect(data.points[1].value == data.domain.lowerBound)
    #expect(data.points[0].sample.value == -10)
    #expect(data.segments.first?.isClipped == true)
    let nonpositive = NumericChartPlotData(
      samples: samples([-1, 0]), yAxis: axis, presentationStyle: .line)
    #expect(nonpositive.domain == 1...10)
    #expect(nonpositive.clippedSampleCount == 2)
    #expect(nonpositive.segments.allSatisfy { $0.isClipped })
    #expect(NumericChartDomain.domain(yAxis: axis, samples: []) == 1...10)
  }

  @Test("Logarithmic crossings interpolate by powers of ten")
  func logarithmicCrossings() throws {
    let axis = try NumericChartYAxis.bounded(lowerBound: 10, upperBound: 100, scale: .logarithmic)
    let data = NumericChartPlotData(
      samples: samples([1, 1_000]), yAxis: axis, presentationStyle: .line)
    #expect(data.segments.map(\.isClipped) == [true, false, true])
    #expect(abs(data.segments[0].endTime.timeIntervalSince1970 - 1.0 / 3) < 0.000001)
    #expect(abs(data.segments[2].startTime.timeIntervalSince1970 - 2.0 / 3) < 0.000001)
  }

  @Test("Invalid bounds cannot enter saved chart configuration")
  func rejectsInvalidBounds() {
    for (lower, upper) in [(10.0, 1.0), (1, 1), (.infinity, 10), (1, .nan)] {
      #expect(throws: (any Error).self) {
        try NumericChartYAxis.bounded(lowerBound: lower, upperBound: upper)
      }
    }
    for bound in [-1.0, 0] {
      #expect(throws: NumericChartConfigurationValidationError.logarithmicYAxisBounds) {
        try NumericChartYAxis.bounded(lowerBound: bound, scale: .logarithmic)
      }
      #expect(throws: NumericChartConfigurationValidationError.logarithmicYAxisBounds) {
        try NumericChartYAxis.bounded(upperBound: bound, scale: .logarithmic)
      }
    }
  }

  @Test("Finite extremes, subnormal positives, and single points remain renderable")
  func finiteExtremes() throws {
    for scale in NumericChartYAxisScale.allCases {
      let axis = try NumericChartYAxis.bounded(scale: scale)
      for value in [Double.leastNonzeroMagnitude, .greatestFiniteMagnitude] {
        let data = NumericChartPlotData(
          samples: samples([value]), yAxis: axis, presentationStyle: .line)
        #expect(data.domain.lowerBound.isFinite && data.domain.upperBound.isFinite)
        #expect(data.domain.lowerBound < data.domain.upperBound)
        #expect(data.domain.contains(value))
      }
    }
    let data = NumericChartPlotData(
      samples: samples([-.greatestFiniteMagnitude, .greatestFiniteMagnitude]),
      yAxis: try .fixed(lowerBound: -100, upperBound: 100), presentationStyle: .line
    )
    #expect(
      data.segments.allSatisfy {
        $0.startValue.isFinite && $0.endValue.isFinite
          && $0.startTime.timeIntervalSince1970.isFinite
          && $0.endTime.timeIntervalSince1970.isFinite
      })
  }

  private func samples(_ values: [Double]) -> [NumericChartSample] {
    let epoch = UUID()
    return values.enumerated().map {
      NumericChartSample(
        id: .init(connectionEpoch: epoch, ordinal: UInt64($0.offset + 1), direction: .received),
        receivedAtMicroseconds: Int64($0.offset) * 1_000_000, value: $0.element
      )
    }
  }
}
