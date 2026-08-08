import XCTest

final class AdaptiveWorkspaceUITests: XCTestCase {
  @MainActor
  func testCompactDestinationsRemainReachableAtAccessibilityTextSize() {
    let app = launch(
      destination: "topics",
      widthClass: "compact",
      accessibilityTextSize: true
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.compact.tabs"]
        .waitForExistence(timeout: 5)
    )

    for title in ["Topics", "Details", "Publish", "Charts"] {
      let destination = app.tabBars.buttons[title]
      XCTAssertTrue(destination.exists, "\(title) must remain in the tab bar")
      destination.tap()
      XCTAssertTrue(destination.isSelected)
    }
  }

  @MainActor
  func testWideSplitKeepsTopicsAlongsideEveryWorkflow() {
    let app = launch(destination: "details", widthClass: "regular")
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.wide.split"]
        .waitForExistence(timeout: 5)
    )

    XCTAssertTrue(app.staticTexts["Topics"].exists)
    for title in ["Details", "Publish", "Charts"] {
      XCTAssertTrue(
        app.descendants(matching: .any)[title].exists,
        "\(title) must remain reachable in the wide workspace"
      )
    }
  }

  @MainActor
  func testRegularSelectionAndDrillingKeepTopicTreeBesideInformation() {
    let app = launch(destination: "topics", widthClass: "regular")
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.wide.split"]
        .waitForExistence(timeout: 5)
    )

    drillToTemperature(in: app)

    XCTAssertTrue(
      app.descendants(matching: .any)["topic-explorer"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["payload-information-pane"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["topic-row.factory/line/pressure"]
        .exists
    )

    let other = app.descendants(matching: .any)[
      "topic-disclosure.factory/other"
    ]
    XCTAssertTrue(other.exists)
    other.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["topic-row.factory/other/status"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.staticTexts["factory/line/temperature"].exists)
  }

  @MainActor
  func testRegularChartsRemainBesideTopicInformationDuringTraversalAndPinning() {
    let app = launch(destination: "charts", widthClass: "regular")
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.graph.split"]
        .waitForExistence(timeout: 5)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["topic-explorer"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["payload-information-pane"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["graph-dashboard-pane"].exists
    )
    XCTAssertTrue(app.staticTexts["No Pinned Charts"].exists)

    drillToTemperature(in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.graph.split"].exists
    )
    let pin = app.buttons["Pin to Chart"]
    XCTAssertTrue(pin.waitForExistence(timeout: 3))
    pin.tap()
    XCTAssertTrue(app.buttons["Remove Chart"].waitForExistence(timeout: 3))

    let pressure = app.descendants(matching: .any)[
      "topic-row.factory/line/pressure"
    ]
    XCTAssertTrue(pressure.exists)
    pressure.tap()
    XCTAssertTrue(app.buttons["Remove Chart"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["payload-information-pane"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["graph-dashboard-pane"].exists
    )
  }

  @MainActor
  func testCompactSelectionAdvancesAndReturnsToSelectedTopic() {
    let app = launch(destination: "topics", widthClass: "compact")
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.compact.tabs"]
        .waitForExistence(timeout: 5)
    )

    drillToTemperature(in: app)

    XCTAssertTrue(app.tabBars.buttons["Details"].isSelected)
    XCTAssertTrue(app.staticTexts["factory/line/temperature"].exists)
    app.tabBars.buttons["Topics"].tap()
    XCTAssertTrue(app.tabBars.buttons["Topics"].isSelected)
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "topic-row.factory/line/temperature"
      ].exists
    )
  }

  @MainActor
  func testResizeTransitionPreservesSelectionExpansionAndPayload() {
    let app = launch(
      destination: "topics",
      widthClass: "regular",
      resizeControl: true
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.wide.split"]
        .waitForExistence(timeout: 5)
    )
    drillToTemperature(in: app)

    app.buttons["workspace.test.resize.compact"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.compact.tabs"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.tabBars.buttons["Topics"].isSelected)
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "topic-row.factory/line/temperature"
      ].exists
    )
    app.tabBars.buttons["Details"].tap()
    XCTAssertTrue(app.staticTexts["factory/line/temperature"].exists)

    app.buttons["workspace.test.resize.regular"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.wide.split"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "topic-row.factory/line/temperature"
      ].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["payload-information-pane"].exists
    )
    XCTAssertTrue(app.staticTexts["factory/line/temperature"].exists)
  }

  @MainActor
  func testChartResizeTransitionPreservesThePinnedCardAndPauseState() {
    let app = launch(
      destination: "charts",
      widthClass: "regular",
      resizeControl: true
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.graph.split"]
        .waitForExistence(timeout: 5)
    )
    drillToTemperature(in: app)
    app.buttons["Pin to Chart"].tap()
    let pause = app.buttons["Pause"]
    XCTAssertTrue(pause.waitForExistence(timeout: 3))
    pause.tap()
    XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))

    app.buttons["workspace.test.resize.compact"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.compact.tabs"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.tabBars.buttons["Charts"].isSelected)
    XCTAssertTrue(app.buttons["Resume"].exists)

    app.buttons["workspace.test.resize.regular"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.graph.split"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.buttons["Resume"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["topic-explorer"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["payload-information-pane"].exists
    )
  }

  @MainActor
  func testRelaunchRestoresTheWideGraphPaneAndPinnedCard() {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("jollysmqtt-ui-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let app = launch(
      destination: "charts",
      widthClass: "regular",
      workspaceFile: persistenceURL.path
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.graph.split"]
        .waitForExistence(timeout: 5)
    )
    drillToTemperature(in: app)
    app.buttons["Pin to Chart"].tap()
    XCTAssertTrue(app.buttons["Remove Chart"].waitForExistence(timeout: 3))
    waitForPersistedChart(at: persistenceURL)

    app.terminate()
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["workspace.graph.split"]
        .waitForExistence(timeout: 5)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["topic-explorer"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["payload-information-pane"].exists
    )
    XCTAssertTrue(app.buttons["Remove Chart"].waitForExistence(timeout: 3))
  }

  @MainActor
  func testRestoredDestinationAndHelpAreKeyboardIndependent() {
    let app = launch(destination: "charts", widthClass: "regular")

    XCTAssertTrue(
      app.staticTexts["No Pinned Charts"].waitForExistence(timeout: 5)
    )

    let help = app.buttons["help.open"]
    XCTAssertTrue(help.exists)
    help.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["help.content"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.staticTexts["Understand retained delivery"].exists)
    XCTAssertTrue(app.staticTexts["History can contain visible gaps"].exists)
  }

  #if os(macOS)
    @MainActor
    func testAddBrokerIsDirectNamedActionFromEmptyListAndOpensCreationEditor() {
      let app = launchBrokerList(empty: true)
      let addBroker = app.buttons["server-list.add-broker"]

      XCTAssertTrue(
        app.descendants(matching: .any)["onboarding.empty"]
          .waitForExistence(timeout: 5)
      )
      XCTAssertTrue(addBroker.waitForExistence(timeout: 5))
      XCTAssertEqual(addBroker.label, "Add Broker")

      addBroker.click()
      XCTAssertTrue(
        app.staticTexts["New Broker"].waitForExistence(timeout: 3)
      )
    }

    @MainActor
    func testAddBrokerShortcutWorksFromEmptyBrokerList() {
      let app = launchBrokerList(empty: true)

      XCTAssertTrue(
        app.descendants(matching: .any)["onboarding.empty"]
          .waitForExistence(timeout: 5)
      )
      XCTAssertTrue(app.staticTexts["No Brokers"].exists)

      app.typeKey("n", modifierFlags: [.command, .shift])
      XCTAssertTrue(
        app.staticTexts["New Broker"].waitForExistence(timeout: 3)
      )
    }

    @MainActor
    func testRegularBrokerSelectionShowsPersistentInlineEditor() {
      let app = launchBrokerList(widthClass: "regular")

      XCTAssertTrue(
        app.descendants(matching: .any)["server-list.inline-editor"]
          .waitForExistence(timeout: 5)
      )
      XCTAssertTrue(
        app.descendants(matching: .any)["profile-editor.name"].exists
      )
      XCTAssertTrue(
        app.descendants(matching: .any)["profile-editor.host"].exists
      )
      XCTAssertTrue(app.buttons["Connect"].exists)
      XCTAssertTrue(app.buttons["Local History"].exists)
      XCTAssertTrue(app.buttons["Save"].exists)
      XCTAssertTrue(app.buttons["Revert"].exists)
    }

    @MainActor
    func testRegularBrokerSelectionProtectsUnsavedDraft() {
      let app = launchBrokerList(widthClass: "regular", twoBrokers: true)
      let name = app.descendants(matching: .any)["profile-editor.name"]
      XCTAssertTrue(name.waitForExistence(timeout: 5))
      name.click()
      name.typeKey("a", modifierFlags: .command)
      name.typeText("Unsaved Draft")

      app.descendants(matching: .any)[
        "server-list.profile.A1F9B0EF-D340-4F57-8E1A-4835CA73A1B2"
      ].click()

      XCTAssertTrue(
        app.staticTexts["Unsaved Broker Changes"]
          .waitForExistence(timeout: 3)
      )
      XCTAssertTrue(app.buttons["Save Changes"].exists)
      XCTAssertTrue(app.buttons["Discard Changes"].exists)
      XCTAssertTrue(app.buttons["Continue Editing"].exists)
      app.sheets.buttons["Continue Editing"].click()
      XCTAssertEqual(name.value as? String, "Unsaved Draft")
    }

    @MainActor
    func testSingleClickSelectsBrokerWithoutConnecting() {
      let app = launchBrokerList(widthClass: "regular", twoBrokers: true)
      let secondBroker = app.descendants(matching: .any)[
        "server-list.profile.A1F9B0EF-D340-4F57-8E1A-4835CA73A1B2"
      ]
      XCTAssertTrue(secondBroker.waitForExistence(timeout: 5))

      secondBroker.click()

      let name = app.descendants(matching: .any)["profile-editor.name"]
      XCTAssertTrue(name.waitForExistence(timeout: 3))
      XCTAssertEqual(name.value as? String, "UI Test Broker 2")
      XCTAssertFalse(
        app.descendants(matching: .any)["workspace.wide.split"].exists
      )
    }

    @MainActor
    func testDoubleClickConnectsTheExactBrokerRow() {
      let app = launchBrokerList(widthClass: "regular", twoBrokers: true)
      let secondBroker = app.descendants(matching: .any)[
        "server-list.profile.A1F9B0EF-D340-4F57-8E1A-4835CA73A1B2"
      ]
      XCTAssertTrue(secondBroker.waitForExistence(timeout: 5))

      secondBroker.doubleClick()

      XCTAssertTrue(
        app.descendants(matching: .any)["workspace.wide.split"]
          .waitForExistence(timeout: 5)
      )
      XCTAssertTrue(app.staticTexts["UI Test Broker 2"].exists)
    }

    @MainActor
    func testDoubleClickPreservesDirtyDraftUntilTheUserDecides() {
      let app = launchBrokerList(widthClass: "regular", twoBrokers: true)
      let name = app.descendants(matching: .any)["profile-editor.name"]
      XCTAssertTrue(name.waitForExistence(timeout: 5))
      name.click()
      name.typeKey("a", modifierFlags: .command)
      name.typeText("Unsaved Double Click Draft")

      app.descendants(matching: .any)[
        "server-list.profile.A1F9B0EF-D340-4F57-8E1A-4835CA73A1B2"
      ].doubleClick()

      XCTAssertTrue(
        app.staticTexts["Unsaved Broker Changes"]
          .waitForExistence(timeout: 3)
      )
      app.sheets.buttons["Continue Editing"].click()
      XCTAssertEqual(name.value as? String, "Unsaved Double Click Draft")
      XCTAssertFalse(
        app.descendants(matching: .any)["workspace.wide.split"].exists
      )
    }

    @MainActor
    func testDoubleClickUsesMissingCredentialPrompt() {
      let app = launchBrokerList(
        widthClass: "regular",
        requiresCredential: true
      )
      let broker = app.descendants(matching: .any)[
        "server-list.profile.E9DE2914-EDB1-4774-BFE5-601A5D8C7C1A"
      ]
      XCTAssertTrue(broker.waitForExistence(timeout: 5))

      broker.doubleClick()

      XCTAssertTrue(
        app.staticTexts["Password for UI Test Broker"]
          .waitForExistence(timeout: 3)
      )
      XCTAssertTrue(app.secureTextFields["Password"].exists)
      XCTAssertTrue(app.buttons["Save and Connect"].exists)
      XCTAssertFalse(
        app.descendants(matching: .any)["workspace.wide.split"].exists
      )
    }

    @MainActor
    func testCommandOConnectsTheSelectedBroker() {
      let app = launchBrokerList(widthClass: "regular")
      XCTAssertTrue(
        app.descendants(matching: .any)["server-list.inline-editor"]
          .waitForExistence(timeout: 5)
      )
      app.typeKey("o", modifierFlags: .command)
      XCTAssertTrue(
        app.descendants(matching: .any)["workspace.wide.split"]
          .waitForExistence(timeout: 5)
      )
    }

    @MainActor
    func testReturnConnectsTheSelectedBroker() {
      let app = launchBrokerList(widthClass: "regular")
      XCTAssertTrue(
        app.descendants(matching: .any)["server-list.inline-editor"]
          .waitForExistence(timeout: 5)
      )
      app.typeKey(.return, modifierFlags: [])
      XCTAssertTrue(
        app.descendants(matching: .any)["workspace.wide.split"]
          .waitForExistence(timeout: 5)
      )
    }

    @MainActor
    func testCompactBrokerSelectionKeepsDedicatedEditor() {
      let app = launchBrokerList(widthClass: "compact")

      XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
      XCTAssertFalse(
        app.descendants(matching: .any)["server-list.inline-editor"].exists
      )
      app.buttons["Edit"].click()
      XCTAssertTrue(
        app.staticTexts["Broker Profile"].waitForExistence(timeout: 3)
      )
    }

    @MainActor
    func testFocusedPublishCommandUsesCommandReturn() {
      let app = launch(destination: "publish", widthClass: "regular")
      let topic = app.textFields["publish.topic"]
      XCTAssertTrue(topic.waitForExistence(timeout: 5))
      topic.click()
      topic.typeText("ui/test")

      let payload = app.textViews["publish.payload"]
      XCTAssertTrue(payload.exists)
      payload.click()
      payload.typeText("ready")
      payload.typeKey(.return, modifierFlags: .command)

      XCTAssertTrue(
        app.staticTexts["QoS 0 publish accepted by the transport"]
          .waitForExistence(timeout: 3)
      )
    }
  #endif

  @MainActor
  private func launch(
    destination: String,
    widthClass: String,
    accessibilityTextSize: Bool = false,
    resizeControl: Bool = false,
    workspaceFile: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-connected"]
    if resizeControl {
      app.launchArguments.append("--ui-testing-resize-workspace")
    }
    app.launchEnvironment["JOLLYSMQTT_UI_DESTINATION"] = destination
    app.launchEnvironment["JOLLYSMQTT_UI_WIDTH_CLASS"] = widthClass
    if let workspaceFile {
      app.launchEnvironment["JOLLYSMQTT_UI_WORKSPACE_FILE"] = workspaceFile
    }
    if accessibilityTextSize {
      app.launchEnvironment["UIPreferredContentSizeCategoryName"] =
        "UICTContentSizeCategoryAccessibilityXXXL"
    }
    app.launch()
    return app
  }

  @MainActor
  private func waitForPersistedChart(at url: URL) {
    let persistedChart = NSPredicate { _, _ in
      guard let data = try? Data(contentsOf: url),
        let text = String(data: data, encoding: .utf8)
      else {
        return false
      }
      return text.contains("factory/line/temperature")
        && text.contains("numericChartDashboard")
    }
    expectation(
      for: persistedChart,
      evaluatedWith: NSObject()
    )
    waitForExpectations(timeout: 5)
  }

  @MainActor
  private func drillToTemperature(in app: XCUIApplication) {
    let factory = app.descendants(matching: .any)[
      "topic-disclosure.factory"
    ]
    XCTAssertTrue(factory.waitForExistence(timeout: 5))
    factory.tap()

    let line = app.descendants(matching: .any)[
      "topic-disclosure.factory/line"
    ]
    XCTAssertTrue(line.waitForExistence(timeout: 2))
    line.tap()

    let temperature = app.descendants(matching: .any)[
      "topic-row.factory/line/temperature"
    ]
    XCTAssertTrue(temperature.waitForExistence(timeout: 2))
    temperature.tap()
  }

  @MainActor
  private func launchBrokerList(
    empty: Bool = false,
    widthClass: String = "regular",
    twoBrokers: Bool = false,
    requiresCredential: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-broker-list"]
    app.launchEnvironment["JOLLYSMQTT_UI_WIDTH_CLASS"] = widthClass
    if empty {
      app.launchEnvironment["JOLLYSMQTT_UI_EMPTY_BROKER_LIST"] = "1"
    }
    if twoBrokers {
      app.launchEnvironment["JOLLYSMQTT_UI_TWO_BROKERS"] = "1"
    }
    if requiresCredential {
      app.launchEnvironment["JOLLYSMQTT_UI_REQUIRES_CREDENTIAL"] = "1"
    }
    app.launch()
    return app
  }
}
