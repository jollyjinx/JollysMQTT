import Foundation
import JollysMQTTCore
import SwiftUI

public enum WorkspaceWidthClass: Equatable, Sendable {
  case compact
  case regular
}

public enum AdaptiveWorkspacePresentation: Equatable, Sendable {
  case compactTabs
  case wideSplit

  public struct PaneRequirements: Equatable, Sendable {
    public let topicTree: Double
    public let information: Double
    public let graphDashboard: Double
    public let divider: Double

    public init(
      topicTree: Double,
      information: Double,
      graphDashboard: Double = 320,
      divider: Double = 1
    ) {
      precondition(topicTree > 0)
      precondition(information > 0)
      precondition(graphDashboard > 0)
      precondition(divider >= 0)
      self.topicTree = topicTree
      self.information = information
      self.graphDashboard = graphDashboard
      self.divider = divider
    }

    public static let standard = Self(
      topicTree: 320,
      information: 360
    )

    public var minimumRegularWidth: Double {
      topicTree + divider + information
    }

    public var minimumGraphWidth: Double {
      minimumRegularWidth + divider + graphDashboard
    }

    public func minimumWidth(
      for destination: WorkspaceDestination
    ) -> Double {
      destination == .charts ? minimumGraphWidth : minimumRegularWidth
    }
  }

  public static func resolve(
    widthClass: WorkspaceWidthClass
  ) -> Self {
    switch widthClass {
    case .compact:
      .compactTabs
    case .regular:
      .wideSplit
    }
  }

  public static func resolve(
    widthClass: WorkspaceWidthClass,
    availableWidth: Double,
    destination: WorkspaceDestination = .details,
    requirements: PaneRequirements = .standard
  ) -> Self {
    guard widthClass == .regular,
      availableWidth.isFinite,
      availableWidth >= requirements.minimumWidth(for: destination)
    else {
      return .compactTabs
    }
    return .wideSplit
  }
}

public enum TopicSelectionNavigationBehavior: Equatable, Sendable {
  case compactAdvancesToDetails
  case persistentInformationPane

  public func destinationAfterSelectingCurrentValue(
    from destination: WorkspaceDestination
  ) -> WorkspaceDestination {
    switch self {
    case .compactAdvancesToDetails:
      .details
    case .persistentInformationPane:
      destination
    }
  }
}

public enum BrokerListPresentation: Equatable, Sendable {
  case compactSummary
  case regularEditor

  public static func resolve(widthClass: WorkspaceWidthClass) -> Self {
    widthClass == .compact ? .compactSummary : .regularEditor
  }
}

public enum JollysMQTTHelpConcept:
  String,
  CaseIterable,
  Equatable,
  Hashable,
  Sendable
{
  case broadSubscriptions
  case retainedDelivery
  case backgroundSuspension
  case missingCredentials
  case overload
  case historyGaps
  case localOnlySync
}

public enum JollysMQTTHelpTopic:
  String,
  CaseIterable,
  Identifiable,
  Sendable
{
  case subscriptions
  case retainedMessages
  case appLifecycle
  case credentials
  case overloadProtection
  case historyCoverage
  case profileSync

  public var id: String { rawValue }

  public var concept: JollysMQTTHelpConcept {
    switch self {
    case .subscriptions:
      .broadSubscriptions
    case .retainedMessages:
      .retainedDelivery
    case .appLifecycle:
      .backgroundSuspension
    case .credentials:
      .missingCredentials
    case .overloadProtection:
      .overload
    case .historyCoverage:
      .historyGaps
    case .profileSync:
      .localOnlySync
    }
  }
}

extension JollysMQTTHelpTopic {
  var title: LocalizedStringResource {
    switch self {
    case .subscriptions:
      LocalizedStringResource(
        "Choose subscription scope deliberately",
        bundle: #bundle,
        comment: "Help heading about broad MQTT subscriptions."
      )
    case .retainedMessages:
      LocalizedStringResource(
        "Understand retained delivery",
        bundle: #bundle,
        comment: "Help heading about MQTT retained-delivery semantics."
      )
    case .appLifecycle:
      LocalizedStringResource(
        "Expect reconnect after suspension",
        bundle: #bundle,
        comment: "Help heading about iOS and iPadOS background suspension."
      )
    case .credentials:
      LocalizedStringResource(
        "Passwords stay on one device",
        bundle: #bundle,
        comment: "Help heading about missing device-local credentials."
      )
    case .overloadProtection:
      LocalizedStringResource(
        "Overload stops the connection safely",
        bundle: #bundle,
        comment: "Help heading about bounded MQTT overload handling."
      )
    case .historyCoverage:
      LocalizedStringResource(
        "History can contain visible gaps",
        bundle: #bundle,
        comment: "Help heading about explicit local-history coverage gaps."
      )
    case .profileSync:
      LocalizedStringResource(
        "Profile sync can be local only",
        bundle: #bundle,
        comment: "Help heading about local-only profile synchronization."
      )
    }
  }

  var explanation: LocalizedStringResource {
    switch self {
    case .subscriptions:
      LocalizedStringResource(
        "New profiles include # and $SYS/# so ordinary and system topics are visible. Broad subscriptions can create heavy traffic on production brokers; narrow or disable them before connecting when appropriate.",
        bundle: #bundle,
        comment: "Help explaining broad MQTT subscription cost and defaults."
      )
    case .retainedMessages:
      LocalizedStringResource(
        "Retained delivery is packet metadata. A retained flag commonly marks a broker-stored value delivered to a new subscription; an unmarked live message does not prove that the broker stores no retained value.",
        bundle: #bundle,
        comment: "Help explaining precise MQTT retained-delivery semantics."
      )
    case .appLifecycle:
      LocalizedStringResource(
        "iPhone and iPad suspend general apps in the background. JollysMQTT saves the workspace, disconnects when no scene is active, and reconnects after activation; it does not promise background MQTT monitoring.",
        bundle: #bundle,
        comment: "Help explaining honest iOS and iPadOS background behavior."
      )
    case .credentials:
      LocalizedStringResource(
        "Passwords are stored in this device’s Keychain and never synchronize with broker profiles. A profile opened on another device asks for its password before connecting.",
        bundle: #bundle,
        comment: "Help explaining device-only credentials and missing-password prompts."
      )
    case .overloadProtection:
      LocalizedStringResource(
        "If messages arrive faster than bounded queues can process them, JollysMQTT disconnects with an overload error instead of allowing memory to grow without limit. Review subscription scope, then choose Retry.",
        bundle: #bundle,
        comment: "Help explaining visible bounded-ingress overload behavior."
      )
    case .historyCoverage:
      LocalizedStringResource(
        "History gaps are recorded after overload, storage failure, or disabled persistence. Charts and comparisons show available local data and do not imply complete coverage across a marked gap.",
        bundle: #bundle,
        comment: "Help explaining local-history coverage gaps."
      )
    case .profileSync:
      LocalizedStringResource(
        "Self-built and unprovisioned copies keep profiles local to this device. Official CloudKit builds can synchronize encrypted profile fields, but workspaces, history, charts, and passwords remain local.",
        bundle: #bundle,
        comment: "Help explaining local-only and CloudKit profile-sync boundaries."
      )
    }
  }

  var systemImage: String {
    switch self {
    case .subscriptions:
      "antenna.radiowaves.left.and.right"
    case .retainedMessages:
      "archivebox"
    case .appLifecycle:
      "arrow.clockwise"
    case .credentials:
      "key"
    case .overloadProtection:
      "exclamationmark.shield"
    case .historyCoverage:
      "clock.badge.exclamationmark"
    case .profileSync:
      "icloud.slash"
    }
  }
}

struct JollysMQTTHelpView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "JollysMQTT shows live broker data while keeping connections, local history, and synchronized profiles within explicit safety limits.",
            bundle: #bundle,
            comment: "Onboarding introduction at the top of application help."
          )
        }

        ForEach(JollysMQTTHelpTopic.allCases) { topic in
          Section {
            Text(topic.explanation)
          } header: {
            Label {
              Text(topic.title)
            } icon: {
              Image(systemName: topic.systemImage)
            }
          }
        }
      }
      .navigationTitle(
        Text(
          "JollysMQTT Help",
          bundle: #bundle,
          comment: "Title of the onboarding and operational help screen."
        )
      )
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            dismiss()
          } label: {
            Text(
              "Done",
              bundle: #bundle,
              comment: "Closes the onboarding and operational help screen."
            )
          }
        }
      }
    }
    .frame(minWidth: 320, idealWidth: 620, minHeight: 420, idealHeight: 720)
    .accessibilityIdentifier("help.content")
  }
}
