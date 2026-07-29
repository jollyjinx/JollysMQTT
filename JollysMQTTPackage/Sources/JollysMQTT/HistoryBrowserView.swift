import JollysMQTTCore
import JollysMQTTStorage
import SwiftUI

struct HistoryBrowserView: View {
  @Bindable var store: HistoryStore

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        "History",
        bundle: #bundle,
        comment: "Heading for durable MQTT payload history."
      )
      .font(.headline)

      if store.state.context == nil {
        Text(
          "History becomes available for the current value of a connected topic.",
          bundle: #bundle,
          comment: "History placeholder when no current MQTT topic is selected."
        )
        .foregroundStyle(.secondary)
      } else {
        HistoryPageControls(store: store)
        HistoryPageContent(store: store)
        if let comparison = store.state.comparison {
          PayloadComparisonView(comparison: comparison)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }
}

private struct HistoryPageControls: View {
  @Bindable var store: HistoryStore

  var body: some View {
    HStack(spacing: 8) {
      Button {
        store.send(.loadNewer)
      } label: {
        Label {
          Text(
            "Newer",
            bundle: #bundle,
            comment: "Loads a newer page of MQTT payload history."
          )
        } icon: {
          Image(systemName: "chevron.up")
        }
      }
      .disabled(!store.state.canLoadNewer || store.state.isLoading)

      Button {
        store.send(.loadOlder)
      } label: {
        Label {
          Text(
            "Older",
            bundle: #bundle,
            comment: "Loads an older page of MQTT payload history."
          )
        } icon: {
          Image(systemName: "chevron.down")
        }
      }
      .disabled(store.state.nextCursor == nil || store.state.isLoading)

      if store.state.isLoading {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(
            Text(
              "Loading History",
              bundle: #bundle,
              comment: "Progress label while durable MQTT history loads."
            )
          )
      }
    }
    .buttonStyle(.bordered)
  }
}

private struct HistoryPageContent: View {
  @Bindable var store: HistoryStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if store.state.loadError {
        Label {
          Text(
            "History could not be loaded.",
            bundle: #bundle,
            comment: "Error shown when a durable MQTT history page fails to load."
          )
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.red)
      } else if store.state.rows.isEmpty && !store.state.isLoading {
        Text(
          "No durable history is available for this topic and connection source.",
          bundle: #bundle,
          comment: "Empty durable MQTT history message."
        )
        .foregroundStyle(.secondary)
      }

      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(store.state.rows) { row in
          HistoryRowView(
            row: row,
            isSelected: store.state.selectedBaselineID == row.id,
            onSelect: {
              store.send(.toggleBaseline(row.id))
            },
            onCopy: {
              store.send(.copy(row.id))
            }
          )
        }
      }

      if let outcome = store.state.copyOutcome {
        HistoryCopyOutcomeView(outcome: outcome) {
          store.send(.dismissCopyOutcome)
        }
      }

      if !store.state.coverageGaps.isEmpty {
        HistoryCoverageGapsView(gaps: store.state.coverageGaps)
      }
    }
  }
}

private struct HistoryRowView: View {
  let row: HistoryRow
  let isSelected: Bool
  let onSelect: () -> Void
  let onCopy: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline) {
            Text(
              verbatim: row.receivedDate.formatted(
                date: .numeric,
                time: .standard
              )
            )
            .fontWeight(isSelected ? .semibold : .regular)
            Spacer()
            Text(
              "Payload size: \(row.message.payload.count) bytes",
              bundle: #bundle,
              comment: "Exact payload size for one durable history row."
            )
          }
          Text(
            "Unix time: \(row.message.receivedAtMicroseconds) µs",
            bundle: #bundle,
            comment:
              "Exact local receive timestamp in microseconds for one durable MQTT history row."
          )
          if let elapsed = row.elapsedToNewerMicroseconds {
            Text(
              "\(elapsed) µs before the next newer value",
              bundle: #bundle,
              comment:
                "Exact elapsed microseconds from this row to its next newer MQTT value."
            )
          }
          HStack(spacing: 10) {
            Text(
              "History QoS \(row.message.qos.rawValue)",
              bundle: #bundle,
              comment: "MQTT quality of service in a durable history row."
            )
            Text(row.directionLabel)
            Text(
              row.message.retained
                ? LocalizedStringResource(
                  "History retained delivery: Yes",
                  bundle: #bundle,
                  comment:
                    "History metadata saying an MQTT publish carried the retained-delivery flag."
                )
                : LocalizedStringResource(
                  "History retained delivery: No",
                  bundle: #bundle,
                  comment:
                    "History metadata saying an MQTT publish did not carry the retained-delivery flag."
                )
            )
          }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .background(
        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isSelected ? Color.accentColor : Color.secondary.opacity(0.25)
          )
      }
      .accessibilityLabel(Text(row.accessibilityLabel))
      .accessibilityValue(
        Text(
          isSelected
            ? LocalizedStringResource(
              "Selected comparison baseline",
              bundle: #bundle,
              comment: "Accessibility value for the selected history baseline."
            )
            : LocalizedStringResource(
              "Available comparison baseline",
              bundle: #bundle,
              comment: "Accessibility value for an unselected history baseline."
            )
        )
      )
      .accessibilityAddTraits(isSelected ? .isSelected : [])

      Button(action: onCopy) {
        Label {
          Text(
            "Copy",
            bundle: #bundle,
            comment: "Copies the exact raw bytes from one MQTT history row."
          )
        } icon: {
          Image(systemName: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel(
        Text(
          "Copy history payload raw bytes",
          bundle: #bundle,
          comment: "Accessible action to copy exact bytes from a history row."
        )
      )
    }
  }
}

private struct HistoryCopyOutcomeView: View {
  let outcome: HistoryCopyOutcome
  let onDismiss: () -> Void

  var body: some View {
    HStack {
      Label {
        Text(outcome.label)
      } icon: {
        Image(
          systemName: outcome.isSuccess
            ? "checkmark.circle"
            : "exclamationmark.triangle")
      }
      .foregroundStyle(outcome.isSuccess ? Color.secondary : Color.red)
      Spacer()
      Button(action: onDismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        Text(
          "Dismiss history copy result",
          bundle: #bundle,
          comment: "Dismisses a history payload copy result."
        )
      )
    }
    .accessibilityElement(children: .contain)
  }
}

private struct HistoryCoverageGapsView: View {
  let gaps: [StoredHistoryCoverageGap]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(
          "Source-wide history coverage gaps",
          bundle: #bundle,
          comment:
            "Heading for gaps affecting the complete MQTT connection source."
        )
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .font(.subheadline.weight(.semibold))

      Text(
        "These gaps affect the connection source and do not prove that this topic lost a message.",
        bundle: #bundle,
        comment:
          "Clarifies that source-wide durable history gaps are not topic-loss evidence."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      ForEach(gaps, id: \.durableOrder) { gap in
        HistoryCoverageGapView(gap: gap)
      }
    }
    .padding(10)
    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct HistoryCoverageGapView: View {
  let gap: StoredHistoryCoverageGap

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(gap.reason.label)
        .font(.caption.weight(.semibold))
      if gap.minimumMissingMessageCount == 1 {
        Text(
          "At least one source message was not persisted.",
          bundle: #bundle,
          comment:
            "A source-wide MQTT history gap contains at least one missing message."
        )
      } else {
        Text(
          "At least \(gap.minimumMissingMessageCount) source messages were not persisted.",
          bundle: #bundle,
          comment:
            "Minimum number of source-wide MQTT messages missing from durable history."
        )
      }
      Text(
        "Started at Unix time \(gap.startedAtMicroseconds) µs",
        bundle: #bundle,
        comment: "Exact start of a source-wide durable MQTT history gap."
      )
      if let ended = gap.endedAtMicroseconds {
        Text(
          "Ended at Unix time \(ended) µs",
          bundle: #bundle,
          comment: "Exact end of a source-wide durable MQTT history gap."
        )
      } else {
        Text(
          "The gap is still open.",
          bundle: #bundle,
          comment: "A source-wide durable MQTT history gap has no known end."
        )
      }
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
  }
}

private struct PayloadComparisonView: View {
  let comparison: PayloadComparison

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Current compared with baseline",
        bundle: #bundle,
        comment: "Heading for an MQTT payload revision comparison."
      )
      .font(.subheadline.weight(.semibold))

      switch comparison.presentation {
      case .json(let json):
        PayloadJSONComparisonView(comparison: json)
      case .text(let text):
        PayloadTextComparisonView(comparison: text)
      case .bytes(let bytes):
        PayloadByteComparisonView(comparison: bytes)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

private struct PayloadJSONComparisonView: View {
  let comparison: PayloadJSONComparison

  var body: some View {
    if comparison.differences.isEmpty {
      Text(
        "No JSON differences.",
        bundle: #bundle,
        comment: "Empty result for a structural JSON payload comparison."
      )
      .foregroundStyle(.secondary)
    } else {
      LazyVStack(alignment: .leading, spacing: 6) {
        ForEach(comparison.differences) { difference in
          VStack(alignment: .leading, spacing: 2) {
            Text(
              verbatim:
                difference.path.rawValue.isEmpty
                ? "/ (root)"
                : difference.path.rawValue
            )
            .font(.caption.monospaced().weight(.semibold))
            Text(difference.change.label)
              .font(.caption)
            if let baseline = difference.baselinePreview {
              Text(
                "Before: \(baseline)",
                bundle: #bundle,
                comment: "Baseline preview for one JSON payload difference."
              )
            }
            if let current = difference.currentPreview {
              Text(
                "Current: \(current)",
                bundle: #bundle,
                comment: "Current preview for one JSON payload difference."
              )
            }
          }
          .font(.caption)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }
    if comparison.isTruncated {
      ComparisonTruncationNotice()
    }
  }
}

private struct PayloadTextComparisonView: View {
  let comparison: PayloadTextComparison

  var body: some View {
    if comparison.lines.isEmpty {
      Text(
        "No text differences.",
        bundle: #bundle,
        comment: "Empty result for a text payload comparison."
      )
      .foregroundStyle(.secondary)
    } else {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(comparison.lines) { line in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: line.change.marker)
            if let lineNumber = line.lineNumber {
              Text(verbatim: String(lineNumber))
                .foregroundStyle(.secondary)
            }
            Text(verbatim: line.text + (line.isTruncated ? "…" : ""))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.caption.monospaced())
          .accessibilityLabel(Text(line.accessibilityLabel))
        }
      }
    }
    if comparison.isTruncated {
      ComparisonTruncationNotice()
    }
  }
}

private struct PayloadByteComparisonView: View {
  let comparison: PayloadByteComparison

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        "Bytes different in compared prefix: \(comparison.differingByteCount) of \(comparison.comparedByteCount).",
        bundle: #bundle,
        comment:
          "Summary for a bounded raw-byte MQTT payload comparison."
      )
      Text(
        "Baseline (\(comparison.baselineByteCount) bytes)",
        bundle: #bundle,
        comment: "Heading and exact byte count for the baseline hex preview."
      )
      .fontWeight(.semibold)
      Text(verbatim: comparison.baselineHex)
        .textSelection(.enabled)
      Text(
        "Current (\(comparison.currentByteCount) bytes)",
        bundle: #bundle,
        comment: "Heading and exact byte count for the current hex preview."
      )
      .fontWeight(.semibold)
      Text(verbatim: comparison.currentHex)
        .textSelection(.enabled)
    }
    .font(.caption.monospaced())
    if comparison.isTruncated {
      ComparisonTruncationNotice()
    }
  }
}

private struct ComparisonTruncationNotice: View {
  var body: some View {
    Text(
      "Comparison output is bounded; additional differences may exist.",
      bundle: #bundle,
      comment: "Notice shown when a payload comparison reaches a safety limit."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

extension HistoryRow {
  fileprivate var receivedDate: Date {
    Date(
      timeIntervalSince1970:
        Double(message.receivedAtMicroseconds) / 1_000_000
    )
  }

  fileprivate var directionLabel: LocalizedStringResource {
    message.direction == .received
      ? LocalizedStringResource(
        "Direction: Received",
        bundle: #bundle,
        comment: "Direction of an incoming durable MQTT history row."
      )
      : LocalizedStringResource(
        "Direction: Published",
        bundle: #bundle,
        comment: "Direction of an outgoing durable MQTT history row."
      )
  }

  fileprivate var accessibilityLabel: LocalizedStringResource {
    LocalizedStringResource(
      "\(directionLabel), Unix time \(message.receivedAtMicroseconds) microseconds, QoS \(message.qos.rawValue), \(message.retained ? "retained delivery" : "not retained"), \(message.payload.count) bytes",
      bundle: #bundle,
      comment:
        "Complete accessible metadata for one durable MQTT payload history row."
    )
  }
}

extension HistoryCopyOutcome {
  fileprivate var isSuccess: Bool {
    if case .succeeded = self { return true }
    return false
  }

  fileprivate var label: LocalizedStringResource {
    switch self {
    case .succeeded:
      LocalizedStringResource(
        "Copied history payload raw bytes",
        bundle: #bundle,
        comment: "Success after copying exact bytes from a durable history row."
      )
    case .failed:
      LocalizedStringResource(
        "History payload copy failed",
        bundle: #bundle,
        comment: "Failure after copying bytes from a durable history row."
      )
    }
  }
}

extension BrokerHistoryCoverageGapReason {
  fileprivate var label: LocalizedStringResource {
    switch self {
    case .storageFailure:
      LocalizedStringResource(
        "Storage failure",
        bundle: #bundle,
        comment: "Reason for a source-wide durable MQTT history gap."
      )
    case .localOverload:
      LocalizedStringResource(
        "Local overload",
        bundle: #bundle,
        comment: "Reason for a source-wide durable MQTT history gap."
      )
    }
  }
}

extension PayloadJSONDifferenceChange {
  fileprivate var label: LocalizedStringResource {
    switch self {
    case .added:
      LocalizedStringResource(
        "Added",
        bundle: #bundle,
        comment: "A JSON value was added in the current MQTT payload."
      )
    case .removed:
      LocalizedStringResource(
        "Removed",
        bundle: #bundle,
        comment: "A JSON value was removed from the current MQTT payload."
      )
    case .changed:
      LocalizedStringResource(
        "Changed",
        bundle: #bundle,
        comment: "A JSON value changed in the current MQTT payload."
      )
    }
  }
}

extension PayloadTextLineChange {
  fileprivate var marker: String {
    switch self {
    case .unchanged: " "
    case .removed: "−"
    case .added: "+"
    }
  }
}

extension PayloadTextLineDifference {
  fileprivate var accessibilityLabel: LocalizedStringResource {
    LocalizedStringResource(
      "\(change == .added ? "Added" : change == .removed ? "Removed" : "Unchanged") line \(lineNumber ?? 0): \(text)",
      bundle: #bundle,
      comment: "Accessible summary for one text payload difference."
    )
  }
}
