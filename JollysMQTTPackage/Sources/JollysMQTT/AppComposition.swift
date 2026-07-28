import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

public struct JollysMQTTAppDependencies: Sendable {
  public static let shared: JollysMQTTAppDependencies = {
    let support =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    let root = support.appending(
      path: "JollysMQTT",
      directoryHint: .isDirectory
    )
    return JollysMQTTAppDependencies(
      profileRepository: LocalProfileRepository(
        fileURL: root.appending(path: "profiles.json")
      ),
      credentialRepository: CredentialRepository.shared,
      workspaceRepository: LocalWorkspaceRepository(
        directoryURL: root.appending(
          path: "workspaces",
          directoryHint: .isDirectory
        )
      )
    )
  }()

  public let profileRepository: any ProfileRepositoryProtocol
  public let credentialRepository: any CredentialRepositoryProtocol
  public let workspaceRepository: any WorkspaceRepositoryProtocol
  public let workspaceReleaser: any WorkspaceLeaseReleasing

  public init(
    profileRepository: any ProfileRepositoryProtocol,
    credentialRepository: any CredentialRepositoryProtocol = CredentialRepository.shared,
    workspaceRepository: any WorkspaceRepositoryProtocol,
    workspaceReleaser: any WorkspaceLeaseReleasing = NoopWorkspaceLeaseReleaser()
  ) {
    self.profileRepository = profileRepository
    self.credentialRepository = credentialRepository
    self.workspaceRepository = workspaceRepository
    self.workspaceReleaser = workspaceReleaser
  }

  @MainActor
  public func makeSceneStore(id: WorkspaceID) -> WorkspaceSceneStore {
    WorkspaceSceneStore(id: id, dependencies: self)
  }
}

@MainActor
@Observable
public final class WorkspaceSceneStore {
  public let workspace: WorkspaceStore
  public let serverList: ServerListStore

  private let workspaceRepository: any WorkspaceRepositoryProtocol
  private let lifecycle: WorkspaceLifecycleOwner
  private var hasStarted = false

  public init(
    id: WorkspaceID,
    dependencies: JollysMQTTAppDependencies
  ) {
    let workspace = WorkspaceStore(
      id: id,
      repository: dependencies.workspaceRepository
    )
    self.workspace = workspace
    self.serverList = ServerListStore(
      repository: dependencies.profileRepository,
      credentialRepository: dependencies.credentialRepository
    )
    self.workspaceRepository = dependencies.workspaceRepository
    self.lifecycle = WorkspaceLifecycleOwner(
      id: id,
      repository: dependencies.workspaceRepository,
      releaser: dependencies.workspaceReleaser,
      prepareForRelease: {
        await workspace.flush()
      }
    )
  }

  public var selectedProfileID: UUID? {
    get { workspace.state.record.selectedProfileID }
    set {
      workspace.selectedProfileID = newValue
      serverList.sendImmediately(.select(newValue))
    }
  }

  public func run() async {
    await start()
    await lifecycle.run()
  }

  public func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    do {
      try await workspaceRepository.pruneClosed()
    } catch {
      // Pruning old closed records must not block opening the current scene.
    }
    await workspace.load()

    let restoredSelection = workspace.state.record.selectedProfileID
    serverList.sendImmediately(.select(restoredSelection))
    await serverList.send(.load)

    if !workspace.state.persistenceError,
      case .serverList = workspace.state.record.route
    {
      let resolvedSelection =
        serverList.state.profiles.contains { $0.id == restoredSelection }
        ? restoredSelection
        : serverList.state.selectedProfileID
      selectedProfileID = resolvedSelection
      await workspace.flush()
    }
  }

  public func connectCurrentWorkspace(_ ready: ConnectReadyState) {
    workspace.sendImmediately(.connect(profileID: ready.profile.id))
    serverList.sendImmediately(.consumeConnectReady(requestID: ready.requestID))
  }

  public func showServerList() {
    workspace.sendImmediately(.showServerList)
  }

  public func waitUntilOwned() async {
    await lifecycle.waitUntilRunning()
  }
}
