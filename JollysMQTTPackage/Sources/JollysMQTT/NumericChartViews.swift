import Charts
import JollysMQTTCore
import SwiftUI

struct NumericChartPinControls: View {
  let inspection: PayloadInspection
  let selectedJSONPointer: PayloadJSONPointer?
  let pinnedSeries: [NumericChartSeries]
  let isAtCapacity: Bool
  let onPin: (NumericChartSeries) -> Void

  var body: some View {
    let availability = NumericChartPinEvaluator.availability(
      inspection: inspection,
      selectedJSONPointer: selectedJSONPointer
    )
    VStack(alignment: .leading, spacing: 6) {
      switch availability {
      case .available(let series):
        let isPinned = pinnedSeries.contains {
          NumericChartPinStateEvaluator.isPinned(
            candidate: series,
            pinnedSeries: $0
          )
        }
        Button {
          onPin(series)
        } label: {
          Label {
            Text(
              isPinned
                ? LocalizedStringResource(
                  "Pin Another Chart",
                  bundle: #bundle,
                  comment: "Pins another card for a series already on the dashboard."
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
        .disabled(isAtCapacity)
        if isAtCapacity {
          Text(
            "The dashboard has reached its bounded card limit.",
            bundle: #bundle,
            comment: "Explains why another numeric chart card cannot be pinned."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
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

enum NumericChartDashboardLayout: Equatable {
  case wide
  case compact
}

struct NumericChartDashboardView: View {
  @Bindable var dashboard: NumericChartDashboardStore
  let layout: NumericChartDashboardLayout
  @State private var availableWidth: CGFloat = 1_024
  #if os(macOS)
    @Environment(MacChartWindowController.self) private var chartWindows
      : MacChartWindowController?
  #endif

  private var visibleCards: [NumericChartCardConfiguration] {
    #if os(macOS)
      dashboard.state.cards.filter { chartWindows?.detachedCardIDs.contains($0.id) != true }
    #else
      dashboard.state.cards
    #endif
  }

  var body: some View {
    Group {
      if dashboard.state.cards.isEmpty {
        ContentUnavailableView {
          Label {
            Text(
              "No Pinned Charts",
              bundle: #bundle,
              comment: "Empty numeric chart dashboard title."
            )
          } icon: {
            Image(systemName: "chart.xyaxis.line")
          }
        } description: {
          Text(
            "Select a numeric or Boolean payload in topic information, then choose Pin to Chart.",
            bundle: #bundle,
            comment: "Explains how to add cards to the chart dashboard."
          )
        }
      } else if visibleCards.isEmpty {
        ContentUnavailableView {
          Label {
            Text("Charts in Separate Windows", bundle: #bundle,
              comment: "Dashboard placeholder when every chart has been moved to its own window.")
          } icon: {
            Image(systemName: "macwindow.on.rectangle")
          }
        } description: {
          Text("Close a chart window to return it to this dashboard.", bundle: #bundle,
            comment: "Explains how to bring a detached chart back to the dashboard.")
        }
      } else {
        switch layout {
        case .wide:
          NumericChartWideGrid(
            dashboard: dashboard,
            cards: visibleCards,
            availableWidth: availableWidth
          )
        case .compact:
          LazyVStack(spacing: 12) {
            ForEach(visibleCards) { card in
              NumericChartCard(
                card: card,
                dashboard: dashboard
              )
            }
          }
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      availableWidth = max(1, $0)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct NumericChartWideGrid: View {
  @Bindable var dashboard: NumericChartDashboardStore
  let cards: [NumericChartCardConfiguration]
  let availableWidth: CGFloat

  var body: some View {
    let grid = NumericChartDashboardGridLayout(
      cards: cards,
      availableWidth: availableWidth
    )
    Grid(
      alignment: .topLeading,
      horizontalSpacing: 12,
      verticalSpacing: 12
    ) {
      ForEach(grid.rows) { row in
        GridRow(alignment: .top) {
          ForEach(row.placements) { placement in
            NumericChartCard(
              card: placement.card,
              dashboard: dashboard
            )
            .gridCellColumns(placement.columnSpan)
          }
          if row.unusedColumnCount > 0 {
            Color.clear
              .frame(minHeight: 1)
              .gridCellColumns(row.unusedColumnCount)
              .accessibilityHidden(true)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct NumericChartDashboardGridLayout: Equatable {
  struct Placement: Equatable, Identifiable {
    let card: NumericChartCardConfiguration
    let columnSpan: Int

    var id: NumericChartCardID { card.id }
  }

  struct Row: Equatable, Identifiable {
    let placements: [Placement]
    let columnCount: Int

    var id: [NumericChartCardID] {
      placements.map(\.id)
    }

    var unusedColumnCount: Int {
      columnCount - placements.reduce(0) { $0 + $1.columnSpan }
    }
  }

  let columnCount: Int
  let rows: [Row]

  init(
    cards: [NumericChartCardConfiguration],
    availableWidth: CGFloat
  ) {
    if availableWidth >= 1_080 {
      columnCount = 3
    } else if availableWidth >= 700 {
      columnCount = 2
    } else {
      columnCount = 1
    }

    var completedRows: [Row] = []
    var placements: [Placement] = []
    var usedColumns = 0
    for card in cards {
      let span = Self.columnSpan(
        for: card.gridSpan,
        columnCount: columnCount
      )
      if usedColumns + span > columnCount {
        completedRows.append(
          Row(placements: placements, columnCount: columnCount)
        )
        placements = []
        usedColumns = 0
      }
      placements.append(Placement(card: card, columnSpan: span))
      usedColumns += span
      if usedColumns == columnCount {
        completedRows.append(
          Row(placements: placements, columnCount: columnCount)
        )
        placements = []
        usedColumns = 0
      }
    }
    if !placements.isEmpty {
      completedRows.append(
        Row(placements: placements, columnCount: columnCount)
      )
    }
    rows = completedRows
  }

  private static func columnSpan(
    for span: NumericChartGridSpan,
    columnCount: Int
  ) -> Int {
    switch span {
    case .automatic, .third:
      1
    case .half:
      max(1, (columnCount + 1) / 2)
    case .full:
      columnCount
    }
  }
}

struct NumericChartCard: View {
  let card: NumericChartCardConfiguration
  @Bindable var dashboard: NumericChartDashboardStore

  var body: some View {
    GroupBox {
      if let store = dashboard.cardStore(for: card.id),
        let configuration = store.state.configuration
      {
        VStack(alignment: .leading, spacing: 12) {
          NumericChartHeader(
            card: card,
            configuration: configuration,
            dashboard: dashboard,
            store: store
          )
          NumericChartContent(
            card: card,
            store: store
          )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } label: {
      Text(
        "Pinned Numeric Chart",
        bundle: #bundle,
        comment: "Heading for one pinned numeric MQTT chart card."
      )
    }
    .accessibilityElement(children: .contain)
  }
}

private struct NumericChartHeader: View {
  let card: NumericChartCardConfiguration
  let configuration: NumericChartConfiguration
  @Bindable var dashboard: NumericChartDashboardStore
  @Bindable var store: NumericChartStore
  @State private var settingsArePresented = false
  #if os(macOS)
    @Environment(MacChartWindowController.self) private var chartWindows
      : MacChartWindowController?
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
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
      HStack(spacing: 12) {
        Button {
          store.send(.setPaused(!configuration.isPaused))
        } label: {
          Label {
            Text(
              configuration.isPaused
                ? LocalizedStringResource(
                  "Resume",
                  bundle: #bundle,
                  comment: "Resumes one numeric chart card."
                )
                : LocalizedStringResource(
                  "Pause",
                  bundle: #bundle,
                  comment: "Pauses one numeric chart card."
                )
            )
          } icon: {
            Image(
              systemName:
                configuration.isPaused
                ? "play.fill"
                : "pause.fill"
            )
          }
        }
        .accessibilityLabel(
          Text(
            configuration.isPaused
              ? LocalizedStringResource(
                "Resume chart for \(configuration.series.id.topic)",
                bundle: #bundle,
                comment:
                  "Accessible and Voice Control action that resumes one chart. The variable is the exact MQTT topic."
              )
              : LocalizedStringResource(
                "Pause chart for \(configuration.series.id.topic)",
                bundle: #bundle,
                comment:
                  "Accessible and Voice Control action that pauses one chart. The variable is the exact MQTT topic."
              )
          )
        )
        Spacer()
        Button {
          settingsArePresented = true
        } label: {
          Label {
            Text("Settings", bundle: #bundle,
              comment: "Opens the settings popover for one numeric chart card.")
          } icon: {
            Image(systemName: "slider.horizontal.3")
          }
        }
        .labelStyle(.iconOnly)
        .help(Text("Settings", bundle: #bundle))
        .accessibilityLabel(
          Text("Settings for \(configuration.series.id.topic)", bundle: #bundle,
            comment: "Accessible action that opens one chart's settings popover. The variable is the exact MQTT topic.")
        )
        .popover(isPresented: $settingsArePresented, arrowEdge: .top) {
          NumericChartSettingsPopover(cardID: card.id, dashboard: dashboard)
            .presentationCompactAdaptation(.popover)
        }
        #if os(macOS)
          if let chartWindows {
            let isDetached = chartWindows.detachedCardIDs.contains(card.id)
            let windowAction = isDetached
              ? LocalizedStringResource("Return to Dashboard", bundle: #bundle,
                comment: "Returns a chart from its separate window to the dashboard.")
              : LocalizedStringResource("Move to Separate Window", bundle: #bundle,
                comment: "Moves one chart out of the dashboard into its own window.")
            Button {
              if isDetached {
                chartWindows.returnToDashboard(card.id)
              } else {
                chartWindows.detach(card.id)
              }
            } label: {
              Label {
                Text(windowAction)
              } icon: {
                Image(systemName: isDetached ? "arrow.down.left.square" : "arrow.up.right.square")
              }
            }
            .labelStyle(.iconOnly)
            .help(Text(windowAction))
            .accessibilityIdentifier("chart.window.\(card.id.rawValue)")
          }
        #endif
        Button(role: .destructive) {
          dashboard.send(.remove(card.id))
        } label: {
          Label {
            Text(
              "Remove Chart",
              bundle: #bundle,
              comment: "Removes one pinned numeric chart card."
            )
          } icon: {
            Image(systemName: "xmark")
          }
        }
        .labelStyle(.iconOnly)
        .help(Text("Remove Chart", bundle: #bundle))
        .accessibilityLabel(
          Text(
            "Remove chart for \(configuration.series.id.topic)",
            bundle: #bundle,
            comment:
              "Accessible and Voice Control action that removes one chart. The variable is the exact MQTT topic."
          )
        )
      }
    }
  }
}

private struct NumericChartSettingsPopover: View {
  let cardID: NumericChartCardID
  @Bindable var dashboard: NumericChartDashboardStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Chart Settings", bundle: #bundle,
          comment: "Title of the numeric chart settings popover.")
          .font(.headline)
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Done", bundle: #bundle,
            comment: "Closes the chart settings popover.")
        }
      }
      ScrollView {
        if let card = dashboard.state.cards.first(where: { $0.id == cardID }),
          let store = dashboard.cardStore(for: cardID),
          let configuration = store.state.configuration
        {
          NumericChartSettings(
            card: card, configuration: configuration, samples: store.state.samples,
            dashboard: dashboard, store: store
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxHeight: 440)
    }
    .padding(16)
    .frame(width: 320)
  }
}

private struct NumericChartSettings: View {
  let card: NumericChartCardConfiguration
  let configuration: NumericChartConfiguration
  let samples: [NumericChartSample]
  @Bindable var dashboard: NumericChartDashboardStore
  @Bindable var store: NumericChartStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      controls
    }
  }

  @ViewBuilder
  private var controls: some View {
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
    Picker(
      selection: Binding(
        get: { card.presentationStyle },
        set: {
          dashboard.send(.setPresentationStyle(card.id, $0))
        }
      )
    ) {
      ForEach(NumericChartPresentationStyle.allCases, id: \.self) {
        Text($0.localizedName)
          .tag($0)
      }
    } label: {
      Text(
        "Style",
        bundle: #bundle,
        comment: "Label for a numeric chart card presentation style."
      )
    }
    Picker(
      selection: Binding(
        get: { card.color },
        set: { dashboard.send(.setColor(card.id, $0)) }
      )
    ) {
      ForEach(NumericChartColor.allCases, id: \.self) {
        Text($0.localizedName)
          .tag($0)
      }
    } label: {
      Text(
        "Color",
        bundle: #bundle,
        comment: "Label for a numeric chart card color."
      )
    }
    Picker(
      selection: Binding(
        get: { card.gridSpan },
        set: { dashboard.send(.setGridSpan(card.id, $0)) }
      )
    ) {
      ForEach(NumericChartGridSpan.allCases, id: \.self) {
        Text($0.localizedName)
          .tag($0)
      }
    } label: {
      Text(
        "Card Size",
        bundle: #bundle,
        comment: "Label for a numeric chart card adaptive grid span."
      )
    }
    Button {
      store.send(.clearDisplayedSamples)
    } label: {
      Label {
        Text(
          "Clear Displayed Samples",
          bundle: #bundle,
          comment: "Clears only samples displayed by one numeric chart card."
        )
      } icon: {
        Image(systemName: "eraser")
      }
    }
    .disabled(samples.isEmpty)
    .accessibilityLabel(
      Text(
        "Clear displayed samples for \(configuration.series.id.topic)",
        bundle: #bundle,
        comment:
          "Accessible and Voice Control action that clears one chart's displayed samples. The variable is the exact MQTT topic."
      )
    )
    Button {
      dashboard.send(.move(card.id, .earlier))
    } label: {
      Label {
        Text(
          "Move Earlier",
          bundle: #bundle,
          comment: "Moves one chart card earlier in dashboard order."
        )
      } icon: {
        Image(systemName: "arrow.up")
      }
    }
    .disabled(dashboard.state.cards.first?.id == card.id)
    .accessibilityLabel(
      Text(
        "Move chart for \(configuration.series.id.topic) earlier",
        bundle: #bundle,
        comment:
          "Accessible and Voice Control action that moves one chart earlier. The variable is the exact MQTT topic."
      )
    )
    Button {
      dashboard.send(.move(card.id, .later))
    } label: {
      Label {
        Text(
          "Move Later",
          bundle: #bundle,
          comment: "Moves one chart card later in dashboard order."
        )
      } icon: {
        Image(systemName: "arrow.down")
      }
    }
    .disabled(dashboard.state.cards.last?.id == card.id)
    .accessibilityLabel(
      Text(
        "Move chart for \(configuration.series.id.topic) later",
        bundle: #bundle,
        comment:
          "Accessible and Voice Control action that moves one chart later. The variable is the exact MQTT topic."
      )
    )
  }
}

extension NumericChartPresentationStyle {
  fileprivate var localizedName: LocalizedStringResource {
    switch self {
    case .line:
      LocalizedStringResource(
        "Line",
        bundle: #bundle,
        comment: "Numeric chart line presentation style."
      )
    case .points:
      LocalizedStringResource(
        "Points",
        bundle: #bundle,
        comment: "Numeric chart point presentation style."
      )
    case .step:
      LocalizedStringResource(
        "Step",
        bundle: #bundle,
        comment: "Numeric chart step-line presentation style."
      )
    }
  }
}

extension NumericChartColor {
  fileprivate var localizedName: LocalizedStringResource {
    switch self {
    case .system:
      LocalizedStringResource(
        "System",
        bundle: #bundle,
        comment: "System-default numeric chart color."
      )
    case .blue:
      LocalizedStringResource(
        "Blue",
        bundle: #bundle,
        comment: "Blue numeric chart card color."
      )
    case .green:
      LocalizedStringResource(
        "Green",
        bundle: #bundle,
        comment: "Green numeric chart card color."
      )
    case .orange:
      LocalizedStringResource(
        "Orange",
        bundle: #bundle,
        comment: "Orange numeric chart card color."
      )
    case .red:
      LocalizedStringResource(
        "Red",
        bundle: #bundle,
        comment: "Red numeric chart card color."
      )
    case .purple:
      LocalizedStringResource(
        "Purple",
        bundle: #bundle,
        comment: "Purple numeric chart card color."
      )
    case .pink:
      LocalizedStringResource(
        "Pink",
        bundle: #bundle,
        comment: "Pink numeric chart card color."
      )
    case .teal:
      LocalizedStringResource(
        "Teal",
        bundle: #bundle,
        comment: "Teal numeric chart card color."
      )
    }
  }

  fileprivate var swiftUIColor: Color {
    switch self {
    case .system:
      .accentColor
    case .blue:
      .blue
    case .green:
      .green
    case .orange:
      .orange
    case .red:
      .red
    case .purple:
      .purple
    case .pink:
      .pink
    case .teal:
      .teal
    }
  }
}

extension NumericChartGridSpan {
  fileprivate var localizedName: LocalizedStringResource {
    switch self {
    case .automatic:
      LocalizedStringResource(
        "Automatic",
        bundle: #bundle,
        comment: "Automatic numeric chart card size."
      )
    case .full:
      LocalizedStringResource(
        "Full Width",
        bundle: #bundle,
        comment: "Full-width numeric chart card size."
      )
    case .half:
      LocalizedStringResource(
        "Half Width",
        bundle: #bundle,
        comment: "Half-width numeric chart card size."
      )
    case .third:
      LocalizedStringResource(
        "Third Width",
        bundle: #bundle,
        comment: "Third-width numeric chart card size."
      )
    }
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
  let card: NumericChartCardConfiguration
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
        NumericChartPlot(
          samples: store.state.displaySamples,
          timeDomain: store.state.visibleTimeRangeMicroseconds,
          yDomain: NumericChartDomain.domain(
            configuration: store.state.configuration,
            samples: store.state.displaySamples
          ),
          presentationStyle: card.presentationStyle,
          color: card.color
        )
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          store.send(.setPixelWidth(Double($0)))
        }
      }
    }
  }
}

private struct NumericChartPlot: View {
  let samples: [NumericChartSample]
  let timeDomain: ClosedRange<Int64>?
  let yDomain: ClosedRange<Double>
  let presentationStyle: NumericChartPresentationStyle
  let color: NumericChartColor
  @State private var selectedDate: Date?
  @ScaledMetric(relativeTo: .caption) private var readoutHeight = 18

  var body: some View {
    plot(selectedSample: selectedSample)
      .frame(minHeight: 180)
      .padding(.top, readoutHeight + 10)
  }

  private func plot(selectedSample: NumericChartSample?) -> some View {
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
    return Chart {
      ForEach(samples) { sample in
        switch presentationStyle {
        case .line:
          LineMark(
            x: .value(timeLabel, date(sample.receivedAtMicroseconds)),
            y: .value(valueLabel, sample.value)
          )
          .foregroundStyle(color.swiftUIColor)
        case .points:
          PointMark(
            x: .value(timeLabel, date(sample.receivedAtMicroseconds)),
            y: .value(valueLabel, sample.value)
          )
          .foregroundStyle(color.swiftUIColor)
          .symbolSize(24)
        case .step:
          LineMark(
            x: .value(timeLabel, date(sample.receivedAtMicroseconds)),
            y: .value(valueLabel, sample.value)
          )
          .foregroundStyle(color.swiftUIColor)
          .interpolationMethod(.stepEnd)
        }
      }
      if let selectedSample {
        RuleMark(x: .value(timeLabel, date(selectedSample.receivedAtMicroseconds)))
          .foregroundStyle(.secondary.opacity(0.35))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .accessibilityHidden(true)
        PointMark(
          x: .value(timeLabel, date(selectedSample.receivedAtMicroseconds)),
          y: .value(valueLabel, selectedSample.value)
        )
        .foregroundStyle(color.swiftUIColor)
        .symbolSize(45)
        .accessibilityHidden(true)
      }
    }
    .chartXScale(domain: dateDomain)
    .chartYScale(domain: yDomain)
    .chartXSelection(value: $selectedDate)
    .chartOverlay { proxy in
      GeometryReader { geometry in
        if let selectedDate, let plotFrame = proxy.plotFrame,
          let selectedX = proxy.position(forX: selectedDate)
        {
          NumericChartReadoutLayout(anchorX: geometry[plotFrame].minX + selectedX) {
            NumericChartReadout(sample: selectedSample)
          }
          .frame(height: readoutHeight)
          .offset(y: -readoutHeight - 10)
        }
      }
      .allowsHitTesting(false)
    }
    .onHover { isHovering in
      if !isHovering { selectedDate = nil }
    }
    .accessibilityLabel(
      Text(
        "Numeric MQTT value over time",
        bundle: #bundle,
        comment: "Accessible description of the numeric MQTT line chart."
      )
    )
  }

  private var selectedSample: NumericChartSample? {
    guard let selectedDate, dateDomain.contains(selectedDate) else { return nil }
    // Inspect the actual plotted values, including the configured multiplier
    // and downsampling, without synthesizing values between MQTT messages.
    return samples.min {
      abs(date($0.receivedAtMicroseconds).timeIntervalSince(selectedDate))
        < abs(date($1.receivedAtMicroseconds).timeIntervalSince(selectedDate))
    }
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

/// Keeps the readout near the pointer while fitting it inside the chart's edges.
private struct NumericChartReadoutLayout: Layout {
  let anchorX: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let size = subviews.first?.sizeThatFits(proposal) ?? .zero
    return CGSize(width: proposal.width ?? size.width, height: proposal.height ?? size.height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let readout = subviews.first else { return }
    let width = min(readout.sizeThatFits(.unspecified).width, bounds.width)
    let leading = min(max(0, anchorX - width / 2), bounds.width - width)
    readout.place(
      at: CGPoint(x: bounds.minX + leading, y: bounds.midY),
      anchor: .leading,
      proposal: ProposedViewSize(width: width, height: bounds.height)
    )
  }
}

private struct NumericChartReadout: View {
  let sample: NumericChartSample?

  var body: some View {
    let timestamp = sample.map {
      Date(timeIntervalSince1970: Double($0.receivedAtMicroseconds) / 1_000_000)
        .formatted(.dateTime.month(.twoDigits).day(.twoDigits)
          .hour().minute().second().secondFraction(.fractional(3)))
    } ?? "—"
    let value = sample.map {
      $0.value.formatted(.number.precision(.significantDigits(1...12)))
    } ?? "—"

    HStack(spacing: 24) {
      Text(
        "Time: \(timestamp)",
        bundle: #bundle,
        comment: "Timestamp of the chart sample under the pointer, or a dash when none is selected."
      )
      .foregroundStyle(.secondary)
      Text(
        "Value: \(value)",
        bundle: #bundle,
        comment: "Scaled value of the chart sample under the pointer, or a dash when none is selected."
      )
      .foregroundStyle(Color.primary)
      .fontWeight(.medium)
    }
    .font(.caption)
    .monospacedDigit()
    .lineLimit(1)
    .minimumScaleFactor(0.75)
    .accessibilityElement(children: .combine)
    .accessibilityHidden(sample == nil)
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
