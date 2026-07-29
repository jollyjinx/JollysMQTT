import JollysMQTTCore
import JollysMQTTStorage
import SwiftUI

struct HistoryBrowserView: View {
  @Bindable var store: HistoryStore
  @Bindable var maintenanceStore: HistoryMaintenanceStore

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
        HistoryPageControls(
          store: store,
          maintenanceStore: maintenanceStore
        )
        HistoryPageContent(store: store)
        if let comparison = store.state.comparison {
          PayloadComparisonView(comparison: comparison)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .sheet(
      isPresented: Binding(
        get: { maintenanceStore.state.isPresented },
        set: { maintenanceStore.send(.setPresented($0)) }
      )
    ) {
      HistoryMaintenanceView(store: maintenanceStore)
    }
  }
}

private struct HistoryPageControls: View {
  @Bindable var store: HistoryStore
  @Bindable var maintenanceStore: HistoryMaintenanceStore

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

      Spacer()

      Button {
        maintenanceStore.send(.setPresented(true))
      } label: {
        Label {
          Text(
            "History Settings",
            bundle: #bundle,
            comment:
              "Opens local retention settings and destructive history controls."
          )
        } icon: {
          Image(systemName: "externaldrive.badge.gearshape")
        }
      }
    }
    .buttonStyle(.bordered)
  }
}

struct HistoryMaintenanceView: View {
  @Bindable var store: HistoryMaintenanceStore

  var body: some View {
    NavigationStack {
      Form {
        if let context = store.state.context {
          Section {
            LabeledContent(
              String(
                localized: "Broker",
                bundle: #bundle,
                comment: "Label for the broker affected by history settings."
              ),
              value: context.brokerName
            )
            if let topic = context.topic {
              LabeledContent(
                String(
                  localized: "Topic",
                  bundle: #bundle,
                  comment: "Label for the topic affected by a topic-history clear."
                ),
                value: topic
              )
            }
          }
          HistoryRetentionFields(store: store)
          HistoryDestructiveControls(store: store)
          if let notice = store.state.notice {
            HistoryMaintenanceNoticeView(notice: notice, store: store)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(
        Text(
          "Local History",
          bundle: #bundle,
          comment: "Title for local MQTT history settings."
        )
      )
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            store.send(.setPresented(false))
          } label: {
            Text(
              "Done",
              bundle: #bundle,
              comment: "Closes local history settings."
            )
          }
        }
      }
      .confirmationDialog(
        confirmationTitle,
        isPresented: Binding(
          get: { store.state.confirmation != nil },
          set: {
            if !$0 { store.send(.cancelClear) }
          }
        ),
        titleVisibility: .visible
      ) {
        Button(role: .destructive) {
          store.send(.confirmClear)
        } label: {
          Text(
            "Clear Confirmed Scope",
            bundle: #bundle,
            comment:
              "Confirms destructive clearing of the exact topic or broker history scope."
          )
        }
        Button(role: .cancel) {
          store.send(.cancelClear)
        } label: {
          Text(
            "Cancel",
            bundle: #bundle,
            comment: "Cancels a destructive local history clear."
          )
        }
      } message: {
        Text(confirmationMessage)
      }
    }
    #if os(macOS)
      .frame(minWidth: 480, minHeight: 560)
    #endif
  }

  private var confirmationTitle: LocalizedStringResource {
    store.state.confirmation == .topic
      ? LocalizedStringResource(
        "Clear Topic History?",
        bundle: #bundle,
        comment: "Confirmation title for exact topic history removal."
      )
      : LocalizedStringResource(
        "Clear Broker History?",
        bundle: #bundle,
        comment: "Confirmation title for all local broker history removal."
      )
  }

  private var confirmationMessage: LocalizedStringResource {
    guard let context = store.state.context else {
      return LocalizedStringResource(
        "No history scope is selected.",
        bundle: #bundle,
        comment: "Fallback history-clear confirmation message."
      )
    }
    if store.state.confirmation == .topic {
      guard let topic = context.topic else {
        return LocalizedStringResource(
          "No topic history scope is selected.",
          bundle: #bundle,
          comment: "Fallback topic-history confirmation message."
        )
      }
      return LocalizedStringResource(
        "Delete durable history for topic “\(topic)” from broker “\(context.brokerName)”? The live topic index and graph remain unchanged.",
        bundle: #bundle,
        comment:
          "Explains the exact topic-history clear scope and that live state is unaffected."
      )
    }
    return LocalizedStringResource(
      "Delete all durable message history and coverage records for broker “\(context.brokerName)”? The live topic index and graph remain unchanged.",
      bundle: #bundle,
      comment:
        "Explains the exact broker-history clear scope and that live state is unaffected."
    )
  }
}

private struct HistoryRetentionFields: View {
  @Bindable var store: HistoryMaintenanceStore

  var body: some View {
    Section {
      TextField(
        value: intBinding(
          get: { store.state.draft.topicMessageLimit },
          intent: HistoryMaintenanceFeature.Intent.setTopicMessageLimit
        ),
        format: .number
      ) {
        Text(
          "Messages per topic (1–1,000,000)",
          bundle: #bundle,
          comment: "Validated per-topic history message count field."
        )
      }
      TextField(
        value: int64Binding(
          get: { store.state.draft.brokerByteLimit },
          intent: HistoryMaintenanceFeature.Intent.setBrokerByteLimit
        ),
        format: .number
      ) {
        Text(
          "Maximum broker allocation in bytes (16 MiB–4 TiB)",
          bundle: #bundle,
          comment: "Validated maximum broker history allocation field."
        )
      }
      TextField(
        value: intBinding(
          get: { store.state.draft.payloadByteLimit },
          intent: HistoryMaintenanceFeature.Intent.setPayloadByteLimit
        ),
        format: .number
      ) {
        Text(
          "Maximum stored payload in bytes (1–67,108,864)",
          bundle: #bundle,
          comment: "Validated maximum stored history payload field."
        )
      }
      TextField(
        value: intBinding(
          get: { store.state.draft.messagePruneBatchLimit },
          intent: HistoryMaintenanceFeature.Intent.setMessagePruneBatchLimit
        ),
        format: .number
      ) {
        Text(
          "Rows per pruning transaction (1–5,000)",
          bundle: #bundle,
          comment: "Validated incremental history prune batch field."
        )
      }
      TextField(
        value: intBinding(
          get: { store.state.draft.vacuumPageLimit },
          intent: HistoryMaintenanceFeature.Intent.setVacuumPageLimit
        ),
        format: .number
      ) {
        Text(
          "Pages reclaimed per cleanup step (1–8,192)",
          bundle: #bundle,
          comment: "Validated incremental history vacuum page field."
        )
      }
      Text(
        "Broker allocation is a ceiling. Pruning begins near 60% and targets 50% so sustained traffic converges without one long transaction.",
        bundle: #bundle,
        comment:
          "Explains broker history allocation high-water and target behavior."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if store.state.validationError != nil {
        Text(
          "These retention values are outside the supported bounds or the payload limit exceeds one tenth of the broker allocation.",
          bundle: #bundle,
          comment: "Validation error for local history retention settings."
        )
        .foregroundStyle(.red)
      }
      if store.state.externalPolicyChanged {
        Text(
          "Another window changed this broker’s retention policy. Your unsaved draft is preserved; review it before saving.",
          bundle: #bundle,
          comment:
            "Warns that another scene changed retention while this sheet has a dirty draft."
        )
        .foregroundStyle(.orange)
      }
      Button {
        store.send(.save)
      } label: {
        Text(
          "Save and Apply Retention",
          bundle: #bundle,
          comment: "Saves local retention settings and runs bounded pruning."
        )
      }
      .disabled(store.state.isWorking)
    } header: {
      Text(
        "Retention",
        bundle: #bundle,
        comment: "Heading for local history retention fields."
      )
    }
  }

  private func intBinding(
    get: @escaping @MainActor @Sendable () -> Int,
    intent:
      @escaping @Sendable (Int) -> HistoryMaintenanceFeature.Intent
  ) -> Binding<Int> {
    Binding(get: get, set: { store.send(intent($0)) })
  }

  private func int64Binding(
    get: @escaping @MainActor @Sendable () -> Int64,
    intent:
      @escaping @Sendable (Int64) -> HistoryMaintenanceFeature.Intent
  ) -> Binding<Int64> {
    Binding(get: get, set: { store.send(intent($0)) })
  }
}

private struct HistoryDestructiveControls: View {
  @Bindable var store: HistoryMaintenanceStore

  var body: some View {
    Section {
      if store.state.context?.historySourceID != nil,
        store.state.context?.topic != nil
      {
        Button(role: .destructive) {
          store.send(.requestClear(.topic))
        } label: {
          Text(
            "Clear Topic History",
            bundle: #bundle,
            comment: "Requests exact selected-topic history removal."
          )
        }
      }
      Button(role: .destructive) {
        store.send(.requestClear(.broker))
      } label: {
        Text(
          "Clear Broker History",
          bundle: #bundle,
          comment: "Requests all local history removal for one broker."
        )
      }
    } header: {
      Text(
        "Destructive Actions",
        bundle: #bundle,
        comment: "Heading for local history deletion controls."
      )
    } footer: {
      Text(
        "Clearing durable history never clears the live topic index, current values, or graphs.",
        bundle: #bundle,
        comment: "Clarifies that history deletion does not mutate live state."
      )
    }
    .disabled(store.state.isWorking)
  }
}

extension HistoryMaintenanceNotice {
  fileprivate var severity: HistoryMaintenanceNoticeSeverity {
    switch self {
    case .settings(.failed), .clearFailed, .secureCleanupFailed:
      .error
    case .settings(.appliedFileProtectionPending),
      .settings(.committedMaintenanceFailed):
      .warning
    case .clear(let outcome)
    where outcome.continuation != nil
      || outcome.summary.secureCleanupStatus == .pending:
      .warning
    case .settings(.applied), .clear, .secureCleanupCompleted:
      .success
    }
  }

  fileprivate var label: LocalizedStringResource {
    switch self {
    case .settings(.applied):
      LocalizedStringResource(
        "Retention settings were saved and bounded pruning completed.",
        bundle: #bundle,
        comment: "Successful retention settings outcome."
      )
    case .settings(.appliedFileProtectionPending):
      LocalizedStringResource(
        "Retention settings were saved and applied, but file protection could not be refreshed.",
        bundle: #bundle,
        comment:
          "Settings committed but platform file-protection metadata failed."
      )
    case .settings(
      .committedMaintenanceFailed(let fileProtectionPending)
    ):
      fileProtectionPending
        ? LocalizedStringResource(
          "Settings were saved, but pruning and file-protection refresh need retrying.",
          bundle: #bundle,
          comment:
            "Settings committed while both pruning and file protection failed."
        )
        : LocalizedStringResource(
          "Settings were saved, but bounded pruning could not complete.",
          bundle: #bundle,
          comment: "Settings committed but applying retention failed."
        )
    case .settings(.failed):
      LocalizedStringResource(
        "Retention settings were not saved. Existing settings remain active.",
        bundle: #bundle,
        comment: "Retention settings failed before commit."
      )
    case .clear(let outcome) where outcome.continuation != nil:
      outcome.interruptedLabel
    case .clear(let outcome)
    where outcome.summary.secureCleanupStatus == .pending:
      LocalizedStringResource(
        "History rows were cleared, but the secure WAL and free-page cleanup is pending.",
        bundle: #bundle,
        comment: "Logical clear succeeded while secure cleanup remains pending."
      )
    case .clear(let outcome):
      LocalizedStringResource(
        "Cleared \(outcome.summary.deletedMessageCount) messages, \(outcome.summary.deletedTopicCount) topic records, and \(outcome.summary.deletedCoverageGapCount) coverage records.",
        bundle: #bundle,
        comment: "Completed local history clear counts."
      )
    case .clearFailed:
      LocalizedStringResource(
        "History was not cleared. No committed partial progress was reported.",
        bundle: #bundle,
        comment: "History clear failed before any reported committed progress."
      )
    case .secureCleanupCompleted:
      LocalizedStringResource(
        "Secure history cleanup completed.",
        bundle: #bundle,
        comment: "Successful retry of local history secure cleanup."
      )
    case .secureCleanupFailed:
      LocalizedStringResource(
        "Secure cleanup is still pending. Close other history readers and retry.",
        bundle: #bundle,
        comment: "Secure local history cleanup retry failed."
      )
    }
  }
}

extension HistoryClearOutcome {
  fileprivate var interruptedLabel: LocalizedStringResource {
    switch continuation {
    case .topic(let scope, _):
      LocalizedStringResource(
        "Clearing topic “\(scope.topic)” was interrupted after deleting \(summary.deletedMessageCount) messages. Resume uses its original confirmation cutoff.",
        bundle: #bundle,
        comment:
          "Partial topic clear outcome naming the original topic and safe cutoff."
      )
    case .broker:
      LocalizedStringResource(
        "Broker history clearing was interrupted after deleting \(summary.deletedMessageCount) messages. Resume uses its original confirmation cutoff.",
        bundle: #bundle,
        comment:
          "Partial broker clear outcome retaining the original safe cutoff."
      )
    case nil:
      LocalizedStringResource(
        "History clearing completed.",
        bundle: #bundle,
        comment: "Fallback completed history-clear label."
      )
    }
  }
}

private struct HistoryMaintenanceNoticeView: View {
  let notice: HistoryMaintenanceNotice
  @Bindable var store: HistoryMaintenanceStore

  var body: some View {
    Section {
      Label {
        Text(notice.label)
      } icon: {
        Image(systemName: notice.severity.systemImage)
      }
      .foregroundStyle(notice.severity.color)
      if case .clear(let outcome) = notice,
        outcome.continuation != nil
      {
        Button {
          store.send(.resumeClear)
        } label: {
          Text(
            "Resume Clear",
            bundle: #bundle,
            comment:
              "Resumes an interrupted clear using its original confirmation cutoff."
          )
        }
      }
      if case .clear(let outcome) = notice,
        outcome.summary.secureCleanupStatus == .pending
      {
        Button {
          store.send(.retrySecureCleanup)
        } label: {
          Text(
            "Retry Secure Cleanup",
            bundle: #bundle,
            comment: "Retries WAL checkpoint and free-page cleanup."
          )
        }
      }
    }
  }
}

private enum HistoryMaintenanceNoticeSeverity {
  case success
  case warning
  case error

  var systemImage: String {
    switch self {
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    }
  }

  var color: Color {
    switch self {
    case .success: .secondary
    case .warning: .orange
    case .error: .red
    }
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
      Group {
        if row.message.hasStoredPayload {
          Button(action: onSelect) {
            metadata
          }
          .buttonStyle(.plain)
        } else {
          metadata
        }
      }
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
      .accessibilityValue(Text(row.accessibilityValue(isSelected: isSelected)))
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
      .disabled(!row.message.hasStoredPayload)
      .accessibilityLabel(
        Text(
          "Copy history payload raw bytes",
          bundle: #bundle,
          comment: "Accessible action to copy exact bytes from a history row."
        )
      )
    }
  }

  private var metadata: some View {
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
          "Payload size: \(row.message.originalPayloadByteCount) bytes",
          bundle: #bundle,
          comment:
            "Original MQTT payload size for one durable history row, including metadata-only rows."
        )
      }
      if !row.message.hasStoredPayload {
        Label {
          Text(
            "Payload bytes omitted by the local history size limit",
            bundle: #bundle,
            comment:
              "Explains that a durable history row kept metadata but omitted an oversized payload."
          )
        } icon: {
          Image(systemName: "externaldrive.badge.exclamationmark")
        }
        .foregroundStyle(.secondary)
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
    let retainedLabel =
      message.retained
      ? LocalizedStringResource(
        "Retained delivery",
        bundle: #bundle,
        comment: "Accessible retained-delivery history metadata."
      )
      : LocalizedStringResource(
        "Not retained",
        bundle: #bundle,
        comment: "Accessible non-retained history metadata."
      )
    let availabilityLabel =
      message.hasStoredPayload
      ? LocalizedStringResource(
        "Payload available",
        bundle: #bundle,
        comment: "Accessible history payload availability."
      )
      : LocalizedStringResource(
        "Payload omitted by history limit",
        bundle: #bundle,
        comment: "Accessible history payload omission reason."
      )
    return LocalizedStringResource(
      "\(directionLabel), Unix time \(message.receivedAtMicroseconds) microseconds, QoS \(message.qos.rawValue), \(retainedLabel), \(message.originalPayloadByteCount) bytes, \(availabilityLabel)",
      bundle: #bundle,
      comment:
        "Complete accessible metadata for one durable MQTT payload history row, including whether payload bytes are available."
    )
  }

  fileprivate func accessibilityValue(
    isSelected: Bool
  ) -> LocalizedStringResource {
    guard message.hasStoredPayload else {
      return LocalizedStringResource(
        "Payload unavailable for comparison",
        bundle: #bundle,
        comment:
          "Accessibility value for a metadata-only history row that cannot be used as a comparison baseline."
      )
    }
    return isSelected
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
