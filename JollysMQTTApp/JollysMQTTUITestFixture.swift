#if DEBUG
  import Foundation
  import JollysMQTT
  import JollysMQTTCore
  import JollysMQTTStorage

  struct JollysMQTTUITestFixture {
    static let workspaceID = WorkspaceID(
      rawValue: UUID(uuidString: "58161A5D-20ED-4A36-BDC2-352294324F11")!
    )
    static let profileID = UUID(
      uuidString: "E9DE2914-EDB1-4774-BFE5-601A5D8C7C1A"
    )!

    let workspaceID: WorkspaceID
    let dependencies: JollysMQTTAppDependencies

    static var current: Self? {
      guard
        ProcessInfo.processInfo.arguments.contains("--ui-testing-connected")
      else {
        return nil
      }
      let requestedDestination =
        ProcessInfo.processInfo.environment["JOLLYSMQTT_UI_DESTINATION"]
        .flatMap(WorkspaceDestination.init(rawValue:))
        ?? .topics
      let profile = BrokerProfile.new(
        id: profileID,
        name: "UI Test Broker",
        host: "fixture.invalid"
      )
      return Self(
        workspaceID: workspaceID,
        dependencies: JollysMQTTAppDependencies(
          profileRepository: JollysMQTTestProfileRepository(
            profiles: [
              RankedBrokerProfile(profile: profile, reorderRank: 0)
            ]
          ),
          workspaceRepository: JollysMQTTestWorkspaceRepository(
            profileID: profile.id,
            destination: requestedDestination
          ),
          brokerFeedFactory: BrokerFeedLeaseFactory { _ in
            JollysMQTTestFeed()
          }
        )
      )
    }
  }

  private actor JollysMQTTestProfileRepository:
    ProfileRepositoryProtocol
  {
    private var profiles: [RankedBrokerProfile]

    init(profiles: [RankedBrokerProfile]) {
      self.profiles = profiles
    }

    func load() -> [RankedBrokerProfile] {
      profiles
    }

    func replaceAll(_ profiles: [RankedBrokerProfile]) {
      self.profiles = profiles
    }
  }

  private actor JollysMQTTestWorkspaceRepository:
    WorkspaceRepositoryProtocol
  {
    private let profileID: UUID
    private let initialDestination: WorkspaceDestination
    private var records: [WorkspaceID: WorkspaceRecord] = [:]

    init(
      profileID: UUID,
      destination: WorkspaceDestination
    ) {
      self.profileID = profileID
      self.initialDestination = destination
    }

    func load(id: WorkspaceID) -> WorkspaceRecord {
      records[id]
        ?? WorkspaceRecord(
          id: id,
          route: .connected(profileID: profileID),
          selectedProfileID: profileID,
          destination: initialDestination
        )
    }

    func save(_ record: WorkspaceRecord) {
      records[record.id] = record
    }

    func markClosed(id: WorkspaceID) {}
    func pruneClosed() {}
  }

  private actor JollysMQTTestFeed: BrokerFeedLeaseControlling {
    private let snapshotStream: AsyncStream<BrokerFeedSnapshot>
    private let snapshotContinuation:
      AsyncStream<BrokerFeedSnapshot>.Continuation
    private let topicStream: AsyncStream<BrokerTopicTreeSnapshot>
    private let topicContinuation:
      AsyncStream<BrokerTopicTreeSnapshot>.Continuation

    init() {
      (snapshotStream, snapshotContinuation) = AsyncStream.makeStream(
        of: BrokerFeedSnapshot.self,
        bufferingPolicy: .bufferingNewest(1)
      )
      (topicStream, topicContinuation) = AsyncStream.makeStream(
        of: BrokerTopicTreeSnapshot.self,
        bufferingPolicy: .bufferingNewest(1)
      )
      snapshotContinuation.yield(BrokerFeedSnapshot(phase: .connected))
      topicContinuation.yield(.empty)
    }

    func snapshots() -> AsyncStream<BrokerFeedSnapshot> {
      snapshotStream
    }

    func topicSnapshots() -> AsyncStream<BrokerTopicTreeSnapshot> {
      topicStream
    }

    func connect(_ configuration: BrokerFeedConfiguration) {
      snapshotContinuation.yield(BrokerFeedSnapshot(phase: .connected))
    }

    func retry() {}
    func retryHistoryPersistence() {}

    func cancel() {
      snapshotContinuation.yield(.idle)
    }

    func setSceneActive(_ isActive: Bool) {}
    func reconnectAllToApply() {}

    func publish(
      _ request: BrokerPublishRequest
    ) -> BrokerPublishResult {
      .success(
        BrokerPublishSuccess(
          operationID: request.operationID,
          completion:
            request.qos == .atMostOnce
            ? .transportAccepted
            : .acknowledged,
          completedAtMicroseconds: 1_000_000
        )
      )
    }

    func release() {
      snapshotContinuation.yield(.idle)
    }
  }
#else
  import JollysMQTT
  import JollysMQTTCore

  struct JollysMQTTUITestFixture {
    let workspaceID: WorkspaceID
    let dependencies: JollysMQTTAppDependencies
    static let current: Self? = nil
  }
#endif
