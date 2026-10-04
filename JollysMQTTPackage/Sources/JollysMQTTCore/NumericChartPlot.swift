import Foundation

public enum NumericChartDomain {
  public static func domain(
    configuration: NumericChartConfiguration?,
    samples: [NumericChartSample]
  ) -> ClosedRange<Double> {
    domain(yAxis: configuration?.yAxis ?? .automatic, samples: samples)
  }

  public static func domain(
    yAxis: NumericChartYAxis,
    samples: [NumericChartSample]
  ) -> ClosedRange<Double> {
    let automatic = automatic(for: samples, scale: yAxis.scale)
    var lower = yAxis.lowerBound ?? automatic.lowerBound
    var upper = yAxis.upperBound ?? automatic.upperBound
    if lower >= upper {
      if yAxis.upperBound == nil {
        upper = expanded(around: lower, scale: yAxis.scale).upperBound
        if upper <= lower { lower = lower.nextDown }
      } else {
        lower = expanded(around: upper, scale: yAxis.scale).lowerBound
        if lower >= upper { upper = upper.nextUp }
      }
    }
    return lower...upper
  }

  public static func automatic(
    for samples: [NumericChartSample],
    scale: NumericChartYAxisScale = .linear
  ) -> ClosedRange<Double> {
    let values = samples.lazy.map(\.value).filter { scale == .linear || $0 > 0 }
    guard let minimum = values.min(), let maximum = values.max() else {
      return scale == .logarithmic ? 1...10 : 0...1
    }
    if minimum == maximum { return expanded(around: minimum, scale: scale) }
    if scale == .logarithmic {
      let padding = (log10(maximum) - log10(minimum)) * 0.05
      let lower = positivePower(log10(minimum) - padding, fallback: minimum)
      let upper = positivePower(log10(maximum) + padding, fallback: maximum)
      return lower...upper
    }
    let span = maximum - minimum
    guard span.isFinite else { return minimum...maximum }
    let padding = span * 0.05
    let lower = minimum - padding
    let upper = maximum + padding
    return (lower.isFinite ? lower : minimum)...(upper.isFinite ? upper : maximum)
  }

  private static func expanded(
    around value: Double,
    scale: NumericChartYAxisScale
  ) -> ClosedRange<Double> {
    if scale == .logarithmic {
      let lower = positivePower(log10(value) - 0.05, fallback: value)
      let upper = positivePower(log10(value) + 0.05, fallback: value)
      if lower == upper {
        return value == .leastNonzeroMagnitude ? value...value.nextUp : value.nextDown...value
      }
      return lower...upper
    }
    let padding = max(abs(value) * 0.05, 1)
    let lower = value - padding
    let upper = value + padding
    return (lower.isFinite ? lower : value)...(upper.isFinite ? upper : value)
  }

  private static func positivePower(_ exponent: Double, fallback: Double) -> Double {
    let value = pow(10, exponent)
    return value.isFinite && value > 0 ? value : fallback
  }
}

/// A bounded presentation projection. Samples retain their actual values for
/// selection; only the plotted coordinates are clamped to the visible domain.
public struct NumericChartPlotData: Equatable, Sendable {
  public struct Point: Equatable, Identifiable, Sendable {
    public let sample: NumericChartSample
    public let value: Double
    public let isClipped: Bool
    public var id: NumericChartSampleID { sample.id }
  }

  public struct Segment: Equatable, Identifiable, Sendable {
    public let id: String
    public let startTime: Date
    public let endTime: Date
    public let startValue: Double
    public let endValue: Double
    public let isClipped: Bool
  }

  public let domain: ClosedRange<Double>
  public let points: [Point]
  public let segments: [Segment]
  public let clippedSampleCount: Int

  public init(
    samples: [NumericChartSample],
    yAxis: NumericChartYAxis,
    presentationStyle: NumericChartPresentationStyle
  ) {
    let domain = NumericChartDomain.domain(yAxis: yAxis, samples: samples)
    self.domain = domain
    points = samples.map {
      Point(
        sample: $0,
        value: min(max($0.value, domain.lowerBound), domain.upperBound),
        isClipped: !domain.contains($0.value)
      )
    }
    clippedSampleCount = points.count(where: \.isClipped)
    var segments: [Segment] = []
    if presentationStyle != .points {
      for (start, end) in zip(points, points.dropFirst()) {
        let identity =
          "\(start.id.connectionEpoch)/\(start.id.ordinal)/\(start.id.direction.rawValue)"
        let startTime = Double(start.sample.receivedAtMicroseconds) / 1_000_000
        let endTime = Double(end.sample.receivedAtMicroseconds) / 1_000_000
        if presentationStyle == .step {
          segments.append(
            Segment(
              id: identity + "/hold",
              startTime: Date(timeIntervalSince1970: startTime),
              endTime: Date(timeIntervalSince1970: endTime),
              startValue: start.value, endValue: start.value,
              isClipped: start.isClipped
            ))
          segments.append(
            Segment(
              id: identity + "/jump",
              startTime: Date(timeIntervalSince1970: endTime),
              endTime: Date(timeIntervalSince1970: endTime),
              startValue: start.value, endValue: end.value,
              isClipped: start.isClipped && end.isClipped && start.value == end.value
            ))
          continue
        }

        // Split at exact boundary crossings, so only the missing portion of a
        // line is red and flat at the edge. Interpolate in the selected scale.
        let a = Self.coordinate(start.sample.value, scale: yAxis.scale, domain: domain)
        let b = Self.coordinate(end.sample.value, scale: yAxis.scale, domain: domain)
        let lower = Self.coordinate(domain.lowerBound, scale: yAxis.scale, domain: domain)
        let upper = Self.coordinate(domain.upperBound, scale: yAxis.scale, domain: domain)
        var cuts: [(fraction: Double, value: Double)] = [(0, start.value), (1, end.value)]
        for bound in [lower, upper] where min(a, b) < bound && bound < max(a, b) {
          let difference = b - a
          let fraction =
            difference.isFinite
            ? (bound - a) / difference
            : (bound / 2 - a / 2) / (b / 2 - a / 2)
          cuts.append((fraction, bound == lower ? domain.lowerBound : domain.upperBound))
        }
        cuts.sort { $0.fraction < $1.fraction }
        for (part, pair) in zip(cuts, cuts.dropFirst()).enumerated() {
          let (from, to) = pair
          let midpoint = from.fraction / 2 + to.fraction / 2
          let coordinate = a * (1 - midpoint) + b * midpoint
          let clipped =
            coordinate < lower || coordinate > upper
            || (start.isClipped && end.isClipped && start.value == end.value)
          segments.append(
            Segment(
              id: identity + "/\(part)",
              startTime: Date(
                timeIntervalSince1970: startTime * (1 - from.fraction) + endTime * from.fraction),
              endTime: Date(
                timeIntervalSince1970: startTime * (1 - to.fraction) + endTime * to.fraction),
              startValue: from.value, endValue: to.value,
              isClipped: clipped
            ))
        }
      }
    }
    self.segments = segments
  }

  private static func coordinate(
    _ value: Double,
    scale: NumericChartYAxisScale,
    domain: ClosedRange<Double>
  ) -> Double {
    scale == .logarithmic ? log10(value > 0 ? value : domain.lowerBound) : value
  }
}
