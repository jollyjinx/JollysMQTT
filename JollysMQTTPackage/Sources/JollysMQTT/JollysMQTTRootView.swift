import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import SwiftUI

public struct JollysMQTTRootView: View {
  @State private var store: ServerListStore

  @MainActor
  public init() {
    let support =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    let fileURL =
      support
      .appending(path: "JollysMQTT", directoryHint: .isDirectory)
      .appending(path: "profiles.json")
    _store = State(
      initialValue: ServerListStore(
        repository: LocalProfileRepository(fileURL: fileURL)
      )
    )
  }

  @MainActor
  public init(store: ServerListStore) {
    _store = State(initialValue: store)
  }

  public var body: some View {
    ServerListView(store: store)
  }
}

struct ServerListView: View {
  @Bindable var store: ServerListStore

  var body: some View {
    NavigationSplitView {
      BrokerListSidebar(store: store)
    } detail: {
      BrokerListDetail(
        profile: store.state.profiles.first {
          $0.id == store.state.selectedProfileID
        }?.profile,
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
    .task {
      if !store.state.hasLoaded {
        await store.send(.load)
      }
    }
    .sheet(isPresented: $store.editorPresented) {
      if let editor = store.state.editor {
        ProfileEditorView(store: store, profileID: editor.id)
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
        Task { await store.send(.confirmDeleteProfile) }
      } label: {
        Text(
          "Delete",
          bundle: #bundle,
          comment: "Destructive action that deletes a broker profile."
        )
      }
      Button(role: .cancel) {
      } label: {
        Text(
          "Cancel",
          bundle: #bundle,
          comment: "Action that cancels a broker profile operation."
        )
      }
    } message: {
      Text(
        "The broker profile “\(store.pendingDeletionName)” will be removed. Credentials are managed separately.",
        bundle: #bundle,
        comment: "Deletion warning. The variable is the broker profile name."
      )
    }
  }
}

private struct BrokerListSidebar: View {
  @Bindable var store: ServerListStore

  var body: some View {
    List(selection: $store.selection) {
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
