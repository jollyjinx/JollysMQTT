import JollysMQTT
import JollysMQTTCore
import SwiftUI

@main
struct JollysMQTTApp: App {
  private let launchFixture = JollysMQTTUITestFixture.current

  var body: some Scene {
    #if os(macOS)
      Window("Brokers", id: JollysMQTTWindows.brokerList) {
        JollysMQTTRootView(
          workspaceID: launchFixture?.workspaceID
            ?? JollysMQTTWindows.brokerListWorkspaceID,
          dependencies: launchFixture?.dependencies
            ?? JollysMQTTAppDependencies.shared
        )
      }
      .defaultSize(width: 920, height: 680)
      .defaultLaunchBehavior(.presented)
      .commands {
        JollysMQTTWindowCommands()
      }
    #endif
    WindowGroup(for: WorkspaceID.self) { workspaceID in
      RestoredWorkspaceScene(
        restoredID: workspaceID,
        dependencies: launchFixture?.dependencies
          ?? JollysMQTTAppDependencies.shared
      )
    } defaultValue: {
      launchFixture?.workspaceID ?? WorkspaceID()
    }
    #if os(macOS)
      .defaultSize(width: 1200, height: 800)
      .defaultLaunchBehavior(.suppressed)
    #else
      .commands {
        JollysMQTTWindowCommands()
      }
    #endif
  }
}

private struct RestoredWorkspaceScene: View {
  @Binding private var restoredID: WorkspaceID
  private let dependencies: JollysMQTTAppDependencies

  init(
    restoredID: Binding<WorkspaceID>,
    dependencies: JollysMQTTAppDependencies
  ) {
    _restoredID = restoredID
    self.dependencies = dependencies
  }

  var body: some View {
    JollysMQTTRootView(
      workspaceID: restoredID,
      dependencies: dependencies
    )
  }
}
