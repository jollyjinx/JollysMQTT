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
}
