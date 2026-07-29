import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import SwiftUI

public struct JollysMQTTWindowCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  public init() {}

  public var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button {
        openWindow(value: WorkspaceID())
      } label: {
        Text(
          "New Window",
          bundle: #bundle,
          comment: "Command that opens a fresh broker-list workspace."
        )
      }
      .keyboardShortcut("n", modifiers: .command)
    }
  }
}

public struct JollysMQTTRootView: View {
  @State private var sceneStore: WorkspaceSceneStore

  @MainActor
  public init(
    workspaceID: WorkspaceID = WorkspaceID(),
    dependencies: JollysMQTTAppDependencies = .shared
  ) {
    _sceneStore = State(
      initialValue: dependencies.makeSceneStore(id: workspaceID)
    )
  }

  public var body: some View {
    WorkspaceSceneView(store: sceneStore)
  }
}

private struct WorkspaceSceneView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var store: WorkspaceSceneStore
  @Bindable private var workspaceStore: WorkspaceStore

  init(store: WorkspaceSceneStore) {
    self.store = store
    _workspaceStore = Bindable(wrappedValue: store.workspace)
  }

  var body: some View {
    WorkspaceContentView(
      route: store.workspace.state.record.route,
      selectedTopic: store.workspace.state.record.selectedTopic,
      serverListStore: store.serverList,
      sceneStore: store
    )
    .task {
      await store.run()
    }
    .task(id: store.serverList.state.connectReady?.requestID) {
      guard let ready = store.serverList.state.connectReady else { return }
      await store.connectCurrentWorkspace(ready)
    }
    .task(id: scenePhase) {
      #if os(iOS)
        await store.setSceneActive(scenePhase == .active)
      #endif
    }
    .onChange(of: store.serverList.state.selectedProfileID) { _, selection in
      guard selection != store.selectedProfileID else { return }
      store.selectedProfileID = selection
    }
    .alert(
      Text(
        "Workspace State Unavailable",
        bundle: #bundle,
        comment: "Title for workspace restoration or persistence failure."
      ),
      isPresented: $workspaceStore.persistenceErrorPresented
    ) {
      Button {
      } label: {
        Text(
          "OK",
          bundle: #bundle,
          comment: "Dismisses a workspace state error."
        )
      }
    } message: {
      Text(
        "Workspace state could not be restored or saved. Existing data was left unchanged.",
        bundle: #bundle,
        comment: "Explains a workspace restoration or persistence failure."
      )
    }
  }
}

private struct WorkspaceContentView: View {
  let route: WorkspaceRoute
  let selectedTopic: String?
  let serverListStore: ServerListStore
  let sceneStore: WorkspaceSceneStore

  var body: some View {
    switch route {
    case .serverList:
      ServerListView(store: serverListStore, sceneStore: sceneStore)
    case .connected(let profileID):
      ConnectedWorkspaceView(
        profileName: serverListStore.state.profiles.first {
          $0.id == profileID
        }?.profile.name,
        selectedTopic: selectedTopic,
        snapshot: sceneStore.connection.state.snapshot,
        topicState: sceneStore.topics.state,
        generationWarning:
          sceneStore.connection.state.generationWarning,
        sceneStore: sceneStore,
        onRetry: {
          Task { await sceneStore.connection.retry() }
        },
        onCancel: {
          Task { await sceneStore.connection.cancel() }
        },
        onApplyLater: {
          sceneStore.connection.applyPendingGenerationLater()
        },
        onReconnectAll: {
          Task { await sceneStore.connection.reconnectAllToApply() }
        },
        onShowBrokers: {
          Task { await sceneStore.showServerList() }
        }
      )
    }
  }
}

private struct ConnectedWorkspaceView: View {
  let profileName: String?
  let selectedTopic: String?
  let snapshot: BrokerFeedSnapshot
  let topicState: TopicOutlineFeature.State
  let generationWarning: BrokerFeedGenerationWarning?
  @Bindable var sceneStore: WorkspaceSceneStore
  let onRetry: () -> Void
  let onCancel: () -> Void
  let onApplyLater: () -> Void
  let onReconnectAll: () -> Void
  let onShowBrokers: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      ConnectedWorkspaceHeader(
        profileName: profileName,
        selectedTopic: selectedTopic
      )
      ConnectionStatusView(snapshot: snapshot)
      if let generationWarning {
        BrokerGenerationWarningView(
          warning: generationWarning,
          onApplyLater: onApplyLater,
          onReconnectAll: onReconnectAll
        )
      }
      HStack(spacing: 12) {
        if snapshot.lastFailure != nil || snapshot.phase == .idle {
          Button(action: onRetry) {
            Text(
              "Retry",
              bundle: #bundle,
              comment: "Retries a broker connection after a failure or cancellation."
            )
          }
          .buttonStyle(.borderedProminent)
        }
        if snapshot.phase.isConnectionWorkActive {
          Button(role: .cancel, action: onCancel) {
            Text(
              "Cancel",
              bundle: #bundle,
              comment: "Cancels the current broker connection or retry."
            )
          }
        }
        Button(action: onShowBrokers) {
          Text(
            "Show Brokers",
            bundle: #bundle,
            comment: "Returns a connected workspace to the broker list."
          )
        }
      }
      TopicExplorerView(
        state: topicState,
        sceneStore: sceneStore
      )
      if topicState.snapshot.historyIsHealthy == false {
        Label {
          Text(
            "History is unavailable. Live topic values are still updating.",
            bundle: #bundle,
            comment: "Warns that durable history failed while live MQTT ingestion continues."
          )
        } icon: {
          Image(systemName: "externaldrive.badge.exclamationmark")
        }
        .foregroundStyle(.secondary)
      }
    }
    .padding(20)
  }
}

private struct ConnectedWorkspaceHeader: View {
  let profileName: String?
  let selectedTopic: String?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "network.badge.shield.half.filled")
        .font(.title2)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        if let profileName {
          Text(verbatim: profileName)
            .font(.headline)
        } else {
          Text(
            "Broker Unavailable",
            bundle: #bundle,
            comment: "Connected-workspace heading when its saved broker profile is unavailable."
          )
          .font(.headline)
        }
        if let selectedTopic {
          Text(verbatim: selectedTopic)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
    }
  }
}

private struct TopicExplorerView: View {
  let state: TopicOutlineFeature.State
  @Bindable var sceneStore: WorkspaceSceneStore

  var body: some View {
    VStack(spacing: 8) {
      TopicOutlineControls(
        searchText: $sceneStore.topicSearchText,
        sortMode: $sceneStore.topicSortMode,
        isFrozen: state.isFrozen,
        pendingChangeCount: state.pendingChangeCount,
        pendingChangeCountIsCapped:
          state.pendingChangeCountIsCapped,
        onFreeze: sceneStore.freezeTopicView,
        onJumpToLive: sceneStore.jumpTopicViewToLive
      )
      if state.rows.isEmpty {
        TopicOutlineEmptyState(isSearching: !state.searchText.isEmpty)
          .frame(maxHeight: .infinity)
      } else {
        List(selection: $sceneStore.selectedTopicID) {
          ForEach(state.rows) { row in
            TopicOutlineRow(
              row: row,
              onToggleExpansion: {
                sceneStore.toggleTopicExpansion(row.id)
              }
            )
            .tag(row.id)
          }
        }
      }
    }
    .frame(minHeight: 320)
  }
}

private struct TopicOutlineEmptyState: View {
  let isSearching: Bool

  var body: some View {
    ContentUnavailableView {
      Label {
        if isSearching {
          Text(
            "No Matching Topics",
            bundle: #bundle,
            comment: "Empty topic explorer title when search has no matches."
          )
        } else {
          Text(
            "Waiting for Topics",
            bundle: #bundle,
            comment: "Empty topic explorer title before live messages arrive."
          )
        }
      } icon: {
        Image(systemName: "point.3.connected.trianglepath.dotted")
      }
    } description: {
      if isSearching {
        Text(
          "Try a different topic path or current value.",
          bundle: #bundle,
          comment: "Description shown when no indexed topic or payload summary matches search."
        )
      } else {
        Text(
          "Live topics will appear here as messages arrive.",
          bundle: #bundle,
          comment: "Description shown before the broker has delivered any topics."
        )
      }
    }
  }
}

private struct TopicOutlineControls: View {
  @Binding var searchText: String
  @Binding var sortMode: BrokerTopicSortMode
  let isFrozen: Bool
  let pendingChangeCount: Int
  let pendingChangeCountIsCapped: Bool
  let onFreeze: () -> Void
  let onJumpToLive: () -> Void

  var body: some View {
    ViewThatFits {
      HStack(spacing: 8) {
        TopicSearchField(searchText: $searchText)
        TopicSortPicker(sortMode: $sortMode)
        TopicFreezeButton(
          isFrozen: isFrozen,
          pendingChangeCount: pendingChangeCount,
          pendingChangeCountIsCapped: pendingChangeCountIsCapped,
          onFreeze: onFreeze,
          onJumpToLive: onJumpToLive
        )
      }
      VStack(spacing: 8) {
        TopicSearchField(searchText: $searchText)
        HStack(spacing: 8) {
          TopicSortPicker(sortMode: $sortMode)
          TopicFreezeButton(
            isFrozen: isFrozen,
            pendingChangeCount: pendingChangeCount,
            pendingChangeCountIsCapped: pendingChangeCountIsCapped,
            onFreeze: onFreeze,
            onJumpToLive: onJumpToLive
          )
        }
      }
    }
  }
}

private struct TopicSearchField: View {
  @Binding var searchText: String

  var body: some View {
    TextField(
      text: $searchText,
      prompt: Text(
        "Topic path or current value",
        bundle: #bundle,
        comment: "Prompt for searching indexed live topics and current payload summaries."
      )
    ) {
      Text(
        "Search Topics",
        bundle: #bundle,
        comment: "Label for topic path and current-value search."
      )
    }
    .textFieldStyle(.roundedBorder)
  }
}

private struct TopicSortPicker: View {
  @Binding var sortMode: BrokerTopicSortMode

  var body: some View {
    Picker(
      selection: $sortMode
    ) {
      ForEach(BrokerTopicSortMode.allCases, id: \.rawValue) { mode in
        Text(mode.localizedTitle)
          .tag(mode)
      }
    } label: {
      Text(
        "Sort Topics",
        bundle: #bundle,
        comment: "Label for choosing the topic outline sort order."
      )
    }
    .pickerStyle(.menu)
  }
}

private struct TopicFreezeButton: View {
  let isFrozen: Bool
  let pendingChangeCount: Int
  let pendingChangeCountIsCapped: Bool
  let onFreeze: () -> Void
  let onJumpToLive: () -> Void

  var body: some View {
    if isFrozen {
      Button(action: onJumpToLive) {
        Label {
          if pendingChangeCountIsCapped {
            Text(
              "Jump to Live (\(pendingChangeCount)+)",
              bundle: #bundle,
              comment:
                "Resumes a frozen topic view. The variable is a capped pending-message count."
            )
          } else {
            Text(
              "Jump to Live (\(pendingChangeCount))",
              bundle: #bundle,
              comment: "Resumes a frozen topic view. The variable is the pending-message count."
            )
          }
        } icon: {
          Image(systemName: "forward.end.fill")
        }
      }
      .buttonStyle(.borderedProminent)
    } else {
      Button(action: onFreeze) {
        Label {
          Text(
            "Freeze View",
            bundle: #bundle,
            comment: "Pauses presentation updates while live topic ingestion continues."
          )
        } icon: {
          Image(systemName: "pause.fill")
        }
      }
    }
  }
}

private struct TopicOutlineRow: View {
  let row: TopicOutlineRowState
  let onToggleExpansion: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if row.allowsExpansionToggle {
        Button(action: onToggleExpansion) {
          Image(
            systemName:
              row.isExpanded ? "chevron.down" : "chevron.right"
          )
          .frame(width: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          row.isExpanded
            ? LocalizedStringResource(
              "Collapse Topic",
              bundle: #bundle,
              comment: "Accessible action that collapses a topic branch."
            )
            : LocalizedStringResource(
              "Expand Topic",
              bundle: #bundle,
              comment: "Accessible action that expands a topic branch."
            )
        )
        .accessibilityHint(
          Text(
            "Changes visibility of descendants under \(row.fullTopic).",
            bundle: #bundle,
            comment:
              "Hint for a topic disclosure control. The variable is the exact MQTT topic path."
          )
        )
      } else {
        Color.clear.frame(width: 16)
          .accessibilityHidden(true)
      }
      TopicOutlineRowContent(row: row)
    }
    .padding(.leading, CGFloat(min(row.depth, 12)) * 16)
  }
}

private struct TopicOutlineRowContent: View {
  let row: TopicOutlineRowState

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          if row.level.isEmpty {
            Text(
              "Empty level",
              bundle: #bundle,
              comment: "Topic segment label that distinguishes an exact empty MQTT path component."
            )
            .fontWeight(row.isSelected ? .semibold : .regular)
          } else {
            Text(verbatim: row.level)
              .fontWeight(row.isSelected ? .semibold : .regular)
          }
          if row.hasValue {
            TopicActivityIndicator(latestOrdinal: row.latestOrdinal)
          }
          if row.retained {
            Image(systemName: "pin.fill")
              .foregroundStyle(.secondary)
              .accessibilityLabel(
                Text(
                  "Retained delivery",
                  bundle: #bundle,
                  comment: "Indicates that the latest MQTT delivery carried the retained flag."
                )
              )
          }
          if let qos = row.qos {
            Text(
              "QoS \(qos.rawValue)",
              bundle: #bundle,
              comment: "MQTT quality-of-service metadata. The variable is 0, 1, or 2."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        if let summary = row.payloadSummary, !summary.display.isEmpty {
          HStack(spacing: 4) {
            Text(verbatim: "=")
            Text(verbatim: summary.display)
            if summary.isTruncated {
              Text(verbatim: "…")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }
      Spacer()
      if row.hasChildren {
        Text(
          "\(row.descendantValueTopicCount) topics, \(row.descendantMessageCount) messages",
          bundle: #bundle,
          comment:
            "Topic branch descendant counters. The variables are descendant value-topic and message counts."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: row.fullTopic))
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(row.isSelected ? .isSelected : [])
  }

  private var accessibilityValue: Text {
    if let qos = row.qos, let summary = row.payloadSummary {
      if row.retained {
        return Text(
          "Retained delivery, QoS \(qos.rawValue), current value \(summary.display), \(row.descendantValueTopicCount) descendant topics, \(row.descendantMessageCount) descendant messages",
          bundle: #bundle,
          comment:
            "Accessible MQTT topic metadata. Variables are QoS, current payload summary, descendant value-topic count, and descendant message count."
        )
      } else {
        return Text(
          "Latest delivery, QoS \(qos.rawValue), current value \(summary.display), \(row.descendantValueTopicCount) descendant topics, \(row.descendantMessageCount) descendant messages",
          bundle: #bundle,
          comment:
            "Accessible MQTT topic metadata. Variables are QoS, current payload summary, descendant value-topic count, and descendant message count."
        )
      }
    } else if let qos = row.qos {
      if row.retained {
        return Text(
          "Retained delivery, QoS \(qos.rawValue), \(row.descendantValueTopicCount) descendant topics, \(row.descendantMessageCount) descendant messages",
          bundle: #bundle,
          comment:
            "Accessible MQTT topic metadata without a text summary. Variables are QoS, descendant value-topic count, and descendant message count."
        )
      } else {
        return Text(
          "Latest delivery, QoS \(qos.rawValue), \(row.descendantValueTopicCount) descendant topics, \(row.descendantMessageCount) descendant messages",
          bundle: #bundle,
          comment:
            "Accessible MQTT topic metadata without a text summary. Variables are QoS, descendant value-topic count, and descendant message count."
        )
      }
    } else {
      return Text(
        "\(row.descendantValueTopicCount) descendant topics, \(row.descendantMessageCount) descendant messages",
        bundle: #bundle,
        comment:
          "Accessible branch-only MQTT topic metadata. Variables are descendant value-topic and message counts."
      )
    }
  }
}

private struct TopicActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let latestOrdinal: UInt64?

  var body: some View {
    if reduceMotion {
      Image(systemName: "circle.fill")
        .font(.caption2)
        .foregroundStyle(.green)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "circle.fill")
        .font(.caption2)
        .foregroundStyle(.green)
        .symbolEffect(.pulse, value: latestOrdinal)
        .accessibilityHidden(true)
    }
  }
}

extension BrokerTopicSortMode {
  fileprivate var localizedTitle: LocalizedStringResource {
    switch self {
    case .name:
      LocalizedStringResource(
        "Name",
        bundle: #bundle,
        comment: "Sorts topic siblings alphabetically by segment name."
      )
    case .recentActivity:
      LocalizedStringResource(
        "Recent Activity",
        bundle: #bundle,
        comment: "Sorts topic siblings by latest subtree activity."
      )
    case .descendantMessages:
      LocalizedStringResource(
        "Most Messages",
        bundle: #bundle,
        comment: "Sorts topic siblings by descendant message count."
      )
    case .descendantTopics:
      LocalizedStringResource(
        "Most Topics",
        bundle: #bundle,
        comment: "Sorts topic siblings by descendant value-topic count."
      )
    }
  }
}

private struct BrokerGenerationWarningView: View {
  let warning: BrokerFeedGenerationWarning
  let onApplyLater: () -> Void
  let onReconnectAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(
          "Broker Settings Changed",
          bundle: #bundle,
          comment: "Title of the warning that a connected broker profile has newer settings."
        )
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.headline)

      if warning.blocker == .fixedClientIDConflict {
        Text(
          "The updated fixed client ID is already in use by another connection to this broker. Choose a different client ID before reconnecting.",
          bundle: #bundle,
          comment: "Explains why updated broker settings cannot reconnect all windows."
        )
      } else {
        Text(
          "All windows are still using the previous connection settings.",
          bundle: #bundle,
          comment: "Explains that a profile edit is pending for every connected workspace."
        )
      }

      ViewThatFits {
        HStack(spacing: 12) {
          actions
        }
        VStack(alignment: .leading, spacing: 8) {
          actions
        }
      }
    }
    .padding(12)
    .frame(maxWidth: 560, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var actions: some View {
    Button(action: onApplyLater) {
      Text(
        "Apply Later",
        bundle: #bundle,
        comment: "Dismisses this workspace's warning while keeping the active broker generation."
      )
    }
    Button(action: onReconnectAll) {
      Text(
        "Reconnect All Windows to Apply",
        bundle: #bundle,
        comment: "Reconnects every workspace for a broker using the pending profile settings."
      )
    }
    .buttonStyle(.borderedProminent)
    .disabled(warning.blocker != nil)
  }
}

private struct ConnectionStatusView: View {
  let snapshot: BrokerFeedSnapshot

  var body: some View {
    VStack(spacing: 8) {
      Label {
        Text(snapshot.phase.localizedTitle)
      } icon: {
        if snapshot.phase.showsProgress {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: snapshot.phase.systemImageName)
        }
      }
      .accessibilityLabel(snapshot.phase.localizedTitle)

      if let failure = snapshot.lastFailure {
        Text(failure.localizedDescription)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .accessibilityLabel(failure.localizedDescription)
      }
      if let retryAt = snapshot.retry?.retryAt {
        Text(
          "Next retry \(retryAt, style: .relative)",
          bundle: #bundle,
          comment: "Relative time until the next automatic broker reconnect."
        )
      }
    }
  }
}

extension BrokerFeedPhase {
  fileprivate var localizedTitle: LocalizedStringResource {
    switch self {
    case .idle:
      LocalizedStringResource("Disconnected", bundle: #bundle)
    case .resolving:
      LocalizedStringResource("Resolving broker", bundle: #bundle)
    case .connecting:
      LocalizedStringResource("Connecting", bundle: #bundle)
    case .subscribing:
      LocalizedStringResource("Subscribing", bundle: #bundle)
    case .connected:
      LocalizedStringResource("Connected", bundle: #bundle)
    case .waitingToReconnect:
      LocalizedStringResource("Waiting to reconnect", bundle: #bundle)
    case .disconnecting:
      LocalizedStringResource("Disconnecting", bundle: #bundle)
    case .suspended:
      LocalizedStringResource("Suspended", bundle: #bundle)
    case .failed:
      LocalizedStringResource("Connection failed", bundle: #bundle)
    case .overloaded:
      LocalizedStringResource("Connection overloaded", bundle: #bundle)
    }
  }

  fileprivate var showsProgress: Bool {
    switch self {
    case .resolving, .connecting, .subscribing, .waitingToReconnect,
      .disconnecting:
      true
    case .idle, .connected, .suspended, .failed, .overloaded:
      false
    }
  }

  fileprivate var isConnectionWorkActive: Bool {
    switch self {
    case .resolving, .connecting, .subscribing, .connected,
      .waitingToReconnect:
      true
    case .idle, .disconnecting, .suspended, .failed, .overloaded:
      false
    }
  }

  fileprivate var systemImageName: String {
    switch self {
    case .connected:
      "checkmark.circle"
    case .suspended:
      "pause.circle"
    case .failed, .overloaded:
      "exclamationmark.triangle"
    case .idle:
      "circle"
    case .resolving, .connecting, .subscribing, .waitingToReconnect,
      .disconnecting:
      "arrow.trianglehead.2.clockwise"
    }
  }
}

extension BrokerFeedFailure {
  fileprivate var localizedDescription: LocalizedStringResource {
    switch self {
    case .dnsResolutionFailed:
      LocalizedStringResource(
        "The broker name could not be resolved.",
        bundle: #bundle
      )
    case .networkUnavailable:
      LocalizedStringResource("The network is unavailable.", bundle: #bundle)
    case .transportUnavailable:
      LocalizedStringResource("The network connection ended.", bundle: #bundle)
    case .brokerUnavailable:
      LocalizedStringResource("The broker is unavailable.", bundle: #bundle)
    case .authenticationRejected:
      LocalizedStringResource(
        "The broker rejected the username or password.",
        bundle: #bundle
      )
    case .trustRejected:
      LocalizedStringResource(
        "The broker certificate is not trusted.",
        bundle: #bundle
      )
    case .invalidConfiguration:
      LocalizedStringResource(
        "The broker configuration is invalid.",
        bundle: #bundle
      )
    case .subscriptionRejected:
      LocalizedStringResource(
        "The broker rejected a subscription.",
        bundle: #bundle
      )
    case .localOverload:
      LocalizedStringResource(
        "Messages arrived faster than this device could process them.",
        bundle: #bundle
      )
    case .credentialUnavailable:
      LocalizedStringResource(
        "The device password is unavailable.",
        bundle: #bundle
      )
    case .sessionAlreadyInUse:
      LocalizedStringResource(
        "The MQTT session is already in use.",
        bundle: #bundle
      )
    case .fixedClientIDConflict:
      LocalizedStringResource(
        "Another broker connection is using this fixed client ID.",
        bundle: #bundle
      )
    case .protocolFailure:
      LocalizedStringResource(
        "The broker reported an MQTT protocol error.",
        bundle: #bundle
      )
    case .payloadTooLarge:
      LocalizedStringResource(
        "A received MQTT payload exceeded the configured size limit.",
        bundle: #bundle
      )
    }
  }
}

struct ServerListView: View {
  @Bindable var store: ServerListStore
  @Bindable var sceneStore: WorkspaceSceneStore

  var body: some View {
    NavigationSplitView {
      BrokerListSidebar(store: store, sceneStore: sceneStore)
    } detail: {
      BrokerListDetail(
        profile: store.state.profiles.first {
          $0.id == sceneStore.selectedProfileID
        }?.profile,
        credentialAvailability:
          sceneStore.selectedProfileID.flatMap {
            store.state.credentialStatuses[$0]?.availability
          },
        store: store
      )
    }
    .navigationTitle(
      Text(
        "JollysMQTT",
        bundle: #bundle,
        comment: "Application title shown in navigation chrome."
      )
    )
    .sheet(isPresented: $store.editorPresented) {
      if let editor = store.state.editor {
        ProfileEditorView(store: store, profileID: editor.id)
      }
    }
    .sheet(isPresented: $store.credentialPromptPresented) {
      if let prompt = store.state.credentialPrompt {
        CredentialPromptView(prompt: prompt, store: store)
      }
    }
    .confirmationDialog(
      Text(
        "Delete Broker?",
        bundle: #bundle,
        comment: "Title confirming deletion of a broker profile."
      ),
      isPresented: $store.deletionPresented,
      titleVisibility: .visible
    ) {
      Button(role: .destructive) {
        guard let profileID = store.state.pendingDeletionProfileID else { return }
        Task { await store.send(.deleteProfileAndCredential(profileID)) }
      } label: {
        Text(
          "Delete Profile and Password",
          bundle: #bundle,
          comment: "Destructive action that deletes a broker profile and its device password."
        )
      }
      Button(role: .destructive) {
        guard let profileID = store.state.pendingDeletionProfileID else { return }
        Task { await store.send(.deleteProfile(profileID)) }
      } label: {
        Text(
          "Delete Profile Only",
          bundle: #bundle,
          comment: "Destructive action that deletes a broker profile but keeps its device password."
        )
      }
      Button(role: .cancel) {
        store.sendImmediately(.cancelDeleteProfile)
      } label: {
        Text(
          "Cancel",
          bundle: #bundle,
          comment: "Action that cancels a broker profile operation."
        )
      }
    } message: {
      Text(
        "Choose whether to keep or delete the password stored on this device for “\(store.pendingDeletionName)”.",
        bundle: #bundle,
        comment: "Deletion warning. The variable is the broker profile name."
      )
    }
    .alert(
      Text(
        "Password Not Updated",
        bundle: #bundle,
        comment: "Title for a device credential operation failure."
      ),
      isPresented: $store.credentialErrorPresented
    ) {
      Button {
      } label: {
        Text(
          "OK",
          bundle: #bundle,
          comment: "Dismisses a credential operation error."
        )
      }
    } message: {
      CredentialErrorMessage(error: store.state.credentialError)
    }
  }
}

private struct BrokerListSidebar: View {
  @Bindable var store: ServerListStore
  @Bindable var sceneStore: WorkspaceSceneStore

  var body: some View {
    List(selection: $sceneStore.selectedProfileID) {
      ForEach(store.state.profiles) { ranked in
        BrokerProfileRow(
          name: ranked.profile.name,
          endpoint: ranked.profile.endpointSummary
        )
        .tag(ranked.id)
        .contextMenu {
          BrokerRowActions(profileID: ranked.id, store: store)
        }
      }
      .onMove { offsets, destination in
        guard let source = offsets.first else { return }
        let movingID = store.state.profiles[source].id
        let destinationID =
          destination < store.state.profiles.count
          ? store.state.profiles[destination].id
          : nil
        Task {
          await store.send(.moveProfile(movingID, before: destinationID))
        }
      }
    }
    .overlay {
      if store.state.isLoading {
        ProgressView()
          .accessibilityLabel(
            Text(
              "Loading broker profiles",
              bundle: #bundle,
              comment: "Accessibility label for profile loading progress."
            )
          )
      } else if store.state.profiles.isEmpty {
        BrokerListEmptyState()
      }
    }
    .toolbar {
      #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
          EditButton()
            .accessibilityHint(
              Text(
                "Enables drag handles for reordering broker profiles.",
                bundle: #bundle,
                comment: "Accessibility hint for editing broker list order."
              )
            )
        }
      #endif
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await store.send(.createProfile(id: UUID())) }
        } label: {
          Label {
            Text(
              "Add Broker",
              bundle: #bundle,
              comment: "Toolbar action that creates a broker profile."
            )
          } icon: {
            Image(systemName: "plus")
          }
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .accessibilityHint(
          Text(
            "Opens the broker profile editor.",
            bundle: #bundle,
            comment: "Accessibility hint for the add broker action."
          )
        )
      }
    }
  }
}

private struct BrokerProfileRow: View {
  let name: String
  let endpoint: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name)
        .font(.headline)
      Text(endpoint)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrokerRowActions: View {
  let profileID: BrokerProfile.ID
  let store: ServerListStore

  var body: some View {
    Button {
      Task { await store.send(.editProfile(profileID)) }
    } label: {
      Text(
        "Edit",
        bundle: #bundle,
        comment: "Context action that edits a broker profile."
      )
    }
    Button {
      Task {
        await store.send(.duplicateProfile(profileID, newID: UUID()))
      }
    } label: {
      Text(
        "Duplicate",
        bundle: #bundle,
        comment: "Context action that duplicates a broker profile."
      )
    }
    Button(role: .destructive) {
      store.sendImmediately(.requestDeleteProfile(profileID))
    } label: {
      Text(
        "Delete",
        bundle: #bundle,
        comment: "Context action that requests broker profile deletion."
      )
    }
  }
}

private struct BrokerListDetail: View {
  let profile: BrokerProfile?
  let credentialAvailability: CredentialAvailability?
  let store: ServerListStore

  var body: some View {
    VStack(spacing: 20) {
      if let profile {
        Image(systemName: profile.transport == .tls ? "lock.shield" : "network")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(profile.name)
          .font(.title)
        Text(profile.endpointSummary)
          .foregroundStyle(.secondary)
        if profile.username == nil {
          AnonymousBrokerStatus()
        } else {
          BrokerCredentialAvailability(availability: credentialAvailability)
        }
        BrokerDetailActions(profileID: profile.id, store: store)
      } else {
        BrokerListEmptyState()
      }

      if store.state.persistenceError {
        Label {
          Text(
            "Profile changes could not be saved.",
            bundle: #bundle,
            comment: "Error shown when local profile persistence fails."
          )
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.red)
        .accessibilityAddTraits(.isStaticText)
      } else if store.state.hasUnpersistedChanges {
        Label {
          Text(
            "Saving profile changes…",
            bundle: #bundle,
            comment: "Status shown while local profile changes are not yet durable."
          )
        } icon: {
          ProgressView()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
    }
    .padding()
  }
}

private struct BrokerCredentialAvailability: View {
  let availability: CredentialAvailability?

  var body: some View {
    switch availability {
    case .available:
      Label {
        Text(
          "Password available on this device",
          bundle: #bundle,
          comment: "Indicates that a broker password exists in this device's Keychain."
        )
      } icon: {
        Image(systemName: "key.fill")
      }
      .foregroundStyle(.secondary)
    case .missing:
      Label {
        Text(
          "Password required on this device",
          bundle: #bundle,
          comment: "Indicates that this device has no broker password."
        )
      } icon: {
        Image(systemName: "key.slash")
      }
      .foregroundStyle(.orange)
    case nil:
      Text(
        "Password availability is checked when connecting.",
        bundle: #bundle,
        comment: "Explains when the app checks for a device-local broker password."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }
}

private struct AnonymousBrokerStatus: View {
  var body: some View {
    Label {
      Text(
        "Anonymous connection; no password required",
        bundle: #bundle,
        comment: "Indicates that a broker profile has no username and does not use a password."
      )
    } icon: {
      Image(systemName: "person.crop.circle")
    }
    .foregroundStyle(.secondary)
  }
}

private struct CredentialPromptView: View {
  let prompt: CredentialPromptState
  let store: ServerListStore
  @State private var password = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField(text: $password) {
            Text(
              "Password",
              bundle: #bundle,
              comment: "Label for transient broker password entry."
            )
          }
          .textContentType(.password)
          .disabled(prompt.isSaving)
        } footer: {
          Text(
            "The password is stored only in this device’s Keychain.",
            bundle: #bundle,
            comment: "Privacy explanation below transient broker password entry."
          )
        }
      }
      .navigationTitle(
        Text(
          "Password for \(prompt.profileName)",
          bundle: #bundle,
          comment: "Credential prompt title. The variable is a broker profile name."
        )
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            password.removeAll(keepingCapacity: false)
            store.sendImmediately(.cancelCredentialPrompt)
          } label: {
            Text(
              "Cancel",
              bundle: #bundle,
              comment: "Cancels broker password entry."
            )
          }
          .disabled(prompt.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            let credential = TransientCredential(utf8: password)
            password.removeAll(keepingCapacity: false)
            Task {
              await store.send(.submitCredential(credential))
            }
          } label: {
            if prompt.isSaving {
              ProgressView()
                .accessibilityLabel(
                  Text(
                    "Saving password",
                    bundle: #bundle,
                    comment: "Accessibility label while a broker password is saved."
                  )
                )
            } else {
              Text(
                "Save and Connect",
                bundle: #bundle,
                comment: "Saves a device password and continues connecting."
              )
            }
          }
          .disabled(prompt.isSaving)
        }
      }
    }
    .frame(minWidth: 320, idealWidth: 440, minHeight: 220)
    .interactiveDismissDisabled(prompt.isSaving)
  }
}

private struct CredentialErrorMessage: View {
  let error: CredentialPresentationError?

  var body: some View {
    switch error {
    case .cancelled:
      Text(
        "Password access was cancelled. The broker profile was not changed.",
        bundle: #bundle,
        comment: "Explains a cancelled Keychain credential operation."
      )
    case .denied:
      Text(
        "Password access was denied. The broker profile was not changed.",
        bundle: #bundle,
        comment: "Explains a denied Keychain credential operation."
      )
    case .unavailable:
      Text(
        "The password could not be accessed. The broker profile was not changed.",
        bundle: #bundle,
        comment: "Explains an unavailable Keychain credential operation."
      )
    case nil:
      EmptyView()
    }
  }
}

private struct BrokerDetailActions: View {
  let profileID: BrokerProfile.ID
  let store: ServerListStore

  var body: some View {
    ViewThatFits {
      HStack {
        BrokerActionButtons(profileID: profileID, store: store)
      }
      VStack {
        BrokerActionButtons(profileID: profileID, store: store)
      }
    }
  }
}

private struct BrokerActionButtons: View {
  let profileID: BrokerProfile.ID
  let store: ServerListStore

  var body: some View {
    Button {
      Task { await store.send(.connect(profileID)) }
    } label: {
      Label {
        Text(
          "Connect",
          bundle: #bundle,
          comment: "Primary action that connects to a selected broker."
        )
      } icon: {
        Image(systemName: "bolt.horizontal")
      }
    }
    .buttonStyle(.borderedProminent)

    Button {
      Task { await store.send(.editProfile(profileID)) }
    } label: {
      Text(
        "Edit",
        bundle: #bundle,
        comment: "Action that edits the selected broker profile."
      )
    }
  }
}

private struct BrokerListEmptyState: View {
  var body: some View {
    ContentUnavailableView {
      Label {
        Text(
          "No Brokers",
          bundle: #bundle,
          comment: "Title of the initial empty broker-list screen."
        )
      } icon: {
        Image(systemName: "network")
      }
    } description: {
      Text(
        "Add a broker profile to get started.",
        bundle: #bundle,
        comment: "Description on the initial empty broker-list screen."
      )
    }
  }
}

private struct ProfileEditorView: View {
  let store: ServerListStore
  let profileID: BrokerProfile.ID

  var body: some View {
    NavigationStack {
      Form {
        ProfileEndpointSection(store: store)
        ProfileAuthenticationSection(store: store)
        ProfileAdvancedSection(store: store)
        ProfileValidationSection(issues: store.state.editor?.validationIssues ?? [])
      }
      .navigationTitle(
        Text(
          "Broker Profile",
          bundle: #bundle,
          comment: "Title of the broker profile editor."
        )
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            store.sendImmediately(.cancelEditor)
          } label: {
            Text(
              "Cancel",
              bundle: #bundle,
              comment: "Action that closes the profile editor without saving."
            )
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await store.send(.saveEditor) }
          } label: {
            Text(
              "Save",
              bundle: #bundle,
              comment: "Action that validates and saves a broker profile."
            )
          }
        }
      }
    }
    .id(profileID)
    .frame(minWidth: 360, idealWidth: 520, minHeight: 460)
  }
}

private struct ProfileEndpointSection: View {
  @Bindable var store: ServerListStore

  var body: some View {
    Section {
      TextField(
        text: $store[editorText: .name],
        prompt: Text(
          "Home Broker",
          bundle: #bundle,
          comment: "Example placeholder for a broker display name."
        )
      ) {
        Text(
          "Name",
          bundle: #bundle,
          comment: "Label for a broker profile display name."
        )
      }
      .textContentType(.name)

      TextField(text: $store[editorText: .host]) {
        Text(
          "Host",
          bundle: #bundle,
          comment: "Label for the broker host name or IP address."
        )
      }
      .textContentType(.URL)
      .autocorrectionDisabled()

      TextField(
        value: $store[editorInteger: .port],
        format: .number
      ) {
        Text(
          "Port",
          bundle: #bundle,
          comment: "Label for the broker network port."
        )
      }

      Picker(selection: $store.editorTransport) {
        Text(
          "TCP",
          bundle: #bundle,
          comment: "Unencrypted TCP broker transport."
        )
        .tag(BrokerTransport.tcp)
        Text(
          "TLS",
          bundle: #bundle,
          comment: "System-trust TLS broker transport."
        )
        .tag(BrokerTransport.tls)
      } label: {
        Text(
          "Transport",
          bundle: #bundle,
          comment: "Label for the broker transport picker."
        )
      }
    } header: {
      Text(
        "Connection",
        bundle: #bundle,
        comment: "Header for common broker endpoint settings."
      )
    }
  }
}

private struct ProfileAuthenticationSection: View {
  @Bindable var store: ServerListStore

  var body: some View {
    Section {
      TextField(text: $store[editorText: .username]) {
        Text(
          "Username",
          bundle: #bundle,
          comment: "Label for the optional MQTT username."
        )
      }
      .textContentType(.username)
      .autocorrectionDisabled()

      Text(
        "Passwords are stored separately on this device.",
        bundle: #bundle,
        comment: "Explains that secret material is outside the profile editor model."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    } header: {
      Text(
        "Authentication",
        bundle: #bundle,
        comment: "Header for broker authentication settings."
      )
    }
  }
}

private struct ProfileAdvancedSection: View {
  @Bindable var store: ServerListStore
  @State private var isExpanded = false

  var body: some View {
    Section {
      DisclosureGroup(isExpanded: $isExpanded) {
        ProfileSessionSettings(store: store)
        ProfileReconnectSettings(store: store)
        ProfileSubscriptionsSettings(store: store)
      } label: {
        Text(
          "Advanced Settings",
          bundle: #bundle,
          comment: "Disclosure label for uncommon profile settings."
        )
      }
    }
  }
}

private struct ProfileSessionSettings: View {
  @Bindable var store: ServerListStore

  var body: some View {
    Picker(selection: $store.editorClientIDMode) {
      Text(
        "Stable Generated",
        bundle: #bundle,
        comment: "Client ID mode derived stably for the installation and profile."
      )
      .tag(ServerListStore.EditorClientIDMode.stableGenerated)
      Text(
        "Random per Connection",
        bundle: #bundle,
        comment: "Client ID mode that creates an ID for every clean connection."
      )
      .tag(ServerListStore.EditorClientIDMode.randomPerConnection)
      Text(
        "Explicit",
        bundle: #bundle,
        comment: "Client ID mode entered by the user."
      )
      .tag(ServerListStore.EditorClientIDMode.explicit)
    } label: {
      Text(
        "Client ID",
        bundle: #bundle,
        comment: "Label for the MQTT client identifier policy."
      )
    }

    if store.editorClientIDMode == .explicit {
      TextField(text: $store[editorText: .explicitClientID]) {
        Text(
          "Explicit Client ID",
          bundle: #bundle,
          comment: "Label for a fixed MQTT client identifier."
        )
      }
      .autocorrectionDisabled()
    }

    Toggle(isOn: $store.editorCleanSession) {
      Text(
        "Clean Session",
        bundle: #bundle,
        comment: "Toggle controlling MQTT clean-session behavior."
      )
    }

    Stepper(
      value: $store[editorInteger: .keepAlive],
      in: 1...65_535
    ) {
      Text(
        "Keepalive: \(store[editorInteger: .keepAlive]) seconds",
        bundle: #bundle,
        comment: "MQTT keepalive value. The variable is a number of seconds."
      )
    }
  }
}

private struct ProfileReconnectSettings: View {
  @Bindable var store: ServerListStore

  var body: some View {
    Toggle(isOn: $store.editorReconnectEnabled) {
      Text(
        "Automatic Reconnect",
        bundle: #bundle,
        comment: "Toggle controlling automatic reconnect attempts."
      )
    }

    if store.editorReconnectEnabled {
      Stepper(
        value: $store[editorInteger: .reconnectInitial],
        in: 1...300
      ) {
        Text(
          "Initial delay: \(store[editorInteger: .reconnectInitial]) seconds",
          bundle: #bundle,
          comment: "Reconnect initial delay. The variable is a number of seconds."
        )
      }
      Stepper(
        value: $store[editorInteger: .reconnectMaximum],
        in: 1...86_400
      ) {
        Text(
          "Maximum delay: \(store[editorInteger: .reconnectMaximum]) seconds",
          bundle: #bundle,
          comment: "Reconnect maximum delay. The variable is a number of seconds."
        )
      }
    }
  }
}

private struct ProfileSubscriptionsSettings: View {
  let store: ServerListStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Subscriptions",
        bundle: #bundle,
        comment: "Header for MQTT subscription filters."
      )
      .font(.headline)

      if store.state.editor?.hasBroadSubscriptionWarning == true {
        Label {
          Text(
            "Broad subscriptions can be expensive on production brokers.",
            bundle: #bundle,
            comment: "Warning about default wildcard MQTT subscriptions."
          )
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        .accessibilityAddTraits(.isStaticText)
      }

      ForEach(store.state.editor?.subscriptions ?? []) { subscription in
        ProfileSubscriptionRow(
          subscriptionID: subscription.id,
          store: store
        )
      }

      Button {
        store.sendImmediately(.addSubscription(id: UUID()))
      } label: {
        Label {
          Text(
            "Add Subscription",
            bundle: #bundle,
            comment: "Action that adds an MQTT subscription filter."
          )
        } icon: {
          Image(systemName: "plus")
        }
      }
      .accessibilityHint(
        Text(
          "Adds an enabled topic filter at QoS 0.",
          bundle: #bundle,
          comment: "Accessibility hint for adding a subscription filter."
        )
      )
    }
  }
}

private struct ProfileSubscriptionRow: View {
  let subscriptionID: SubscriptionDefinition.ID
  @Bindable var store: ServerListStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: $store[subscriptionEnabled: subscriptionID]) {
        Text(
          "Enabled",
          bundle: #bundle,
          comment: "Toggle enabling an MQTT subscription filter."
        )
      }
      TextField(text: $store[subscriptionFilter: subscriptionID]) {
        Text(
          "Topic Filter",
          bundle: #bundle,
          comment: "Label for an MQTT subscription topic filter."
        )
      }
      .autocorrectionDisabled()

      HStack {
        Picker(selection: $store[subscriptionQoS: subscriptionID]) {
          Text(verbatim: "0").tag(
            JollysMQTTCore.MQTTQualityOfService.atMostOnce
          )
          Text(verbatim: "1").tag(
            JollysMQTTCore.MQTTQualityOfService.atLeastOnce
          )
          Text(verbatim: "2").tag(
            JollysMQTTCore.MQTTQualityOfService.exactlyOnce
          )
        } label: {
          Text(
            "QoS",
            bundle: #bundle,
            comment: "Label for MQTT requested quality of service."
          )
        }

        Spacer()

        Button(role: .destructive) {
          store.sendImmediately(.removeSubscription(subscriptionID))
        } label: {
          Label {
            Text(
              "Remove",
              bundle: #bundle,
              comment: "Action that removes an MQTT subscription filter."
            )
          } icon: {
            Image(systemName: "minus.circle")
          }
        }
        .accessibilityHint(
          Text(
            "Removes this topic filter from the profile.",
            bundle: #bundle,
            comment: "Accessibility hint for removing a subscription filter."
          )
        )
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }
}

private struct ProfileValidationSection: View {
  let issues: [BrokerProfileValidationIssue]

  var body: some View {
    if !issues.isEmpty {
      Section {
        ForEach(issues, id: \.self) { issue in
          Label {
            ProfileValidationIssueText(issue: issue)
          } icon: {
            Image(systemName: "exclamationmark.circle")
          }
          .foregroundStyle(.red)
        }
      } header: {
        Text(
          "Fix Before Saving",
          bundle: #bundle,
          comment: "Header for broker profile validation errors."
        )
      }
    }
  }
}

private struct ProfileValidationIssueText: View {
  let issue: BrokerProfileValidationIssue

  var body: some View {
    VStack(alignment: .leading) {
      switch issue.field {
      case .name:
        Text(
          "Enter a profile name.",
          bundle: #bundle,
          comment: "Validation error for a missing broker profile name."
        )
      case .host:
        Text(
          "Enter a valid broker host.",
          bundle: #bundle,
          comment: "Validation error for an invalid broker host."
        )
      case .port:
        Text(
          "Enter a port from 1 through 65535.",
          bundle: #bundle,
          comment: "Validation error for an invalid broker port."
        )
      case .username:
        Text(
          "Enter a valid username.",
          bundle: #bundle,
          comment: "Validation error for an invalid MQTT username."
        )
      case .clientID:
        Text(
          "Enter a valid client ID.",
          bundle: #bundle,
          comment: "Validation error for an invalid MQTT client identifier."
        )
      case .session:
        Text(
          "Persistent sessions require a stable client ID.",
          bundle: #bundle,
          comment: "Validation error for incompatible MQTT session settings."
        )
      case .keepAlive:
        Text(
          "Enter a valid keepalive interval.",
          bundle: #bundle,
          comment: "Validation error for MQTT keepalive."
        )
      case .reconnect:
        Text(
          "The reconnect delays are incompatible.",
          bundle: #bundle,
          comment: "Validation error for reconnect delay settings."
        )
      case .subscriptions:
        Text(
          "Enable at least one unique, valid subscription filter.",
          bundle: #bundle,
          comment: "Validation error for MQTT subscriptions."
        )
      }
    }
  }
}

public enum ApplicationModule: Sendable {
  public static let name = "JollysMQTT"
  public static let dependencies = [
    CoreModule.name,
    TransportModule.name,
    StorageModule.name,
  ]
}
