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
  @State private var helpPresented = false

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
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Button {
            helpPresented = true
          } label: {
            Label {
              Text(
                "Help",
                bundle: #bundle,
                comment: "Opens JollysMQTT onboarding and operational help."
              )
            } icon: {
              Image(systemName: "questionmark.circle")
            }
          }
          .keyboardShortcut("/", modifiers: [.command, .shift])
          .accessibilityIdentifier("help.open")
          .accessibilityHint(
            Text(
              "Explains subscriptions, retained delivery, suspension, credentials, overload, history coverage, and profile sync.",
              bundle: #bundle,
              comment: "Accessibility hint for the application help button."
            )
          )
        }
      }
      .sheet(isPresented: $helpPresented) {
        JollysMQTTHelpView()
      }
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
    #if os(macOS)
      MacConnectedWorkspaceView(
        profileName: profileName,
        snapshot: snapshot,
        topicState: topicState,
        generationWarning: generationWarning,
        sceneStore: sceneStore,
        onRetry: onRetry,
        onCancel: onCancel,
        onApplyLater: onApplyLater,
        onReconnectAll: onReconnectAll,
        onShowBrokers: onShowBrokers
      )
    #else
      TouchConnectedWorkspaceView(
        profileName: profileName,
        selectedTopic: selectedTopic,
        snapshot: snapshot,
        topicState: topicState,
        generationWarning: generationWarning,
        sceneStore: sceneStore,
        onRetry: onRetry,
        onCancel: onCancel,
        onApplyLater: onApplyLater,
        onReconnectAll: onReconnectAll,
        onShowBrokers: onShowBrokers
      )
    #endif
  }
}

#if os(macOS)
  private struct MacConnectedWorkspaceView: View {
    let profileName: String?
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
      SelectedPayloadWorkspace(
        topicState: topicState,
        sceneStore: sceneStore,
        inspectorStore: sceneStore.payloadInspector,
        historyStore: sceneStore.history,
        publishStore: sceneStore.publishComposer
      )
      .safeAreaInset(edge: .top, spacing: 0) {
        MacWorkspaceBanners(
          snapshot: snapshot,
          generationWarning: generationWarning,
          historyIsHealthy: topicState.snapshot.historyIsHealthy,
          unpersistedMessageCount:
            topicState.snapshot.unpersistedMessageCount,
          onApplyLater: onApplyLater,
          onReconnectAll: onReconnectAll,
          onRetryHistory: {
            Task {
              await sceneStore.retryHistoryPersistence()
            }
          }
        )
      }
      .toolbar {
        ToolbarItem(placement: .automatic) {
          MacBrokerToolbarLabel(profileName: profileName)
        }
        ToolbarItem(placement: .automatic) {
          MacConnectionToolbarLabel(snapshot: snapshot)
        }
        ToolbarItemGroup(placement: .primaryAction) {
          if snapshot.lastFailure != nil || snapshot.phase == .idle {
            Button(action: onRetry) {
              Label {
                Text(
                  "Retry",
                  bundle: #bundle,
                  comment: "Retries a broker connection after a failure or cancellation."
                )
              } icon: {
                Image(systemName: "arrow.clockwise")
              }
            }
          }
          if snapshot.phase.isConnectionWorkActive {
            Button(role: .cancel, action: onCancel) {
              Label {
                Text(
                  "Disconnect",
                  bundle: #bundle,
                  comment: "Disconnects the current broker workspace."
                )
              } icon: {
                Image(systemName: "stop.circle")
              }
            }
          }
          Button(action: onShowBrokers) {
            Label {
              Text(
                "Brokers",
                bundle: #bundle,
                comment: "Returns a connected workspace to the broker list."
              )
            } icon: {
              Image(systemName: "server.rack")
            }
          }
        }
      }
    }
  }

  private struct MacBrokerToolbarLabel: View {
    let profileName: String?

    var body: some View {
      Label {
        if let profileName {
          Text(verbatim: profileName)
            .lineLimit(1)
        } else {
          Text(
            "Broker Unavailable",
            bundle: #bundle,
            comment: "Toolbar title when the connected workspace broker profile is unavailable."
          )
        }
      } icon: {
        Image(systemName: "network")
      }
      .help(
        Text(
          "Current broker",
          bundle: #bundle,
          comment: "Help text for the current-broker toolbar item."
        )
      )
    }
  }

  private struct MacConnectionToolbarLabel: View {
    let snapshot: BrokerFeedSnapshot

    var body: some View {
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
      .foregroundStyle(
        snapshot.lastFailure == nil ? Color.secondary : Color.red
      )
      .accessibilityLabel(snapshot.phase.localizedTitle)
    }
  }

  private struct MacWorkspaceBanners: View {
    let snapshot: BrokerFeedSnapshot
    let generationWarning: BrokerFeedGenerationWarning?
    let historyIsHealthy: Bool
    let unpersistedMessageCount: Int
    let onApplyLater: () -> Void
    let onReconnectAll: () -> Void
    let onRetryHistory: () -> Void

    var body: some View {
      VStack(spacing: 0) {
        if let generationWarning {
          BrokerGenerationWarningView(
            warning: generationWarning,
            onApplyLater: onApplyLater,
            onReconnectAll: onReconnectAll
          )
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          Divider()
        }
        if snapshot.lastFailure != nil || snapshot.retry != nil {
          MacConnectionIssueBanner(snapshot: snapshot)
          Divider()
        }
        if !historyIsHealthy {
          HistoryDegradedView(
            unpersistedMessageCount: unpersistedMessageCount,
            onRetry: onRetryHistory,
            isCompact: true
          )
          Divider()
        }
      }
      .background(.bar)
    }
  }

  private struct MacConnectionIssueBanner: View {
    let snapshot: BrokerFeedSnapshot

    var body: some View {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.red)
        if let failure = snapshot.lastFailure {
          Text(failure.localizedDescription)
            .lineLimit(2)
        }
        if let retryAt = snapshot.retry?.retryAt {
          Text(
            "Next retry \(retryAt, style: .relative)",
            bundle: #bundle,
            comment: "Relative time until the next automatic broker reconnect."
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .combine)
    }
  }
#endif

private struct TouchConnectedWorkspaceView: View {
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
      SelectedPayloadWorkspace(
        topicState: topicState,
        sceneStore: sceneStore,
        inspectorStore: sceneStore.payloadInspector,
        historyStore: sceneStore.history,
        publishStore: sceneStore.publishComposer
      )
      if topicState.snapshot.historyIsHealthy == false {
        HistoryDegradedView(
          unpersistedMessageCount:
            topicState.snapshot.unpersistedMessageCount,
          onRetry: {
            Task {
              await sceneStore.retryHistoryPersistence()
            }
          },
          isCompact: false
        )
      }
    }
    .padding(20)
  }
}

private struct HistoryDegradedView: View {
  let unpersistedMessageCount: Int
  let onRetry: () -> Void
  let isCompact: Bool

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        warning
        Spacer()
        retryButton
      }
      VStack(alignment: .leading, spacing: 8) {
        warning
        retryButton
      }
    }
    .font(isCompact ? .callout : .body)
    .foregroundStyle(.secondary)
    .padding(.horizontal, isCompact ? 12 : 0)
    .padding(.vertical, isCompact ? 8 : 0)
    .accessibilityElement(children: .contain)
  }

  private var warning: some View {
    Label {
      Text(
        "History is degraded. Live topics are still updating, but \(unpersistedMessageCount) messages are not covered by durable history.",
        bundle: #bundle,
        comment:
          "Warns that durable history failed while live MQTT ingestion continues. The variable is the number of messages known not to be persisted."
      )
    } icon: {
      Image(systemName: "externaldrive.badge.exclamationmark")
    }
  }

  private var retryButton: some View {
    Button(action: onRetry) {
      Text(
        "Retry History",
        bundle: #bundle,
        comment: "Attempts to resume durable MQTT history persistence."
      )
    }
    .buttonStyle(.borderedProminent)
  }
}

private struct SelectedPayloadWorkspace: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let topicState: TopicOutlineFeature.State
  @Bindable var sceneStore: WorkspaceSceneStore
  @Bindable var inspectorStore: PayloadInspectorStore
  @Bindable var historyStore: HistoryStore
  @Bindable var publishStore: PublishStore

  var body: some View {
    switch AdaptiveWorkspacePresentation.resolve(
      widthClass: resolvedWidthClass
    ) {
    case .compactTabs:
      PayloadCompactWorkspace(
        topicState: topicState,
        sceneStore: sceneStore,
        inspectorStore: inspectorStore,
        historyStore: historyStore,
        publishStore: publishStore
      )
    case .wideSplit:
      PayloadWideWorkspace(
        topicState: topicState,
        sceneStore: sceneStore,
        inspectorStore: inspectorStore,
        historyStore: historyStore,
        publishStore: publishStore
      )
    }
  }

  private var resolvedWidthClass: WorkspaceWidthClass {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains(
        "--ui-testing-connected"
      ),
        let rawValue = ProcessInfo.processInfo.environment[
          "JOLLYSMQTT_UI_WIDTH_CLASS"
        ]
      {
        return rawValue == "compact" ? .compact : .regular
      }
    #endif
    return horizontalSizeClass == .compact ? .compact : .regular
  }
}

private struct PayloadCompactWorkspace: View {
  let topicState: TopicOutlineFeature.State
  @Bindable var sceneStore: WorkspaceSceneStore
  @Bindable var inspectorStore: PayloadInspectorStore
  @Bindable var historyStore: HistoryStore
  @Bindable var publishStore: PublishStore

  var body: some View {
    TabView(
      selection: Binding(
        get: { sceneStore.destination },
        set: { sceneStore.destination = $0 }
      )
    ) {
      TopicExplorerView(
        state: topicState,
        sceneStore: sceneStore
      )
      .tabItem {
        Label {
          Text(
            "Topics",
            bundle: #bundle,
            comment: "Compact connected-workspace topic destination."
          )
        } icon: {
          Image(systemName: "list.bullet.indent")
        }
      }
      .tag(WorkspaceDestination.topics)

      PayloadInspectorPane(
        store: inspectorStore,
        historyStore: historyStore,
        historyMaintenanceStore: sceneStore.historyMaintenance,
        retainedDeletionStore: sceneStore.retainedDeletion,
        numericChartDashboard: sceneStore.numericChartDashboard,
        onPinNumericChart: sceneStore.pinNumericChart,
        layout: .compact
      )
      .tabItem {
        Label {
          Text(
            "Details",
            bundle: #bundle,
            comment: "Compact connected-workspace payload-details destination."
          )
        } icon: {
          Image(systemName: "doc.text.magnifyingglass")
        }
      }
      .tag(WorkspaceDestination.details)

      PublishComposerView(store: publishStore)
        .tabItem {
          Label {
            Text(
              "Publish",
              bundle: #bundle,
              comment: "Compact connected-workspace publish destination."
            )
          } icon: {
            Image(systemName: "paperplane")
          }
        }
        .tag(WorkspaceDestination.publish)

      ScrollView {
        NumericChartDashboardView(
          dashboard: sceneStore.numericChartDashboard,
          layout: .compact
        )
        .padding(1)
      }
      .tabItem {
        Label {
          Text(
            "Charts",
            bundle: #bundle,
            comment: "Compact connected-workspace numeric-charts destination."
          )
        } icon: {
          Image(systemName: "chart.xyaxis.line")
        }
      }
      .tag(WorkspaceDestination.charts)
    }
    .accessibilityIdentifier("workspace.compact.tabs")
  }
}

private struct PayloadWideWorkspace: View {
  let topicState: TopicOutlineFeature.State
  @Bindable var sceneStore: WorkspaceSceneStore
  @Bindable var inspectorStore: PayloadInspectorStore
  @Bindable var historyStore: HistoryStore
  @Bindable var publishStore: PublishStore

  var body: some View {
    NavigationSplitView {
      TopicExplorerView(
        state: topicState,
        sceneStore: sceneStore
      )
      .navigationTitle(
        Text(
          "Topics",
          bundle: #bundle,
          comment: "Wide connected-workspace topic-column title."
        )
      )
      .modifier(TopicColumnWidth())
    } detail: {
      TabView(
        selection: Binding(
          get: {
            sceneStore.destination == .topics
              ? WorkspaceDestination.details
              : sceneStore.destination
          },
          set: { sceneStore.destination = $0 }
        )
      ) {
        PayloadInspectorPane(
          store: inspectorStore,
          historyStore: historyStore,
          historyMaintenanceStore: sceneStore.historyMaintenance,
          retainedDeletionStore: sceneStore.retainedDeletion,
          numericChartDashboard: sceneStore.numericChartDashboard,
          onPinNumericChart: sceneStore.pinNumericChart,
          layout: .wide
        )
        .tabItem {
          Label {
            Text(
              "Details",
              bundle: #bundle,
              comment: "Wide connected-workspace payload-details destination."
            )
          } icon: {
            Image(systemName: "doc.text.magnifyingglass")
          }
        }
        .tag(WorkspaceDestination.details)

        PublishComposerView(store: publishStore)
          .tabItem {
            Label {
              Text(
                "Publish",
                bundle: #bundle,
                comment: "Wide connected-workspace publish destination."
              )
            } icon: {
              Image(systemName: "paperplane")
            }
          }
          .tag(WorkspaceDestination.publish)

        ScrollView {
          NumericChartDashboardView(
            dashboard: sceneStore.numericChartDashboard,
            layout: .wide
          )
          .padding(1)
        }
        .tabItem {
          Label {
            Text(
              "Charts",
              bundle: #bundle,
              comment: "Wide connected-workspace numeric-charts destination."
            )
          } icon: {
            Image(systemName: "chart.xyaxis.line")
          }
        }
        .tag(WorkspaceDestination.charts)
      }
    }
    .accessibilityIdentifier("workspace.wide.split")
  }
}

private struct PublishComposerView: View {
  @Bindable var store: PublishStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(
          "Publish",
          bundle: #bundle,
          comment: "Heading for the MQTT publish composer."
        )
        .font(.headline)

        PublishTopicField(store: store)
        PublishPayloadEditor(store: store)
        PublishDeliveryControls(store: store)
        PublishPrimaryAction(store: store)

        if !store.state.history.entries.isEmpty {
          PublishDraftHistoryMenu(store: store)
        }
        if store.state.status != .idle {
          PublishStatusView(status: store.state.status)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct PublishTopicField: View {
  @Bindable var store: PublishStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        text: Binding(
          get: { store.state.draft.topic },
          set: { store.send(.editTopic($0)) }
        ),
        prompt: Text(
          "factory/line/status",
          bundle: #bundle,
          comment: "Example MQTT publication topic in the composer."
        )
      ) {
        Text(
          "Topic",
          bundle: #bundle,
          comment: "Label for the exact MQTT publication topic."
        )
      }
      .textFieldStyle(.roundedBorder)
      .autocorrectionDisabled()
      .accessibilityIdentifier("publish.topic")
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif

      if store.state.topicWasManuallyEdited,
        store.state.selectedTopic != nil
      {
        Button {
          store.send(.followSelectedTopic)
        } label: {
          Text(
            "Use Selected Topic",
            bundle: #bundle,
            comment: "Re-enables publish-topic prefill from outline selection."
          )
        }
        .buttonStyle(.bordered)
      }
    }
  }
}

private struct PublishPayloadEditor: View {
  @Bindable var store: PublishStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(
        selection: Binding(
          get: { store.state.draft.inputMode },
          set: { store.send(.setInputMode($0)) }
        )
      ) {
        Text(
          "Text",
          bundle: #bundle,
          comment: "Publish composer UTF-8 text input mode."
        )
        .tag(PublishInputMode.text)
        Text(
          "JSON",
          bundle: #bundle,
          comment: "Publish composer JSON input mode."
        )
        .tag(PublishInputMode.json)
        Text(
          "Hex",
          bundle: #bundle,
          comment: "Publish composer hexadecimal byte input mode."
        )
        .tag(PublishInputMode.hex)
      } label: {
        Text(
          "Input Mode",
          bundle: #bundle,
          comment: "Label for choosing how publish payload input is decoded."
        )
      }
      .pickerStyle(.segmented)

      TextEditor(
        text: Binding(
          get: { store.state.draft.payloadSource },
          set: { store.send(.editPayload($0)) }
        )
      )
      .font(.body.monospaced())
      .frame(minHeight: 160)
      .padding(8)
      .background(.quaternary, in: .rect(cornerRadius: 8))
      .accessibilityLabel(
        Text(
          "Payload",
          bundle: #bundle,
          comment: "Accessible label for the MQTT publish payload editor."
        )
      )
      .accessibilityIdentifier("publish.payload")

      if store.state.draft.inputMode == .json {
        Button {
          store.send(.formatJSON)
        } label: {
          Text(
            "Validate and Format JSON",
            bundle: #bundle,
            comment: "Validates and pretty-prints JSON in the publish composer."
          )
        }
        .buttonStyle(.bordered)
      }
    }
  }
}

private struct PublishDeliveryControls: View {
  @Bindable var store: PublishStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(
        selection: Binding(
          get: { store.state.draft.qos },
          set: { store.send(.setQoS($0)) }
        )
      ) {
        ForEach(
          JollysMQTTCore.MQTTQualityOfService.allCases,
          id: \.rawValue
        ) { qos in
          Text(
            "QoS \(qos.rawValue)",
            bundle: #bundle,
            comment: "MQTT publication quality of service option."
          )
          .tag(qos)
        }
      } label: {
        Text(
          "Quality of Service",
          bundle: #bundle,
          comment: "Label for the MQTT publish QoS picker."
        )
      }
      .pickerStyle(.segmented)

      Toggle(
        isOn: Binding(
          get: { store.state.draft.retain },
          set: { store.send(.setRetain($0)) }
        )
      ) {
        Text(
          "Retain",
          bundle: #bundle,
          comment: "Requests broker retention for the MQTT publication."
        )
      }
    }
  }
}

private struct PublishPrimaryAction: View {
  @Bindable var store: PublishStore

  var body: some View {
    Button {
      store.publish()
    } label: {
      if store.state.isPublishing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(
            "Publishing",
            bundle: #bundle,
            comment: "Publish button label while awaiting transport completion."
          )
        }
      } else {
        Text(
          "Publish",
          bundle: #bundle,
          comment: "Sends the composed MQTT publication."
        )
      }
    }
    .buttonStyle(.borderedProminent)
    .keyboardShortcut(.return, modifiers: .command)
    .disabled(store.state.isPublishing)
    .accessibilityIdentifier("publish.send")
    .accessibilityHint(
      Text(
        "Command-Return",
        bundle: #bundle,
        comment: "Keyboard shortcut hint for publishing the current draft."
      )
    )
  }
}

private struct PublishDraftHistoryMenu: View {
  @Bindable var store: PublishStore

  var body: some View {
    Menu {
      ForEach(store.state.history.entries) { entry in
        Button {
          store.send(.restoreHistory(entry.id))
        } label: {
          Text(verbatim: entry.draft.historyLabel)
        }
      }
    } label: {
      Label {
        Text(
          "Successful Drafts",
          bundle: #bundle,
          comment: "Opens bounded history of successfully published drafts."
        )
      } icon: {
        Image(systemName: "clock.arrow.circlepath")
      }
    }
  }
}

private struct PublishStatusView: View {
  let status: PublishStatus

  var body: some View {
    Label {
      Text(status.localizedDescription)
    } icon: {
      Image(systemName: status.systemImage)
    }
    .font(.caption)
    .foregroundStyle(status.isFailure ? Color.red : Color.secondary)
    .accessibilityElement(children: .combine)
  }
}

private struct PayloadInspectorPane: View {
  @Bindable var store: PayloadInspectorStore
  @Bindable var historyStore: HistoryStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore
  @Bindable var retainedDeletionStore: RetainedDeletionStore
  @Bindable var numericChartDashboard: NumericChartDashboardStore
  let onPinNumericChart: (NumericChartSeries) -> Void
  let layout: PayloadInspectorLayout

  var body: some View {
    Group {
      if let inspection = store.state.inspection {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            PayloadMetadataHeader(message: inspection.message)
            PayloadPrimaryActions(
              copyStore: store,
              retainedDeletionStore: retainedDeletionStore
            )
            NumericChartPinControls(
              inspection: inspection,
              selectedJSONPointer: store.state.selectedJSONPointer,
              pinnedSeries:
                numericChartDashboard.state.cards.map(\.chart.series),
              isAtCapacity:
                numericChartDashboard.state.cards.count
                >= numericChartDashboard.maximumCardCount,
              onPin: onPinNumericChart
            )
            PayloadPresentationView(
              inspection: inspection,
              jsonMode: store.state.jsonMode,
              selectedJSONPointer:
                store.state.selectedJSONPointer,
              store: store
            )
            if let outcome = store.state.copyOutcome {
              PayloadCopyOutcomeView(outcome: outcome)
            }
            Divider()
            HistoryBrowserView(
              store: historyStore,
              maintenanceStore: historyMaintenanceStore
            )
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
        }
      } else if store.state.isInspecting {
        ProgressView {
          Text(
            "Inspecting Payload",
            bundle: #bundle,
            comment: "Progress label while the selected MQTT payload is parsed."
          )
        }
        .frame(maxWidth: .infinity, minHeight: 240)
      } else {
        PayloadUnavailableView(reason: store.state.unavailableReason)
          .frame(maxWidth: .infinity, minHeight: 240)
      }
    }
    .task(id: layout) {
      store.send(.setLayout(layout))
    }
    .accessibilityElement(children: .contain)
  }
}

private struct PayloadUnavailableView: View {
  let reason: PayloadUnavailableReason?

  var body: some View {
    ContentUnavailableView {
      Label {
        switch reason {
        case .stale:
          Text(
            "No Current Payload",
            bundle: #bundle,
            comment: "Inspector title for a stale cached topic."
          )
        case .noCurrentValue:
          Text(
            "Topic Has No Value",
            bundle: #bundle,
            comment: "Inspector title for a branch without a current payload."
          )
        case .noSelection, .none:
          Text(
            "Select a Topic",
            bundle: #bundle,
            comment: "Inspector title when no MQTT topic is selected."
          )
        }
      } icon: {
        Image(systemName: "doc.text.magnifyingglass")
      }
    } description: {
      if reason == .stale {
        Text(
          "This cached topic has not been observed in the current connection. Its old payload is not shown as current.",
          bundle: #bundle,
          comment: "Explains why a stale cached MQTT payload is suppressed."
        )
      }
    }
  }
}

private struct PayloadMetadataHeader: View {
  let message: PayloadMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: message.topicID.fullTopic)
        .font(.headline)
        .textSelection(.enabled)
        .accessibilityLabel(
          Text(
            "Topic \(message.topicID.fullTopic)",
            bundle: #bundle,
            comment: "Accessible exact MQTT topic in the payload inspector."
          )
        )
      ViewThatFits {
        HStack(spacing: 12) {
          metadataItems
        }
        VStack(alignment: .leading, spacing: 8) {
          metadataItems
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var metadataItems: some View {
    Label {
      Text(
        receivedDate,
        format: .dateTime
          .year().month().day()
          .hour().minute().second()
      )
    } icon: {
      Image(systemName: "clock")
    }
    .accessibilityLabel(
      Text(
        "Received locally \(receivedDate.formatted(date: .complete, time: .complete))",
        bundle: #bundle,
        comment: "Accessible local receive time for an MQTT payload."
      )
    )
    Text(
      "QoS \(message.qos.rawValue)",
      bundle: #bundle,
      comment: "MQTT quality-of-service metadata. The variable is 0, 1, or 2."
    )
    if message.retained {
      Text(
        "Retained delivery: Yes",
        bundle: #bundle,
        comment:
          "Packet metadata saying the MQTT publish carried the retained-delivery flag; this does not claim current broker state."
      )
    } else {
      Text(
        "Retained delivery: No",
        bundle: #bundle,
        comment:
          "Packet metadata saying the MQTT publish did not carry the retained-delivery flag; this does not claim current broker state."
      )
    }
    Text(
      message.direction == .received
        ? LocalizedStringResource(
          "Received",
          bundle: #bundle,
          comment: "Direction of an incoming MQTT publish."
        )
        : LocalizedStringResource(
          "Published",
          bundle: #bundle,
          comment: "Direction of an outgoing MQTT publish."
        )
    )
    Text(
      "\(message.payloadByteCount) bytes",
      bundle: #bundle,
      comment: "Exact MQTT payload size in bytes."
    )
  }

  private var receivedDate: Date {
    Date(
      timeIntervalSince1970:
        Double(message.receivedAtMicroseconds) / 1_000_000
    )
  }
}

private struct PayloadCopyControls: View {
  @Bindable var store: PayloadInspectorStore

  var body: some View {
    Menu {
      controls
    } label: {
      Label {
        Text(
          "Copy",
          bundle: #bundle,
          comment: "Menu containing payload and topic copy commands."
        )
      } icon: {
        Image(systemName: "doc.on.doc")
      }
    }
    .menuStyle(.button)
    .fixedSize()
  }

  @ViewBuilder
  private var controls: some View {
    PayloadCopyButton(
      title: LocalizedStringResource(
        "Copy Topic",
        bundle: #bundle,
        comment: "Copies the exact selected MQTT topic."
      ),
      action: .topic,
      isEnabled: store.state.canCopy(.topic),
      store: store
    )
    .keyboardShortcut("c", modifiers: [.command, .shift])
    PayloadCopyButton(
      title: LocalizedStringResource(
        "Copy Raw Bytes",
        bundle: #bundle,
        comment: "Copies the exact selected MQTT payload bytes."
      ),
      action: .rawBytes,
      isEnabled: store.state.canCopy(.rawBytes),
      store: store
    )
    PayloadCopyButton(
      title: LocalizedStringResource(
        "Copy Display Text",
        bundle: #bundle,
        comment: "Copies the complete selected payload text."
      ),
      action: .displayText,
      isEnabled: store.state.canCopy(.displayText),
      store: store
    )
    if store.state.canCopy(.formattedJSON) {
      PayloadCopyButton(
        title: LocalizedStringResource(
          "Copy Formatted JSON",
          bundle: #bundle,
          comment: "Copies the complete formatted JSON document."
        ),
        action: .formattedJSON,
        isEnabled: true,
        store: store
      )
    }
    if store.state.canCopy(.selectedJSONValue) {
      PayloadCopyButton(
        title: LocalizedStringResource(
          "Copy Selected JSON Value",
          bundle: #bundle,
          comment: "Copies the selected JSON value or subtree."
        ),
        action: .selectedJSONValue,
        isEnabled: true,
        store: store
      )
    }
  }
}

private struct PayloadPrimaryActions: View {
  @Bindable var copyStore: PayloadInspectorStore
  @Bindable var retainedDeletionStore: RetainedDeletionStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        PayloadCopyControls(store: copyStore)
        RetainedDeletionActionButtons(store: retainedDeletionStore)
      }
      RetainedDeletionFeedback(store: retainedDeletionStore)
    }
  }
}

private struct PayloadCopyButton: View {
  let title: LocalizedStringResource
  let action: PayloadCopyAction
  let isEnabled: Bool
  @Bindable var store: PayloadInspectorStore

  var body: some View {
    Button {
      store.send(.copy(action))
    } label: {
      Text(title)
    }
    .disabled(!isEnabled)
  }
}

private struct PayloadPresentationView: View {
  let inspection: PayloadInspection
  let jsonMode: PayloadInspectorJSONMode
  let selectedJSONPointer: PayloadJSONPointer?
  @Bindable var store: PayloadInspectorStore

  var body: some View {
    switch inspection.presentation {
    case .json(let document):
      PayloadJSONPresentationView(
        document: document,
        mode: jsonMode,
        selectedPointer: selectedJSONPointer,
        store: store
      )
    case .text(let text):
      PayloadTextView(presentation: text)
    case .bytes(let hex):
      PayloadHexView(presentation: hex)
    }
  }
}

private struct PayloadJSONPresentationView: View {
  let document: PayloadJSONDocument
  let mode: PayloadInspectorJSONMode
  let selectedPointer: PayloadJSONPointer?
  @Bindable var store: PayloadInspectorStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(
        selection: Binding(
          get: { mode },
          set: { store.send(.setJSONMode($0)) }
        )
      ) {
        Text(
          "Structure",
          bundle: #bundle,
          comment: "JSON inspector structural presentation mode."
        )
        .tag(PayloadInspectorJSONMode.structure)
        Text(
          "Raw",
          bundle: #bundle,
          comment: "JSON inspector raw source presentation mode."
        )
        .tag(PayloadInspectorJSONMode.raw)
      } label: {
        Text(
          "JSON Presentation",
          bundle: #bundle,
          comment: "Label for choosing structural or raw JSON presentation."
        )
      }
      .pickerStyle(.segmented)

      if mode == .structure {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(document.nodes) { node in
            Button {
              store.send(.selectJSONValue(node.id))
            } label: {
              PayloadJSONNodeRow(
                node: node,
                isSelected: node.id == selectedPointer
              )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              Text(
                "JSON path \(node.pathPreview.isEmpty ? "root" : node.pathPreview)\(node.pathPreviewIsTruncated ? "…" : "")",
                bundle: #bundle,
                comment: "Accessible deterministic JSON path for a structural row."
              )
            )
            .accessibilityValue(Text(verbatim: node.accessibilityValue))
            .accessibilityAddTraits(
              node.id == selectedPointer ? .isSelected : []
            )
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          if !document.rawTextIsOriginalUTF8 {
            Text(
              "Normalized text view of the original non-UTF-8 JSON bytes",
              bundle: #bundle,
              comment: "Clarifies that non-UTF-8 JSON is transcoded for its raw text view."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Text(verbatim: document.rawText)
            .font(.body.monospaced())
            .textSelection(.enabled)
        }
      }
    }
  }
}

private struct PayloadJSONNodeRow: View {
  let node: PayloadJSONNode
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: node.label)
        .fontWeight(isSelected ? .semibold : .regular)
      if node.labelIsTruncated {
        Text(verbatim: "…")
          .accessibilityHidden(true)
      }
      if let displayValue = node.displayValue {
        Text(verbatim: displayValue)
          .foregroundStyle(.secondary)
        if node.displayValueIsTruncated {
          Text(verbatim: "…")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      } else {
        Text(verbatim: node.kind.containerSummary(count: node.childCount))
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.leading, CGFloat(min(node.depth, 12)) * indentation)
    .padding(.vertical, 4)
    .frame(minHeight: minimumRowHeight)
    .contentShape(.rect)
  }

  private var indentation: CGFloat {
    #if os(macOS)
      12
    #else
      16
    #endif
  }

  private var minimumRowHeight: CGFloat {
    #if os(macOS)
      24
    #else
      44
    #endif
  }
}

private struct PayloadTextView: View {
  let presentation: PayloadTextPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: presentation.text)
        .font(.body.monospaced())
        .textSelection(.enabled)
      if presentation.isPreviewTruncated {
        Group {
          if presentation.completeText != nil {
            Text(
              "Preview truncated. Copy Display Text copies the complete payload.",
              bundle: #bundle,
              comment: "Explains bounded text preview and complete copy semantics."
            )
          } else {
            Text(
              "Preview truncated at the bounded inspection limit. Use Copy Raw Bytes for the complete payload.",
              bundle: #bundle,
              comment:
                "Explains that oversized selected text is preview-only and exact bytes remain copyable."
            )
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if let notice = presentation.notice {
        Text(notice.localizedDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct PayloadHexView: View {
  let presentation: PayloadHexPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: presentation.text)
        .font(.body.monospaced())
        .textSelection(.enabled)
      if presentation.isTruncated {
        Text(
          "Showing \(presentation.presentedByteCount) of \(presentation.totalByteCount) bytes. Copy Raw Bytes copies the complete payload.",
          bundle: #bundle,
          comment:
            "Explains bounded hexadecimal output and complete raw-byte copy semantics."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

private struct PayloadCopyOutcomeView: View {
  let outcome: PayloadCopyOutcome

  var body: some View {
    Label {
      switch outcome {
      case .succeeded:
        Text(
          "Copied",
          bundle: #bundle,
          comment: "Accessible confirmation after a payload copy action."
        )
      case .failed:
        Text(
          "Copy Failed",
          bundle: #bundle,
          comment: "Accessible failure after a payload copy action."
        )
      }
    } icon: {
      Image(
        systemName:
          outcome.isSuccess ? "checkmark.circle" : "exclamationmark.triangle"
      )
    }
    .foregroundStyle(
      outcome.isSuccess ? Color.secondary : Color.red
    )
    .accessibilityElement(children: .combine)
  }
}

extension PayloadJSONNodeKind {
  fileprivate func containerSummary(count: Int) -> String {
    switch self {
    case .object:
      "{\(count)}"
    case .array:
      "[\(count)]"
    case .string, .number, .boolean, .null:
      ""
    }
  }
}

extension PayloadJSONNode {
  fileprivate var accessibilityValue: String {
    let value = displayValue ?? kind.containerSummary(count: childCount)
    return displayValueIsTruncated ? value + "…" : value
  }
}

extension PayloadInspectionNotice {
  fileprivate var localizedDescription: LocalizedStringResource {
    switch self {
    case .jsonByteLimitExceeded(let limit):
      LocalizedStringResource(
        "JSON parsing was skipped because the payload exceeds the \(limit)-byte inspection limit.",
        bundle: #bundle,
        comment:
          "Visible bounded-inspection notice. The variable is the JSON byte limit."
      )
    case .jsonDepthLimitExceeded(let limit):
      LocalizedStringResource(
        "JSON parsing was skipped because nesting exceeds the \(limit)-level inspection limit.",
        bundle: #bundle,
        comment:
          "Visible bounded-inspection notice. The variable is the JSON nesting limit."
      )
    case .jsonNodeLimitExceeded(let limit):
      LocalizedStringResource(
        "JSON parsing was skipped because the document exceeds the \(limit)-node inspection limit.",
        bundle: #bundle,
        comment:
          "Visible bounded-inspection notice. The variable is the JSON node limit."
      )
    }
  }
}

extension PayloadCopyOutcome {
  fileprivate var isSuccess: Bool {
    if case .succeeded = self { return true }
    return false
  }
}

extension PublishDraft {
  var historyLabel: String {
    let topicPreview =
      String(topic.prefix(80))
      + (topic.count > 80 ? "…" : "")
    let compactPayload =
      payloadSource
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    let preview =
      String(compactPayload.prefix(32))
      + (compactPayload.count > 32 ? "…" : "")
    return preview.isEmpty
      ? topicPreview
      : "\(topicPreview) — \(preview)"
  }
}

extension PublishStatus {
  var systemImage: String {
    switch self {
    case .idle:
      "circle"
    case .publishing:
      "clock.arrow.circlepath"
    case .succeeded:
      "checkmark.circle"
    case .rejected:
      "exclamationmark.triangle"
    }
  }

  fileprivate var isFailure: Bool {
    if case .rejected = self { return true }
    return false
  }

  fileprivate var localizedDescription: LocalizedStringResource {
    switch self {
    case .idle:
      LocalizedStringResource(
        "Ready to publish",
        bundle: #bundle,
        comment: "Neutral MQTT publish composer state."
      )
    case .publishing:
      LocalizedStringResource(
        "Waiting for MQTT completion",
        bundle: #bundle,
        comment: "Publish state while transport acceptance or acknowledgement is pending."
      )
    case .succeeded(let success):
      switch success.completion {
      case .transportAccepted:
        LocalizedStringResource(
          "QoS 0 publish accepted by the transport",
          bundle: #bundle,
          comment: "Honest success description for an MQTT QoS 0 publish."
        )
      case .acknowledged:
        LocalizedStringResource(
          "Publish acknowledged by the broker",
          bundle: #bundle,
          comment: "Honest success description for an MQTT QoS 1 or 2 publish."
        )
      }
    case .rejected(let failure):
      failure.localizedDescription
    }
  }
}

extension BrokerPublishFailure {
  fileprivate var localizedDescription: LocalizedStringResource {
    switch self {
    case .invalidDraft(let validation):
      validation.localizedDescription
    case .notConnected:
      LocalizedStringResource(
        "Connect to the broker before publishing.",
        bundle: #bundle,
        comment: "Publish rejection when no connected feed can accept a command."
      )
    case .queueFull:
      LocalizedStringResource(
        "The publish queue is full. Nothing was sent.",
        bundle: #bundle,
        comment: "Synchronous visible rejection before MQTT transport is called."
      )
    case .transportUnavailable:
      LocalizedStringResource(
        "The publish did not complete.",
        bundle: #bundle,
        comment: "Publish failure after the transport could not complete the operation."
      )
    case .cancelled:
      LocalizedStringResource(
        "The publish was cancelled.",
        bundle: #bundle,
        comment: "Publish failure when its connection or owning feed is cancelled."
      )
    case .connectionChanged:
      LocalizedStringResource(
        "The broker connection changed before the publish could be sent.",
        bundle: #bundle,
        comment:
          "Publish failure when a destructive operation belongs to an earlier broker connection."
      )
    }
  }
}

extension PublishDraftValidationError {
  fileprivate var localizedDescription: LocalizedStringResource {
    switch self {
    case .invalidTopic:
      LocalizedStringResource(
        "Enter a valid publication topic without + or # wildcards.",
        bundle: #bundle,
        comment: "Validation error for an invalid MQTT publication topic."
      )
    case .invalidJSON:
      LocalizedStringResource(
        "Enter valid JSON for JSON mode.",
        bundle: #bundle,
        comment: "Validation error for malformed publish JSON."
      )
    case .invalidHex:
      LocalizedStringResource(
        "Enter hexadecimal byte pairs separated only by whitespace.",
        bundle: #bundle,
        comment: "Validation error for malformed hexadecimal publish input."
      )
    case .retainedDeletionRequiresConfirmation:
      LocalizedStringResource(
        "A retained zero-byte publish deletes a retained value and requires confirmation.",
        bundle: #bundle,
        comment: "Blocks an unconfirmed destructive retained-value deletion."
      )
    case .payloadTooLarge(let byteCount, let maximumByteCount):
      LocalizedStringResource(
        "The \(byteCount)-byte payload exceeds the \(maximumByteCount)-byte publish limit.",
        bundle: #bundle,
        comment:
          "Publish payload limit error. The first variable is actual bytes; the second is the maximum."
      )
    }
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
    VStack(spacing: explorerSpacing) {
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
      .padding(explorerControlPadding)
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
            .modifier(TopicOutlineListRowStyle())
          }
        }
        .modifier(TopicOutlineListStyle())
      }
    }
    .frame(minHeight: 320)
  }

  private var explorerSpacing: CGFloat {
    #if os(macOS)
      0
    #else
      8
    #endif
  }

  private var explorerControlPadding: CGFloat {
    #if os(macOS)
      8
    #else
      0
    #endif
  }
}

private struct TopicColumnWidth: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
      content.navigationSplitViewColumnWidth(min: 320, ideal: 480, max: 680)
    #else
      content.navigationSplitViewColumnWidth(min: 280, ideal: 360)
    #endif
  }
}

private struct TopicOutlineListStyle: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
      content.listStyle(.sidebar)
    #else
      content
    #endif
  }
}

private struct TopicOutlineListRowStyle: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
      content.listRowInsets(
        EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
      )
    #else
      content
    #endif
  }
}

private struct RetainedDeletionFeedback: View {
  @Bindable var store: RetainedDeletionStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if store.state.targetEnumerationEmpty {
        Text(
          "No non-stale locally known value-bearing topics are available in the selected scope.",
          bundle: #bundle,
          comment:
            "Explains why a retained deletion request produced no current local targets."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if store.state.reconfirmationUnavailable {
        Text(
          "None of the retryable topics is a current locally known value on this connection.",
          bundle: #bundle,
          comment:
            "Explains why reconnect reconfirmation found no still-current retryable targets."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          Text(
            "No current retryable retained values",
            bundle: #bundle,
            comment:
              "Accessible summary when retained deletion reconfirmation has no current targets."
          )
        )
      }

      if let operation = store.state.operation {
        RetainedDeletionOperationView(
          operation: operation,
          canRetry: store.state.canRetryCurrentAuthorization,
          canReconfirm:
            store.state.canReconfirmRetryableRemainder,
          onCancel: {
            store.send(.cancel)
          },
          onRetry: store.retry,
          onReconfirm: store.reconfirmRetryableRemainder,
          onDismiss: {
            store.send(.dismissReport)
          }
        )
      }
    }
    .confirmationDialog(
      confirmationTitle(store.state.confirmation),
      isPresented: Binding(
        get: { store.state.confirmation != nil },
        set: { presented in
          if !presented {
            store.send(.dismissConfirmation)
          }
        }
      ),
      titleVisibility: .visible,
      presenting: store.state.confirmation
    ) { confirmation in
      Button(role: .destructive) {
        store.confirm()
      } label: {
        confirmationButtonLabel(confirmation)
      }
      .accessibilityLabel(
        confirmationAccessibilityLabel(confirmation)
      )
      .accessibilityHint(
        Text(
          "Publishes zero-byte retained MQTT messages and waits for broker acknowledgements.",
          bundle: #bundle,
          comment:
            "Accessible confirmation hint for acknowledged retained-value deletion."
        )
      )
      Button(role: .cancel) {
        store.send(.dismissConfirmation)
      } label: {
        Text(
          "Cancel",
          bundle: #bundle,
          comment: "Cancels a retained-value deletion confirmation."
        )
      }
    } message: { confirmation in
      confirmationMessage(confirmation)
    }
  }

  private func confirmationTitle(
    _ confirmation: RetainedDeletionConfirmation?
  ) -> Text {
    guard let confirmation else {
      return Text(
        "Delete retained value?",
        bundle: #bundle,
        comment: "Fallback destructive retained-value confirmation title."
      )
    }
    switch confirmation.scope {
    case .single:
      return Text(
        "Delete retained value?",
        bundle: #bundle,
        comment: "Single retained-value destructive confirmation title."
      )
    case .subtree, .retryableRemainder:
      return Text(
        "Delete \(confirmation.topicCount) retained values?",
        bundle: #bundle,
        comment:
          "Recursive retained-value confirmation title. The variable is the exact target count."
      )
    }
  }

  @ViewBuilder
  private func confirmationButtonLabel(
    _ confirmation: RetainedDeletionConfirmation
  ) -> some View {
    switch confirmation.scope {
    case .single:
      Text(
        "Delete retained value",
        bundle: #bundle,
        comment: "Confirms one retained-value deletion."
      )
    case .subtree, .retryableRemainder:
      Text(
        "Delete \(confirmation.topicCount) retained values",
        bundle: #bundle,
        comment:
          "Confirms recursive retained-value deletion. The variable is the exact target count."
      )
    }
  }

  private func confirmationAccessibilityLabel(
    _ confirmation: RetainedDeletionConfirmation
  ) -> Text {
    switch confirmation.accessibilityTarget {
    case .exactTopic(let topic):
      Text(
        "Confirm deleting the retained value for \(topic)",
        bundle: #bundle,
        comment:
          "Accessible destructive confirmation label. The variable is the exact MQTT topic."
      )
    case .exactCount(let count):
      Text(
        "Confirm deleting \(count) retained values",
        bundle: #bundle,
        comment:
          "Accessible recursive destructive confirmation label. The variable is the exact topic count."
      )
    }
  }

  private func confirmationMessage(
    _ confirmation: RetainedDeletionConfirmation
  ) -> Text {
    switch confirmation.scope {
    case .single(let topic):
      Text(
        "This publishes a zero-byte retained message to \(topic). It attempts to clear that broker-retained value; local delivery metadata does not prove the broker currently stores it.",
        bundle: #bundle,
        comment:
          "Explains MQTT semantics before one retained-value deletion. The variable is the exact topic."
      )
    case .subtree:
      Text(
        "This publishes zero-byte retained messages to exactly \(confirmation.topicCount) unique, non-stale, locally known value-bearing topics in the selected subtree. This is not the broker’s complete retained-message inventory.",
        bundle: #bundle,
        comment:
          "Explains recursive retained deletion scope. The variable is the exact snapshotted target count."
      )
    case .retryableRemainder:
      Text(
        "The connection changed. This newly confirms exactly \(confirmation.topicCount) still-current retryable topics on the present connection. This is not the broker’s complete retained-message inventory.",
        bundle: #bundle,
        comment:
          "Explains renewed authorization for retryable retained deletions after reconnect. The variable is the new exact count."
      )
    }
  }
}

private struct RetainedDeletionActionButtons: View {
  @Bindable var store: RetainedDeletionStore

  var body: some View {
    Menu {
      Button(role: .destructive) {
        store.requestSingleDeletion()
      } label: {
        Label {
          Text(
            "Delete retained value",
            bundle: #bundle,
            comment:
              "Destructive action that publishes one zero-byte retained MQTT message after confirmation."
          )
        } icon: {
          Image(systemName: "pin.slash")
        }
      }
      .disabled(
        !store.state.canDeleteSingle
          || store.state.operation?.isActive == true
      )
      .accessibilityHint(
        Text(
          "Requires confirmation, then attempts to clear this topic’s broker-retained value.",
          bundle: #bundle,
          comment:
            "Accessible hint explaining the single retained-value deletion action."
        )
      )

      Button(role: .destructive) {
        store.requestSubtreeDeletion()
      } label: {
        Label {
          Text(
            "Delete retained values in subtree",
            bundle: #bundle,
            comment:
              "Destructive action that targets locally known value topics in the selected subtree."
          )
        } icon: {
          Image(systemName: "point.3.filled.connected.trianglepath.dotted")
        }
      }
      .disabled(
        !store.state.canDeleteSubtree
          || store.state.operation?.isActive == true
      )
      .accessibilityHint(
        Text(
          "Enumerates the current local snapshot and asks you to confirm the exact topic count.",
          bundle: #bundle,
          comment:
            "Accessible hint explaining recursive retained-value target enumeration."
        )
      )
    } label: {
      Label {
        Text(
          "Retained Values",
          bundle: #bundle,
          comment: "Menu containing destructive retained-value actions."
        )
      } icon: {
        Image(systemName: "pin")
      }
    }
    .menuStyle(.button)
    .fixedSize()
  }
}

private struct RetainedDeletionOperationView: View {
  let operation: RetainedDeletionOperation
  let canRetry: Bool
  let canReconfirm: Bool
  let onCancel: () -> Void
  let onRetry: () -> Void
  let onReconfirm: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if operation.isActive {
          Text(
            "\(operation.completedTopicCount) of \(operation.topics.count) completed",
            bundle: #bundle,
            comment:
              "Active retained deletion progress. Variables are completed and total topic counts."
          )
        } else {
          Text(
            "\(operation.completedTopics.count) completed, \(operation.retryableTopics.count) retryable",
            bundle: #bundle,
            comment:
              "Retained deletion result summary. Variables are completed and retryable topic counts."
          )
        }
      }
      .font(.subheadline.weight(.semibold))

      if operation.isActive {
        ProgressView()
          .accessibilityLabel(
            Text(
              "Deleting retained values",
              bundle: #bundle,
              comment: "Progress label for a retained deletion operation."
            )
          )
        if let currentTopic = operation.currentTopic {
          Text(verbatim: currentTopic)
            .font(.caption.monospaced())
            .lineLimit(1)
            .accessibilityLabel(
              Text(
                "Current retained deletion topic \(currentTopic)",
                bundle: #bundle,
                comment:
                  "Accessible label for the MQTT topic whose retained delete is in flight. The variable is the exact topic."
              )
            )
        }
        Button(role: .cancel, action: onCancel) {
          Text(
            "Cancel after current topic",
            bundle: #bundle,
            comment:
              "Stops recursive retained deletion after the current acknowledged publish settles."
          )
        }
        .disabled(operation.phase == .cancelling)
      } else {
        HStack(spacing: 8) {
          if canRetry {
            Button(action: onRetry) {
              Text(
                "Retry remaining topics",
                bundle: #bundle,
                comment:
                  "Retries failed or cancelled retained deletions on the same connection."
              )
            }
          } else if canReconfirm {
            Button(role: .destructive, action: onReconfirm) {
              Text(
                "Reconfirm on current connection",
                bundle: #bundle,
                comment:
                  "Begins a new exact-count confirmation after the broker connection changed."
              )
            }
          }
          Button(action: onDismiss) {
            Text(
              "Dismiss",
              bundle: #bundle,
              comment: "Dismisses a retained deletion result report."
            )
          }
        }
      }

      if !operation.isActive {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(operation.topics) { topic in
              RetainedDeletionTopicResultRow(topic: topic)
            }
          }
        }
        .frame(maxHeight: 160)
      }
    }
    .padding(10)
    .background(.quaternary, in: .rect(cornerRadius: 8))
    .accessibilityElement(children: .contain)
  }
}

private struct RetainedDeletionTopicResultRow: View {
  let topic: RetainedDeletionTopicOperation

  var body: some View {
    Label {
      Text(verbatim: topic.topic)
        .lineLimit(1)
    } icon: {
      Image(systemName: systemImage)
    }
    .font(.caption)
    .foregroundStyle(foregroundStyle)
    .accessibilityElement(children: .combine)
    .accessibilityValue(accessibilityValue)
  }

  private var systemImage: String {
    switch topic.status {
    case .pending:
      "circle"
    case .publishing:
      "clock.arrow.circlepath"
    case .succeeded:
      "checkmark.circle"
    case .failed:
      "exclamationmark.triangle"
    }
  }

  private var foregroundStyle: Color {
    switch topic.status {
    case .failed:
      .red
    default:
      .secondary
    }
  }

  private var accessibilityValue: Text {
    switch topic.status {
    case .pending:
      Text(
        "Retryable",
        bundle: #bundle,
        comment: "Accessible status for a retained deletion not yet attempted."
      )
    case .publishing:
      Text(
        "Waiting for broker acknowledgement",
        bundle: #bundle,
        comment: "Accessible status for an in-flight retained deletion."
      )
    case .succeeded:
      Text(
        "Completed",
        bundle: #bundle,
        comment: "Accessible status for a successfully acknowledged retained deletion."
      )
    case .failed(let failure):
      Text(failure.localizedDescription)
    }
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
          .frame(width: disclosureSize, height: disclosureSize)
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
        Color.clear.frame(width: disclosureSize, height: disclosureSize)
          .accessibilityHidden(true)
      }
      TopicOutlineRowContent(row: row)
    }
    .padding(.leading, CGFloat(min(row.depth, 12)) * indentation)
  }

  private var disclosureSize: CGFloat {
    #if os(macOS)
      20
    #else
      44
    #endif
  }

  private var indentation: CGFloat {
    #if os(macOS)
      12
    #else
      16
    #endif
  }
}

private struct TopicOutlineRowContent: View {
  let row: TopicOutlineRowState

  var body: some View {
    #if os(macOS)
      HStack(spacing: 4) {
        primaryLabel
        summary
        Spacer(minLength: 8)
        descendantCounts
      }
      .controlSize(.small)
      .frame(minHeight: 22)
      .contentShape(.rect)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: row.fullTopic))
      .accessibilityValue(accessibilityValue)
      .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    #else
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
          primaryLabel
          summary
        }
        Spacer()
        descendantCounts
      }
      .contentShape(.rect)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: row.fullTopic))
      .accessibilityValue(accessibilityValue)
      .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    #endif
  }

  private var primaryLabel: some View {
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
      if row.hasValue && !row.isStale {
        TopicActivityIndicator(latestOrdinal: row.latestOrdinal)
      }
      if row.isStale {
        Label {
          Text(
            "Stale",
            bundle: #bundle,
            comment:
              "Marks a cached MQTT topic that has not been observed in the current connection."
          )
        } icon: {
          Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
  }

  @ViewBuilder
  private var summary: some View {
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

  @ViewBuilder
  private var descendantCounts: some View {
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

  private var accessibilityValue: Text {
    if row.isStale {
      return Text(
        "Stale cached topic, not observed in the current connection, \(row.descendantValueTopicCount) descendant topics, \(row.descendantMessageCount) descendant messages",
        bundle: #bundle,
        comment:
          "Accessible stale MQTT topic metadata. Variables are descendant value-topic and message counts."
      )
    } else if let qos = row.qos, let summary = row.payloadSummary {
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
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Bindable var store: ServerListStore
  @Bindable var sceneStore: WorkspaceSceneStore

  var body: some View {
    NavigationSplitView {
      BrokerListSidebar(store: store, presentation: presentation)
    } detail: {
      BrokerListDetail(
        profile: store.state.profiles.first {
          $0.id == store.state.selectedProfileID
        }?.profile,
        credentialAvailability:
          store.state.selectedProfileID.flatMap {
            store.state.credentialStatuses[$0]?.availability
          },
        store: store,
        historyMaintenanceStore: sceneStore.historyMaintenance,
        presentation: presentation
      )
    }
    .navigationTitle(
      Text(
        "JollysMQTT",
        bundle: #bundle,
        comment: "Application title shown in navigation chrome."
      )
    )
    .safeAreaInset(edge: .top) {
      ProfileSyncStatusBanner(
        store: sceneStore.profileSync
      )
    }
    .task {
      await sceneStore.profileSync.run()
    }
    .task(id: store.state.selectedProfileID) {
      guard presentation == .regularEditor,
        store.state.editor == nil,
        let profileID = store.state.selectedProfileID
      else { return }
      await store.send(.editProfileInline(profileID))
    }
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
    .sheet(
      isPresented: Binding(
        get: { sceneStore.historyMaintenance.state.isPresented },
        set: {
          sceneStore.historyMaintenance.send(.setPresented($0))
        }
      )
    ) {
      HistoryMaintenanceView(store: sceneStore.historyMaintenance)
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
        Task {
          await store.send(.confirmDeleteProfileAndHistoryAndCredential)
        }
      } label: {
        Text(
          "Delete Profile, History, and Password",
          bundle: #bundle,
          comment:
            "Destructive action that deletes a broker profile, local history, and device password."
        )
      }
      Button(role: .destructive) {
        Task { await store.send(.confirmDeleteProfileAndHistory) }
      } label: {
        Text(
          "Delete Profile and History",
          bundle: #bundle,
          comment:
            "Destructive action that deletes a broker profile and local history while keeping its device password."
        )
      }
      Button(role: .destructive) {
        Task { await store.send(.confirmDeleteProfileAndCredential) }
      } label: {
        Text(
          "Delete Profile and Password",
          bundle: #bundle,
          comment:
            "Destructive action that deletes a broker profile and its device password while keeping local history."
        )
      }
      Button(role: .destructive) {
        Task { await store.send(.confirmDeleteProfile) }
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
        "Deleting “\(store.pendingDeletionName)” creates a permanent synchronization tombstone. Broker-specific topic, search, and chart state is removed from this workspace; other restored workspaces are scrubbed when they observe the deletion. Choose independently whether to delete local history and the device password. Per-broker retention settings are always removed.",
        bundle: #bundle,
        comment:
          "Deletion warning describing the permanent tombstone, workspace privacy cleanup, independent history/password choices, and retention-settings cleanup. The variable is the broker profile name."
      )
    }
    .alert(
      Text(
        store.state.deletionOutcome?.succeeded == true
          ? LocalizedStringResource(
            "Broker Deleted",
            bundle: #bundle,
            comment: "Title for a completed broker deletion."
          )
          : LocalizedStringResource(
            "Broker Deletion Incomplete",
            bundle: #bundle,
            comment: "Title for a partial cross-resource broker deletion."
          )
      ),
      isPresented: $store.deletionOutcomePresented
    ) {
      if let outcome = store.state.deletionOutcome,
        outcome.profile == .removed,
        !outcome.succeeded
      {
        Button {
          Task { await store.send(.retryDeletionCleanup) }
        } label: {
          Text(
            "Retry Remaining Cleanup",
            bundle: #bundle,
            comment:
              "Retries failed optional resource cleanup after profile deletion committed."
          )
        }
      }
      Button {
      } label: {
        Text(
          "OK",
          bundle: #bundle,
          comment: "Dismisses a broker deletion outcome."
        )
      }
    } message: {
      Text(
        store.state.deletionOutcome?.localizedSummary
          ?? LocalizedStringResource(
            "Broker deletion did not complete.",
            bundle: #bundle,
            comment: "Fallback broker deletion outcome alert message."
          )
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
    .confirmationDialog(
      Text(
        "Unsaved Broker Changes",
        bundle: #bundle,
        comment: "Title shown before navigation would leave an unsaved broker draft."
      ),
      isPresented: $store.pendingDraftDecisionPresented,
      titleVisibility: .visible
    ) {
      Button {
        Task { await store.send(.savePendingDraft) }
      } label: {
        Text(
          "Save Changes",
          bundle: #bundle,
          comment: "Saves a broker draft before continuing the requested action."
        )
      }
      Button(role: .destructive) {
        Task { await store.send(.discardPendingDraft) }
      } label: {
        Text(
          "Discard Changes",
          bundle: #bundle,
          comment: "Discards a broker draft before continuing the requested action."
        )
      }
      Button(role: .cancel) {
        store.sendImmediately(.continueEditingDraft)
      } label: {
        Text(
          "Continue Editing",
          bundle: #bundle,
          comment: "Keeps the current broker draft and cancels navigation."
        )
      }
    } message: {
      Text(
        store.state.pendingDraftDestination?.requiresSavedProfile == true
          ? LocalizedStringResource(
            "Save this draft before connecting, or discard it to connect with the stored profile.",
            bundle: #bundle,
            comment: "Explains that connecting never uses an unsaved broker draft."
          )
          : LocalizedStringResource(
            "Save or discard this draft before changing brokers.",
            bundle: #bundle,
            comment: "Explains that changing broker selection never silently discards a draft."
          )
      )
    }
  }

  private var presentation: BrokerListPresentation {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--ui-testing-broker-list"),
        let rawValue = ProcessInfo.processInfo.environment[
          "JOLLYSMQTT_UI_WIDTH_CLASS"
        ]
      {
        return rawValue == "compact" ? .compactSummary : .regularEditor
      }
    #endif
    return BrokerListPresentation.resolve(
      widthClass: horizontalSizeClass == .compact ? .compact : .regular
    )
  }
}

extension PendingProfileDraftDestination {
  fileprivate var requiresSavedProfile: Bool {
    if case .connection = self { true } else { false }
  }
}

private struct ProfileSyncStatusBanner: View {
  @Bindable var store: ProfileSyncControlStore

  var body: some View {
    switch store.status {
    case .localOnly, .available:
      EmptyView()
    case .cloudSyncDisabled:
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "iCloud profile sync is off on this device. Broker profiles remain stored locally.",
          bundle: #bundle,
          comment:
            "Explains the durable, device-local CloudKit opt-out."
        )
        Button {
          Task { await store.enableCloudSync() }
        } label: {
          Text(
            "Enable iCloud Profile Sync",
            bundle: #bundle,
            comment:
              "Explicitly re-enables CloudKit profile synchronization on this device."
          )
        }
        .disabled(store.isWorking)
      }
      .profileSyncBannerStyle()
    case .cloudSyncPreferenceSaveFailed:
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "Cloud sync is off for this session, but the device-only choice could not be saved. Retry before closing the app.",
          bundle: #bundle,
          comment:
            "Warns that the fail-safe CloudKit opt-out is active but could not be persisted."
        )
        Button {
          Task { await store.keepLocalOnly() }
        } label: {
          Text(
            "Retry Saving Device-Only Choice",
            bundle: #bundle,
            comment:
              "Retries persistence of the device-local CloudKit opt-out."
          )
        }
        .disabled(store.isWorking)
      }
      .profileSyncBannerStyle()
    case .syncing:
      HStack(spacing: 8) {
        ProgressView()
        Text(
          "Syncing broker profiles with iCloud…",
          bundle: #bundle,
          comment: "Progress shown while CloudKit profile sync is active."
        )
      }
      .profileSyncBannerStyle()
    case .retryScheduled(let failure):
      ProfileSyncChoiceBanner(
        message: retryMessage(for: failure),
        primaryTitle: LocalizedStringResource(
          "Retry iCloud Sync",
          bundle: #bundle,
          comment: "Retries a transient CloudKit profile sync failure."
        ),
        primaryAction: { await store.retry() },
        keepLocalAction: { await store.keepLocalOnly() },
        isWorking: store.isWorking
      )
    case .failed(let failure):
      ProfileSyncChoiceBanner(
        message: failureMessage(for: failure),
        primaryTitle: LocalizedStringResource(
          "Retry iCloud Sync",
          bundle: #bundle,
          comment: "Retries an unavailable CloudKit profile sync operation."
        ),
        primaryAction: { await store.retry() },
        keepLocalAction: { await store.keepLocalOnly() },
        isWorking: store.isWorking
      )
    case .recoveryRequired(let recovery):
      ProfileSyncChoiceBanner(
        message: recoveryMessage(for: recovery.reason),
        primaryTitle: LocalizedStringResource(
          "Use Local Profiles with This iCloud Account",
          bundle: #bundle,
          comment:
            "Explicitly resumes CloudKit by uploading the preserved local profiles to the current account."
        ),
        primaryAction: {
          await store.resumeUsingLocalProfiles()
        },
        keepLocalAction: { await store.keepLocalOnly() },
        isWorking: store.isWorking
      )
    }
  }

  private func retryMessage(
    for failure: ProfileSyncFailure
  ) -> LocalizedStringResource {
    switch failure.kind {
    case .offline:
      LocalizedStringResource(
        "Broker profiles remain available on this device while the network is offline.",
        bundle: #bundle,
        comment:
          "Explains that an offline CloudKit failure did not remove local profiles."
      )
    case .rateLimited:
      LocalizedStringResource(
        "iCloud asked JollysMQTT to wait. Broker profiles remain available on this device.",
        bundle: #bundle,
        comment:
          "Explains a rate-limited CloudKit retry without exposing private profile data."
      )
    case .unavailable, .invalidRemoteProfile, .corruptRemotePayload,
      .internalFailure:
      failureMessage(for: failure)
    }
  }

  private func failureMessage(
    for failure: ProfileSyncFailure
  ) -> LocalizedStringResource {
    switch failure.kind {
    case .unavailable:
      LocalizedStringResource(
        "iCloud profile sync is unavailable. Broker profiles remain available on this device.",
        bundle: #bundle,
        comment:
          "Explains unavailable CloudKit sync while preserving local profiles."
      )
    case .invalidRemoteProfile, .corruptRemotePayload:
      LocalizedStringResource(
        "An iCloud profile record could not be used. The last known local profiles were preserved.",
        bundle: #bundle,
        comment:
          "Explains rejected remote profile data and preservation of local data."
      )
    case .offline, .rateLimited, .internalFailure:
      LocalizedStringResource(
        "iCloud profile sync did not finish. Broker profiles remain available on this device.",
        bundle: #bundle,
        comment:
          "Generic CloudKit sync failure preserving local broker profiles."
      )
    }
  }

  private func recoveryMessage(
    for reason: ProfileSyncRecovery.Reason
  ) -> LocalizedStringResource {
    switch reason {
    case .signedOut:
      LocalizedStringResource(
        "iCloud was signed out. Sign in first, then choose whether to use these local profiles with that account or keep them only on this device.",
        bundle: #bundle,
        comment:
          "Prompts for an explicit choice after the iCloud account signs out."
      )
    case .accountChanged:
      LocalizedStringResource(
        "The iCloud account changed. Local profiles were preserved and will not be uploaded to the new account without your permission.",
        bundle: #bundle,
        comment:
          "Warns that profiles from a prior account are not automatically uploaded to a new account."
      )
    case .zoneDeleted:
      LocalizedStringResource(
        "The iCloud profile zone was deleted. Local profiles were preserved. Choose whether to recreate the zone from them.",
        bundle: #bundle,
        comment:
          "Prompts after a user-deleted CloudKit custom zone."
      )
    case .zonePurged:
      LocalizedStringResource(
        "iCloud purged the profile zone. Local profiles were preserved. Choose whether to recreate the zone from them.",
        bundle: #bundle,
        comment:
          "Prompts after CloudKit purges the custom profile zone."
      )
    case .encryptedDataReset:
      LocalizedStringResource(
        "iCloud reset the encrypted-data key. Local profiles were preserved. Choose whether to upload them again under the new key.",
        bundle: #bundle,
        comment:
          "Prompts after an encrypted CloudKit data-key reset."
      )
    }
  }
}

private struct ProfileSyncChoiceBanner: View {
  let message: LocalizedStringResource
  let primaryTitle: LocalizedStringResource
  let primaryAction: @MainActor () async -> Void
  let keepLocalAction: @MainActor () async -> Void
  let isWorking: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(message)
      ViewThatFits(in: .horizontal) {
        actionButtons(axis: .horizontal)
        actionButtons(axis: .vertical)
      }
    }
    .profileSyncBannerStyle()
  }

  @ViewBuilder
  private func actionButtons(
    axis: Axis
  ) -> some View {
    let layout =
      axis == .horizontal
      ? AnyLayout(HStackLayout(spacing: 8))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
    layout {
      Button {
        Task { await primaryAction() }
      } label: {
        Text(primaryTitle)
      }
      .disabled(isWorking)
      Button {
        Task { await keepLocalAction() }
      } label: {
        Text(
          "Keep Profiles Only on This Device",
          bundle: #bundle,
          comment:
            "Disables remote profile sync while preserving every local profile."
        )
      }
      .disabled(isWorking)
    }
  }
}

extension View {
  fileprivate func profileSyncBannerStyle() -> some View {
    self
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(.regularMaterial)
      .accessibilityElement(children: .contain)
  }
}

extension BrokerDeletionOutcome {
  fileprivate var localizedSummary: LocalizedStringResource {
    if succeeded {
      return LocalizedStringResource(
        "The profile and selected local resources were removed.",
        bundle: #bundle,
        comment: "Successful broker deletion outcome."
      )
    }
    if secureHistoryCleanupPending, failures.isEmpty {
      return LocalizedStringResource(
        "The profile and selected resources were removed, but secure history file cleanup is still pending. Retry the remaining cleanup.",
        bundle: #bundle,
        comment:
          "Broker deletion with pending retryable secure SQLite cleanup."
      )
    }
    if failures.count > 1 {
      return LocalizedStringResource(
        "The profile was deleted, but multiple selected cleanup steps remain. Retry the remaining cleanup.",
        bundle: #bundle,
        comment:
          "Reports simultaneous independent post-profile cleanup failures."
      )
    }
    switch failure {
    case .history:
      return history == .partiallyRemoved
        ? LocalizedStringResource(
          "The profile was deleted and some history was removed, but history clearing did not complete. Retry the original clear continuation.",
          bundle: #bundle,
          comment:
            "Partial history removal remains after committed profile deletion."
        )
        : LocalizedStringResource(
          "The profile was deleted, but history could not be removed. Retry the remaining cleanup.",
          bundle: #bundle,
          comment: "History cleanup failure after committed profile deletion."
        )
    case .credential:
      return LocalizedStringResource(
        "The profile was deleted, but the device password could not be removed. Retry the remaining cleanup.",
        bundle: #bundle,
        comment:
          "Credential cleanup failure after profile deletion already committed."
      )
    case .retentionSettings:
      return LocalizedStringResource(
        "The profile was deleted, but its retention settings could not be removed. Retry the remaining cleanup.",
        bundle: #bundle,
        comment:
          "Retention settings cleanup failure after profile deletion committed."
      )
    case .cleanupJournal:
      return profile == .removed
        ? LocalizedStringResource(
          "The selected cleanup completed, but its crash-recovery journal could not be removed. Retry to finish securely.",
          bundle: #bundle,
          comment:
            "Deletion cleanup succeeded but its durable retry journal could not be removed."
        )
        : LocalizedStringResource(
          "The profile was not deleted because its crash-safe cleanup choices could not be saved. No history, password, workspace, or retention data was removed.",
          bundle: #bundle,
          comment:
            "Deletion was refused because durable cleanup intent could not be recorded first."
        )
    case .profile:
      return LocalizedStringResource(
        "The profile deletion could not be saved. The profile remains, and no selected history, password, or retention settings were touched.",
        bundle: #bundle,
        comment:
          "Profile persistence failure before any optional local resource cleanup."
      )
    case nil:
      return LocalizedStringResource(
        "Broker deletion did not complete.",
        bundle: #bundle,
        comment: "Fallback incomplete broker deletion outcome."
      )
    }
  }
}

private struct BrokerListSidebar: View {
  @Bindable var store: ServerListStore
  let presentation: BrokerListPresentation

  var body: some View {
    List(selection: $store.selection) {
      ForEach(store.state.profiles) { ranked in
        BrokerProfileRow(
          id: ranked.id,
          name: ranked.profile.name,
          endpoint: ranked.profile.endpointSummary
        )
        .tag(ranked.id)
        .contextMenu {
          BrokerRowActions(
            profileID: ranked.id,
            store: store,
            presentation: presentation
          )
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
    .modifier(
      BrokerListActionsModifier(
        store: store,
        presentation: presentation
      )
    )
  }
}

private struct BrokerListActionsModifier: ViewModifier {
  let store: ServerListStore
  let presentation: BrokerListPresentation

  func body(content: Content) -> some View {
    #if os(macOS)
      content.safeAreaInset(edge: .bottom) {
        AddBrokerButton(store: store, presentation: presentation)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .background(.bar)
      }
    #else
      content.toolbar {
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
        ToolbarItem(placement: .primaryAction) {
          AddBrokerButton(store: store, presentation: presentation)
        }
      }
    #endif
  }
}

private struct AddBrokerButton: View {
  let store: ServerListStore
  let presentation: BrokerListPresentation

  var body: some View {
    Button(action: addBroker) {
      Label {
        Text(
          "Add Broker",
          bundle: #bundle,
          comment: "Action that creates a broker profile."
        )
      } icon: {
        Image(systemName: "plus")
      }
    }
    .keyboardShortcut("n", modifiers: [.command, .shift])
    .accessibilityIdentifier("server-list.add-broker")
    .accessibilityHint(
      Text(
        "Opens the broker profile editor.",
        bundle: #bundle,
        comment: "Accessibility hint for the add broker action."
      )
    )
  }

  private func addBroker() {
    Task {
      switch presentation {
      case .compactSummary:
        await store.send(.createProfile(id: UUID()))
      case .regularEditor:
        await store.send(.createProfileInline(id: UUID()))
      }
    }
  }
}

private struct BrokerProfileRow: View {
  let id: BrokerProfile.ID
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
    .accessibilityIdentifier("server-list.profile.\(id.uuidString)")
  }
}

private struct BrokerRowActions: View {
  let profileID: BrokerProfile.ID
  let store: ServerListStore
  let presentation: BrokerListPresentation

  var body: some View {
    Button {
      Task {
        switch presentation {
        case .compactSummary:
          await store.send(.editProfile(profileID))
        case .regularEditor:
          await store.send(.select(profileID))
        }
      }
    } label: {
      Text(
        "Edit",
        bundle: #bundle,
        comment: "Context action that edits a broker profile."
      )
    }
    .disabled(store.state.isProfileMutationBlocked)
    Button {
      Task {
        switch presentation {
        case .compactSummary:
          await store.send(.duplicateProfile(profileID, newID: UUID()))
        case .regularEditor:
          await store.send(.duplicateProfileInline(profileID, newID: UUID()))
        }
      }
    } label: {
      Text(
        "Duplicate",
        bundle: #bundle,
        comment: "Context action that duplicates a broker profile."
      )
    }
    .disabled(store.state.isProfileMutationBlocked)
    Button(role: .destructive) {
      store.sendImmediately(.requestDeleteProfile(profileID))
    } label: {
      Text(
        "Delete",
        bundle: #bundle,
        comment: "Context action that requests broker profile deletion."
      )
    }
    .disabled(store.state.isProfileDeletionBusy)
  }
}

private struct BrokerListDetail: View {
  let profile: BrokerProfile?
  let credentialAvailability: CredentialAvailability?
  let store: ServerListStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore
  let presentation: BrokerListPresentation

  var body: some View {
    switch presentation {
    case .compactSummary:
      BrokerProfileSummary(
        profile: profile,
        credentialAvailability: credentialAvailability,
        store: store,
        historyMaintenanceStore: historyMaintenanceStore
      )
    case .regularEditor:
      BrokerProfileInlineDetail(
        profile: profile,
        credentialAvailability: credentialAvailability,
        store: store,
        historyMaintenanceStore: historyMaintenanceStore
      )
    }
  }
}

private struct BrokerProfileSummary: View {
  let profile: BrokerProfile?
  let credentialAvailability: CredentialAvailability?
  let store: ServerListStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore

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
        BrokerDetailActions(
          profileID: profile.id,
          store: store,
          historyMaintenanceStore: historyMaintenanceStore
        )
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

private struct BrokerProfileInlineDetail: View {
  let profile: BrokerProfile?
  let credentialAvailability: CredentialAvailability?
  let store: ServerListStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore

  var body: some View {
    if let editor = store.state.editor,
      editor.presentation == .inline
    {
      InlineProfileEditorView(
        mode: editor.mode,
        storedProfile: store.state.profiles.first {
          $0.id == editor.id
        }?.profile,
        credentialAvailability: credentialAvailability,
        store: store,
        historyMaintenanceStore: historyMaintenanceStore
      )
      .id(editor.id)
    } else if let profile {
      ProgressView()
        .accessibilityLabel(
          Text(
            "Loading broker profile editor",
            bundle: #bundle,
            comment: "Accessibility label while the selected broker editor is prepared."
          )
        )
        .task(id: profile.id) {
          await store.send(.editProfileInline(profile.id))
        }
    } else {
      BrokerListEmptyState()
    }
  }
}

private struct InlineProfileEditorView: View {
  let mode: ProfileEditorState.Mode
  let storedProfile: BrokerProfile?
  let credentialAvailability: CredentialAvailability?
  let store: ServerListStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore

  var body: some View {
    VStack(spacing: 0) {
      InlineProfileEditorHeader(
        mode: mode,
        storedProfile: storedProfile,
        credentialAvailability: credentialAvailability,
        store: store,
        historyMaintenanceStore: historyMaintenanceStore
      )
      Divider()
      ProfileEditorForm(store: store)
      Divider()
      InlineProfileEditorFooter(mode: mode, store: store)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("server-list.inline-editor")
  }
}

private struct InlineProfileEditorHeader: View {
  let mode: ProfileEditorState.Mode
  let storedProfile: BrokerProfile?
  let credentialAvailability: CredentialAvailability?
  let store: ServerListStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(
          mode == .create
            ? LocalizedStringResource(
              "New Broker",
              bundle: #bundle,
              comment: "Heading for a new inline broker profile draft."
            )
            : LocalizedStringResource(
              "Broker Profile",
              bundle: #bundle,
              comment: "Heading for the selected inline broker profile editor."
            )
        )
        .font(.title2)
        Spacer()
        if let storedProfile {
          BrokerInlineActions(
            profileID: storedProfile.id,
            store: store,
            historyMaintenanceStore: historyMaintenanceStore
          )
        }
      }

      if storedProfile?.username == nil, storedProfile != nil {
        AnonymousBrokerStatus()
      } else if storedProfile != nil {
        BrokerCredentialAvailability(availability: credentialAvailability)
      }
    }
    .padding()
  }
}

private struct BrokerInlineActions: View {
  let profileID: BrokerProfile.ID
  let store: ServerListStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        buttons
      }
      VStack(alignment: .trailing) {
        buttons
      }
    }
  }

  @ViewBuilder
  private var buttons: some View {
    Button {
      Task { await store.send(.connect(profileID)) }
    } label: {
      Label {
        Text(
          "Connect",
          bundle: #bundle,
          comment: "Connects using the unchanged saved broker profile."
        )
      } icon: {
        Image(systemName: "bolt.horizontal")
      }
    }
    .buttonStyle(.borderedProminent)

    Button {
      historyMaintenanceStore.send(.setPresented(true))
    } label: {
      Text(
        "Local History",
        bundle: #bundle,
        comment: "Opens local history controls for the selected broker."
      )
    }
  }
}

private struct InlineProfileEditorFooter: View {
  let mode: ProfileEditorState.Mode
  let store: ServerListStore

  var body: some View {
    HStack {
      if mode == .edit {
        Button {
          store.sendImmediately(.revertEditor)
        } label: {
          Text(
            "Revert",
            bundle: #bundle,
            comment: "Restores the selected broker draft to its saved values."
          )
        }
        .disabled(!store.editorHasUnsavedChanges)
      } else {
        Button {
          store.sendImmediately(.cancelEditor)
        } label: {
          Text(
            "Cancel",
            bundle: #bundle,
            comment: "Cancels creation of an inline broker profile."
          )
        }
      }

      Spacer()

      Button {
        Task { await store.send(.saveEditorKeepingOpen) }
      } label: {
        Text(
          "Save",
          bundle: #bundle,
          comment: "Validates and saves the inline broker profile draft."
        )
      }
      .buttonStyle(.borderedProminent)
      .disabled(!store.editorHasUnsavedChanges)
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
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore

  var body: some View {
    ViewThatFits {
      HStack {
        BrokerActionButtons(
          profileID: profileID,
          store: store,
          historyMaintenanceStore: historyMaintenanceStore
        )
      }
      VStack {
        BrokerActionButtons(
          profileID: profileID,
          store: store,
          historyMaintenanceStore: historyMaintenanceStore
        )
      }
    }
  }
}

private struct BrokerActionButtons: View {
  let profileID: BrokerProfile.ID
  let store: ServerListStore
  @Bindable var historyMaintenanceStore: HistoryMaintenanceStore

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
    .disabled(store.state.isProfileMutationBlocked)

    Button {
      historyMaintenanceStore.send(.setPresented(true))
    } label: {
      Text(
        "Local History",
        bundle: #bundle,
        comment:
          "Opens per-broker local retention and history clearing while disconnected."
      )
    }
  }
}

private struct BrokerListEmptyState: View {
  var body: some View {
    VStack(spacing: 16) {
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

      Text(
        "Start with a narrow subscription when exploring a busy broker. Profiles may synchronize, but passwords and message history stay on this device.",
        bundle: #bundle,
        comment: "Concise first-run onboarding guidance on the empty broker list."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)
    }
    .padding()
    .accessibilityIdentifier("onboarding.empty")
  }
}

private struct ProfileEditorView: View {
  let store: ServerListStore
  let profileID: BrokerProfile.ID

  var body: some View {
    NavigationStack {
      ProfileEditorForm(store: store)
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

private struct ProfileEditorForm: View {
  let store: ServerListStore

  var body: some View {
    Form {
      ProfileEndpointSection(store: store)
      ProfileAuthenticationSection(store: store)
      ProfileAdvancedSection(store: store)
      ProfileValidationSection(
        issues: store.state.editor?.validationIssues ?? []
      )
    }
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
      .accessibilityIdentifier("profile-editor.name")

      TextField(text: $store[editorText: .host]) {
        Text(
          "Host",
          bundle: #bundle,
          comment: "Label for the broker host name or IP address."
        )
      }
      .textContentType(.URL)
      .autocorrectionDisabled()
      .accessibilityIdentifier("profile-editor.host")

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
