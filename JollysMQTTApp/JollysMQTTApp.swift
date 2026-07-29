import JollysMQTT
import JollysMQTTCore
import SwiftUI

@main
struct JollysMQTTApp: App {
  private let launchFixture = JollysMQTTUITestFixture.current

  var body: some Scene {
    WindowGroup(for: WorkspaceID.self) { workspaceID in
      RestoredWorkspaceScene(
        restoredID: workspaceID,
        dependencies: launchFixture?.dependencies
          ?? JollysMQTTAppDependencies.shared
      )
    } defaultValue: {
      launchFixture?.workspaceID ?? WorkspaceID()
    }
    .commands {
      JollysMQTTWindowCommands()
    }
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
