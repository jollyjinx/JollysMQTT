import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTT

@Suite("Adaptive workspace")
struct AdaptiveWorkspaceTests {
  @Test("Every connected workflow remains a first-class destination")
  func completeDestinationSet() {
    #expect(
      WorkspaceDestination.allCases
        == [.topics, .details, .publish, .charts]
    )
  }

  @Test(
    "Compact widths use persistent tabs and regular widths use native split navigation",
    arguments: [
      (WorkspaceWidthClass.compact, AdaptiveWorkspacePresentation.compactTabs),
      (WorkspaceWidthClass.regular, AdaptiveWorkspacePresentation.wideSplit),
    ]
  )
  func adaptivePresentation(
    widthClass: WorkspaceWidthClass,
    expected: AdaptiveWorkspacePresentation
  ) {
    #expect(
      AdaptiveWorkspacePresentation.resolve(widthClass: widthClass)
        == expected
    )
  }

  @Test("Regular presentation uses destination-specific pane fit")
  func regularPresentationUsesDestinationPaneFit() {
    let requirements = AdaptiveWorkspacePresentation.PaneRequirements(
      topicTree: 320,
      information: 360,
      graphDashboard: 320,
      divider: 1
    )

    #expect(requirements.minimumRegularWidth == 681)
    #expect(requirements.minimumGraphWidth == 1_002)
    #expect(
      AdaptiveWorkspacePresentation.resolve(
        widthClass: .regular,
        availableWidth: 680,
        destination: .details,
        requirements: requirements
      ) == .compactTabs
    )
    #expect(
      AdaptiveWorkspacePresentation.resolve(
        widthClass: .regular,
        availableWidth: 681,
        destination: .details,
        requirements: requirements
      ) == .wideSplit
    )
    #expect(
      AdaptiveWorkspacePresentation.resolve(
        widthClass: .compact,
        availableWidth: 1_200,
        destination: .details,
        requirements: requirements
      ) == .compactTabs
    )
    #expect(
      AdaptiveWorkspacePresentation.resolve(
        widthClass: .regular,
        availableWidth: 1_001,
        destination: .charts,
        requirements: requirements
      ) == .compactTabs
    )
    #expect(
      AdaptiveWorkspacePresentation.resolve(
        widthClass: .regular,
        availableWidth: 1_002,
        destination: .charts,
        requirements: requirements
      ) == .wideSplit
    )
  }

  @Test("Only compact topic selection advances the active destination")
  func selectionNavigationFollowsPresentation() {
    for destination in WorkspaceDestination.allCases {
      #expect(
        TopicSelectionNavigationBehavior.persistentInformationPane
          .destinationAfterSelectingCurrentValue(from: destination)
          == destination
      )
      #expect(
        TopicSelectionNavigationBehavior.compactAdvancesToDetails
          .destinationAfterSelectingCurrentValue(from: destination)
          == .details
      )
    }
  }

  @Test(
    "Broker profiles edit inline at regular width and retain a compact summary destination",
    arguments: [
      (WorkspaceWidthClass.compact, BrokerListPresentation.compactSummary),
      (WorkspaceWidthClass.regular, BrokerListPresentation.regularEditor),
    ]
  )
  func brokerListPresentation(
    widthClass: WorkspaceWidthClass,
    expected: BrokerListPresentation
  ) {
    #expect(BrokerListPresentation.resolve(widthClass: widthClass) == expected)
  }

  @Test("Help covers every release-blocking behavior")
  func helpCoverage() {
    #expect(
      Set(JollysMQTTHelpTopic.allCases.map(\.concept))
        == Set(JollysMQTTHelpConcept.allCases)
    )
  }

  @Test("Release navigation and help strings live in the package catalog")
  func releaseStringsAreCatalogued() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let catalogURL =
      packageRoot
      .appending(path: "Sources/JollysMQTT/Resources/Localizable.xcstrings")
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
        as? [String: Any]
    )
    #expect(object["sourceLanguage"] as? String == "en")
    let strings = try #require(object["strings"] as? [String: Any])
    let releaseBlockingKeys = [
      "Topics",
      "Details",
      "Publish",
      "Charts",
      "Help",
      "Choose subscription scope deliberately",
      "Understand retained delivery",
      "Expect reconnect after suspension",
      "Passwords stay on one device",
      "Overload stops the connection safely",
      "History can contain visible gaps",
      "Profile sync can be local only",
      "Unsaved Broker Changes",
      "Save Changes",
      "Discard Changes",
      "Continue Editing",
      "Revert",
    ]
    for key in releaseBlockingKeys {
      #expect(strings[key] != nil, "Missing release string: \(key)")
    }
  }

  @Test("Package navigation never uses app-bundle shorthand labels")
  func packageAwareNavigationLabels() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sources = packageRoot.appending(path: "Sources/JollysMQTT")
    let files = try FileManager.default
      .contentsOfDirectory(
        at: sources,
        includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "swift" }
    let shorthandPattern =
      #"\b(?:Tab|Label|Button|Toggle|Picker|TextField)\s*\(\s*""#
    let expression = try NSRegularExpression(pattern: shorthandPattern)

    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      let range = NSRange(source.startIndex..., in: source)
      #expect(
        expression.firstMatch(in: source, range: range) == nil,
        "Package-bundle shorthand localization in \(file.lastPathComponent)"
      )
    }
  }
}
