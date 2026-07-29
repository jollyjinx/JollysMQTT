import Charts
import JollysMQTTCore
import SwiftUI

struct NumericChartPinControls: View {
  let inspection: PayloadInspection
  let selectedJSONPointer: PayloadJSONPointer?
  let pinnedSeries: NumericChartSeries?
  let onPin: (NumericChartSeries) -> Void

  var body: some View {
    let availability = NumericChartPinEvaluator.availability(
      inspection: inspection,
      selectedJSONPointer: selectedJSONPointer
    )
    VStack(alignment: .leading, spacing: 6) {
      switch availability {
      case .available(let series):
        let isPinned = NumericChartPinStateEvaluator.isPinned(
          candidate: series,
          pinnedSeries: pinnedSeries
        )
        Button {
          onPin(series)
        } label: {
          Label {
            Text(
              isPinned
                ? LocalizedStringResource(
                  "Pinned to Chart",
                  bundle: #bundle,
                  comment: "Indicates the selected value is the active chart."
                )
                : LocalizedStringResource(
                  "Pin to Chart",
                  bundle: #bundle,
                  comment: "Pins the selected numeric payload value to the chart."
                )
            )
          } icon: {
            Image(systemName: "chart.xyaxis.line")
          }
        }
        .buttonStyle(.bordered)
        .disabled(isPinned)
        if series.conversion.kind == .booleanAsZeroOrOne {
          Text(
            "Boolean values are charted as 0 for false and 1 for true.",
            bundle: #bundle,
            comment: "Explains Boolean-to-number chart conversion."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

      case .unavailable(let reason):
        Label {
          Text(reason.localizedDescription)
        } icon: {
          Image(systemName: "chart.xyaxis.line")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

extension NumericChartPinUnavailableReason {
  fileprivate var localizedDescription: LocalizedStringResource {
    switch self {
    case .noCurrentPayload:
      LocalizedStringResource(
        "A current payload is required before a value can be pinned.",
        bundle: #bundle,
        comment: "Explains why chart pinning is unavailable without a current payload."
      )
    case .payloadIsNotJSON:
      LocalizedStringResource(
        "This payload does not contain a JSON number or Boolean.",
        bundle: #bundle,
        comment: "Explains why a non-JSON payload cannot be charted."
      )
    case .selectNumericLeaf:
      LocalizedStringResource(
        "Select a numeric or Boolean JSON leaf to enable charting.",
        bundle: #bundle,
        comment: "Explains that JSON containers cannot be charted."
      )
    case .selectedValueIsNotNumeric:
      LocalizedStringResource(
        "The selected JSON value is not a number or Boolean.",
        bundle: #bundle,
        comment: "Explains that strings and null cannot be charted."
      )
    case .invalidJSONPointer:
      LocalizedStringResource(
        "The selected JSON path is unavailable.",
        bundle: #bundle,
        comment: "Explains that an invalid JSON path cannot be charted."
      )
    }
  }
}

struct NumericChartPane: View {
  @Bindable var store: NumericChartStore

  var body: some View {
    GroupBox {
      if let configuration = store.state.configuration {
        VStack(alignment: .leading, spacing: 12) {
          NumericChartHeader(
            configuration: configuration,
            store: store
          )
          NumericChartSettings(
            configuration: configuration,
            samples: store.state.samples,
            store: store
          )
          NumericChartContent(store: store)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } label: {
      Text(
        "Pinned Numeric Chart",
        bundle: #bundle,
        comment: "Heading for the single pinned numeric MQTT chart."
      )
    }
  }
}

private struct NumericChartHeader: View {
  let configuration: NumericChartConfiguration
  @Bindable var store: NumericChartStore

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: configuration.series.id.topic)
          .font(.headline)
          .textSelection(.enabled)
        if let pointer = configuration.series.id.jsonPointer {
          Text(verbatim: pointer.rawValue)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        } else {
          Text(
            "Payload value",
            bundle: #bundle,
            comment: "Describes a chart sourced from the root payload scalar."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button(role: .destructive) {
        store.send(.remove)
      } label: {
        Label {
          Text(
            "Remove Chart",
            bundle: #bundle,
            comment: "Removes the single pinned numeric chart."
          )
        } icon: {
          Image(systemName: "xmark")
        }
      }
    }
  }
}

private struct NumericChartSettings: View {
  let configuration: NumericChartConfiguration
  let samples: [NumericChartSample]
  @Bindable var store: NumericChartStore

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) {
        controls
      }
      VStack(alignment: .leading, spacing: 10) {
        controls
      }
    }
  }

  @ViewBuilder
  private var controls: some View {
    Toggle(
      isOn: Binding(
        get: { configuration.isPaused },
        set: { store.send(.setPaused($0)) }
      )
    ) {
      Text(
        "Pause",
        bundle: #bundle,
        comment: "Stops appending live points to the numeric chart."
      )
    }
    Toggle(
      isOn: Binding(
        get: { configuration.autoScroll },
        set: { store.send(.setAutoScroll($0)) }
      )
    ) {
      Text(
        "Auto-scroll",
        bundle: #bundle,
        comment: "Keeps the numeric chart anchored to the latest timestamp."
      )
    }
    NumericChartDurationPicker(
      configuration: configuration,
      store: store
    )
    TextField(
      value: Binding(
        get: { configuration.series.conversion.multiplier },
        set: { store.send(.setMultiplier($0)) }
      ),
      format: .number
    ) {
      Text(
        "Scale",
        bundle: #bundle,
        comment: "Multiplier applied to numeric chart values."
      )
    }
    .frame(maxWidth: 140)
    NumericChartYAxisControls(
      configuration: configuration,
      samples: samples,
      store: store
    )
  }
}

private struct NumericChartDurationPicker: View {
  let configuration: NumericChartConfiguration
  @Bindable var store: NumericChartStore

  var body: some View {
    Picker(
      selection: Binding(
        get: { configuration.visibleRange.durationMicroseconds },
        set: { duration in
          guard
            let range = try? NumericChartVisibleRange(
              durationMicroseconds: duration,
              endingAtMicroseconds:
                configuration.visibleRange.endingAtMicroseconds
            )
          else {
            return
          }
          store.send(.setVisibleRange(range))
        }
      )
    ) {
      Text(
        "1 minute",
        bundle: #bundle,
        comment: "One-minute numeric-chart visible range."
      )
      .tag(Int64(60 * 1_000_000))
      Text(
        "5 minutes",
        bundle: #bundle,
        comment: "Five-minute numeric-chart visible range."
      )
      .tag(Int64(5 * 60 * 1_000_000))
      Text(
        "15 minutes",
        bundle: #bundle,
        comment: "Fifteen-minute numeric-chart visible range."
      )
      .tag(Int64(15 * 60 * 1_000_000))
      Text(
        "1 hour",
        bundle: #bundle,
        comment: "One-hour numeric-chart visible range."
      )
      .tag(Int64(60 * 60 * 1_000_000))
    } label: {
      Text(
        "Range",
        bundle: #bundle,
        comment: "Label for the numeric-chart visible time range."
      )
    }
  }
}

private struct NumericChartYAxisControls: View {
  let configuration: NumericChartConfiguration
  let samples: [NumericChartSample]
  @Bindable var store: NumericChartStore

  var body: some View {
    Picker(
      selection: Binding(
        get: { configuration.yAxis.mode },
        set: setMode
      )
    ) {
      Text(
        "Automatic Y-axis",
        bundle: #bundle,
        comment: "Automatically scales the numeric chart Y-axis."
      )
      .tag(NumericChartYAxis.Mode.automatic)
      Text(
        "Fixed Y-axis",
        bundle: #bundle,
        comment: "Uses persisted fixed numeric chart Y-axis bounds."
      )
      .tag(NumericChartYAxis.Mode.fixed)
    } label: {
      Text(
        "Y-axis",
        bundle: #bundle,
        comment: "Label for numeric chart Y-axis scaling mode."
      )
    }
    if configuration.yAxis.mode == .fixed {
      HStack(spacing: 8) {
        TextField(
          value: Binding(
            get: { configuration.yAxis.lowerBound ?? 0 },
            set: setLowerBound
          ),
          format: .number
        ) {
          Text(
            "Y minimum",
            bundle: #bundle,
            comment: "Fixed numeric-chart Y-axis minimum."
          )
        }
        TextField(
          value: Binding(
            get: { configuration.yAxis.upperBound ?? 1 },
            set: setUpperBound
          ),
          format: .number
        ) {
          Text(
            "Y maximum",
            bundle: #bundle,
            comment: "Fixed numeric-chart Y-axis maximum."
          )
        }
      }
      .frame(maxWidth: 260)
    }
  }

  private func setMode(_ mode: NumericChartYAxis.Mode) {
    switch mode {
    case .automatic:
      store.send(.setYAxis(.automatic))
    case .fixed:
      let domain = automaticDomain
      guard
        let yAxis = try? NumericChartYAxis.fixed(
          lowerBound: domain.lowerBound,
          upperBound: domain.upperBound
        )
      else {
        return
      }
      store.send(.setYAxis(yAxis))
    }
  }

  private func setLowerBound(_ lowerBound: Double) {
    guard let upperBound = configuration.yAxis.upperBound,
      let yAxis = try? NumericChartYAxis.fixed(
        lowerBound: lowerBound,
        upperBound: upperBound
      )
    else {
      return
    }
    store.send(.setYAxis(yAxis))
  }

  private func setUpperBound(_ upperBound: Double) {
    guard let lowerBound = configuration.yAxis.lowerBound,
      let yAxis = try? NumericChartYAxis.fixed(
        lowerBound: lowerBound,
        upperBound: upperBound
      )
    else {
      return
    }
    store.send(.setYAxis(yAxis))
  }

  private var automaticDomain: ClosedRange<Double> {
    NumericChartDomain.automatic(for: samples)
  }
}

private struct NumericChartContent: View {
  @Bindable var store: NumericChartStore

  var body: some View {
    switch store.state.loadStatus {
    case .loading:
      ProgressView {
        Text(
          "Restoring Chart History",
          bundle: #bundle,
          comment: "Progress label while numeric chart history is restored."
        )
      }
      .frame(maxWidth: .infinity, minHeight: 180)

    case .failed:
      ContentUnavailableView {
        Label {
          Text(
            "Chart History Unavailable",
            bundle: #bundle,
            comment: "Numeric chart history load failure title."
          )
        } icon: {
          Image(systemName: "chart.xyaxis.line")
        }
      } description: {
        Text(
          "The durable history could not be loaded. Retry to restore the chart and resume live points.",
          bundle: #bundle,
          comment: "Explains a retryable numeric chart history failure."
        )
      } actions: {
        Button {
          store.send(.retry)
        } label: {
          Text(
            "Retry",
            bundle: #bundle,
            comment: "Retries numeric chart history restoration."
          )
        }
      }

    case .idle, .loaded:
      if store.state.displaySamples.isEmpty {
        ContentUnavailableView {
          Label {
            Text(
              "No Numeric Samples",
              bundle: #bundle,
              comment: "Empty numeric chart title."
            )
          } icon: {
            Image(systemName: "chart.xyaxis.line")
          }
        } description: {
          Text(
            "Stored and live values that match this series will appear here.",
            bundle: #bundle,
            comment: "Explains an empty numeric chart."
          )
        }
      } else {
        NumericLineChart(
          samples: store.state.displaySamples,
          timeDomain: store.state.visibleTimeRangeMicroseconds,
          yDomain: NumericChartDomain.domain(
            configuration: store.state.configuration,
            samples: store.state.displaySamples
          )
        )
        .frame(minHeight: 180)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          store.send(.setPixelWidth(Double($0)))
        }
      }
    }
  }
}

private struct NumericLineChart: View {
  let samples: [NumericChartSample]
  let timeDomain: ClosedRange<Int64>?
  let yDomain: ClosedRange<Double>

  var body: some View {
    let timeLabel = String(
      localized: "Chart time",
      bundle: #bundle,
      comment: "Charts axis label for numeric MQTT sample timestamps."
    )
    let valueLabel = String(
      localized: "Chart value",
      bundle: #bundle,
      comment: "Charts axis label for numeric MQTT sample values."
    )
    Chart(samples) { sample in
      LineMark(
        x: .value(
          timeLabel,
          Date(
            timeIntervalSince1970:
              Double(sample.receivedAtMicroseconds) / 1_000_000
          )
        ),
        y: .value(valueLabel, sample.value)
      )
      PointMark(
        x: .value(
          timeLabel,
          Date(
            timeIntervalSince1970:
              Double(sample.receivedAtMicroseconds) / 1_000_000
          )
        ),
        y: .value(valueLabel, sample.value)
      )
      .symbolSize(12)
    }
    .chartXScale(domain: dateDomain)
    .chartYScale(domain: yDomain)
    .accessibilityLabel(
      Text(
        "Numeric MQTT value over time",
        bundle: #bundle,
        comment: "Accessible description of the numeric MQTT line chart."
      )
    )
  }

  private var dateDomain: ClosedRange<Date> {
    guard let timeDomain else {
      let now = Date()
      return now.addingTimeInterval(-1)...now
    }
    return date(timeDomain.lowerBound)...date(timeDomain.upperBound)
  }

  private func date(_ microseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
  }
}

enum NumericChartDomain {
  static func domain(
    configuration: NumericChartConfiguration?,
    samples: [NumericChartSample]
  ) -> ClosedRange<Double> {
    guard let configuration,
      configuration.yAxis.mode == .fixed,
      let lowerBound = configuration.yAxis.lowerBound,
      let upperBound = configuration.yAxis.upperBound
    else {
      return automatic(for: samples)
    }
    return lowerBound...upperBound
  }

  static func automatic(
    for samples: [NumericChartSample]
  ) -> ClosedRange<Double> {
    guard let minimum = samples.map(\.value).min(),
      let maximum = samples.map(\.value).max()
    else {
      return 0...1
    }
    guard minimum == maximum else {
      let span = maximum - minimum
      guard span.isFinite else {
        return minimum...maximum
      }
      let padding = span * 0.05
      let lower = minimum - padding
      let upper = maximum + padding
      let boundedLower = lower.isFinite ? lower : minimum
      let boundedUpper = upper.isFinite ? upper : maximum
      return boundedLower...boundedUpper
    }

    let magnitude = abs(minimum)
    let padding = max(
      magnitude.isFinite ? magnitude * 0.05 : 0,
      1
    )
    let candidateLower = minimum - padding
    let candidateUpper = maximum + padding
    let lower =
      candidateLower.isFinite
      ? candidateLower
      : (minimum.nextDown.isFinite ? minimum.nextDown : minimum)
    let upper =
      candidateUpper.isFinite
      ? candidateUpper
      : (maximum.nextUp.isFinite ? maximum.nextUp : maximum)
    if lower < upper {
      return lower...upper
    }
    return -1...1
  }
}
