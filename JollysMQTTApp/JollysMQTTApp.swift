import JollysMQTT
import JollysMQTTCore
import SwiftUI

@main
struct JollysMQTTApp: App {
  var body: some Scene {
    WindowGroup(for: WorkspaceID.self) { workspaceID in
      RestoredWorkspaceScene(restoredID: workspaceID)
    } defaultValue: {
      WorkspaceID()
    }
    .commands {
      JollysMQTTWindowCommands()
    }
  }
}

private struct RestoredWorkspaceScene: View {
  @Binding private var restoredID: WorkspaceID

  init(restoredID: Binding<WorkspaceID>) {
    _restoredID = restoredID
  }

  var body: some View {
    JollysMQTTRootView(workspaceID: restoredID)
  }
}
