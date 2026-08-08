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
    static let secondProfileID = UUID(
      uuidString: "A1F9B0EF-D340-4F57-8E1A-4835CA73A1B2"
    )!

    let workspaceID: WorkspaceID
    let dependencies: JollysMQTTAppDependencies

    static var current: Self? {
      let arguments = ProcessInfo.processInfo.arguments
      let launchesConnectedWorkspace =
        arguments.contains("--ui-testing-connected")
      let launchesBrokerList =
        arguments.contains("--ui-testing-broker-list")
      guard launchesConnectedWorkspace || launchesBrokerList else {
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
      let profiles: [RankedBrokerProfile]
      if ProcessInfo.processInfo.environment[
        "JOLLYSMQTT_UI_EMPTY_BROKER_LIST"
      ] == "1" {
        profiles = []
      } else {
        var available = [
          RankedBrokerProfile(profile: profile, reorderRank: 0)
        ]
        if ProcessInfo.processInfo.environment[
          "JOLLYSMQTT_UI_TWO_BROKERS"
        ] == "1" {
          available.append(
            RankedBrokerProfile(
              profile: .new(
                id: secondProfileID,
                name: "UI Test Broker 2",
                host: "second.fixture.invalid"
              ),
              reorderRank: 1_024
            )
          )
        }
        profiles = available
      }
      let route: WorkspaceRoute =
        launchesBrokerList
        ? .serverList
        : .connected(profileID: profile.id)
      return Self(
        workspaceID: workspaceID,
        dependencies: JollysMQTTAppDependencies(
          profileRepository: JollysMQTTestProfileRepository(
            profiles: profiles
          ),
          workspaceRepository: JollysMQTTestWorkspaceRepository(
            route: route,
            selectedProfileID: profiles.first?.id,
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
    private let route: WorkspaceRoute
    private let selectedProfileID: UUID?
    private let initialDestination: WorkspaceDestination
    private var records: [WorkspaceID: WorkspaceRecord] = [:]

    init(
      route: WorkspaceRoute,
      selectedProfileID: UUID?,
      destination: WorkspaceDestination
    ) {
      self.route = route
      self.selectedProfileID = selectedProfileID
      self.initialDestination = destination
    }

    func load(id: WorkspaceID) -> WorkspaceRecord {
      records[id]
        ?? WorkspaceRecord(
          id: id,
          route: route,
          selectedProfileID: selectedProfileID,
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
    private let snapshotContinuation: AsyncStream<BrokerFeedSnapshot>.Continuation
    private let topicStream: AsyncStream<BrokerTopicTreeSnapshot>
    private let topicContinuation: AsyncStream<BrokerTopicTreeSnapshot>.Continuation

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
