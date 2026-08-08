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
    accessibilityTextSize: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-connected"]
    app.launchEnvironment["JOLLYSMQTT_UI_DESTINATION"] = destination
    app.launchEnvironment["JOLLYSMQTT_UI_WIDTH_CLASS"] = widthClass
    if accessibilityTextSize {
      app.launchEnvironment["UIPreferredContentSizeCategoryName"] =
        "UICTContentSizeCategoryAccessibilityXXXL"
    }
    app.launch()
    return app
  }

  @MainActor
  private func launchBrokerList(
    empty: Bool = false,
    widthClass: String = "regular",
    twoBrokers: Bool = false
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
    app.launch()
    return app
  }
}
