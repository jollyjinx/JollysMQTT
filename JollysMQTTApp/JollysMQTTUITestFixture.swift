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
      let requiresCredential =
        ProcessInfo.processInfo.environment[
          "JOLLYSMQTT_UI_REQUIRES_CREDENTIAL"
        ] == "1"
      let baseProfile = BrokerProfile.new(
        id: profileID,
        name: "UI Test Broker",
        host: "fixture.invalid"
      )
      let profile = BrokerProfile(
        id: baseProfile.id,
        name: baseProfile.name,
        host: baseProfile.host,
        port: baseProfile.port,
        transport: baseProfile.transport,
        username: requiresCredential ? "operator" : nil,
        clientIDPolicy: baseProfile.clientIDPolicy,
        cleanSession: baseProfile.cleanSession,
        keepAliveSeconds: baseProfile.keepAliveSeconds,
        reconnectPolicy: baseProfile.reconnectPolicy,
        subscriptions: baseProfile.subscriptions
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
          credentialRepository: JollysMQTTestCredentialRepository(),
          workspaceRepository: JollysMQTTestWorkspaceRepository(
            route: route,
            selectedProfileID: profiles.first?.id,
            destination: requestedDestination,
            persistenceFileURL: ProcessInfo.processInfo.environment[
              "JOLLYSMQTT_UI_WORKSPACE_FILE"
            ].map { URL(fileURLWithPath: $0) }
          ),
          brokerFeedFactory: BrokerFeedLeaseFactory { _ in
            JollysMQTTestFeed()
          }
        )
      )
    }
  }

  private actor JollysMQTTestCredentialRepository:
    CredentialRepositoryProtocol
  {
    func status(for profileID: UUID) -> CredentialStatus {
      CredentialStatus(availability: .missing, revision: 0)
    }

    func save(
      _ credential: TransientCredential,
      for profileID: UUID
    ) -> CredentialStatus {
      CredentialStatus(availability: .available, revision: 1)
    }

    func delete(for profileID: UUID) -> CredentialStatus {
      CredentialStatus(availability: .missing, revision: 1)
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
    private let persistenceFileURL: URL?
    private var records: [WorkspaceID: WorkspaceRecord] = [:]

    init(
      route: WorkspaceRoute,
      selectedProfileID: UUID?,
      destination: WorkspaceDestination,
      persistenceFileURL: URL?
    ) {
      self.route = route
      self.selectedProfileID = selectedProfileID
      self.initialDestination = destination
      self.persistenceFileURL = persistenceFileURL
    }

    func load(id: WorkspaceID) throws -> WorkspaceRecord {
      if let record = records[id] {
        return record
      }
      if let persistenceFileURL,
        FileManager.default.fileExists(atPath: persistenceFileURL.path)
      {
        let record = try JSONDecoder().decode(
          WorkspaceRecord.self,
          from: Data(contentsOf: persistenceFileURL)
        )
        records[id] = record
        return record
      }
      return WorkspaceRecord(
        id: id,
        route: route,
        selectedProfileID: selectedProfileID,
        destination: initialDestination
      )
    }

    func save(_ record: WorkspaceRecord) throws {
      records[record.id] = record
      if let persistenceFileURL {
        try JSONEncoder().encode(record).write(
          to: persistenceFileURL,
          options: .atomic
        )
      }
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
      let topicContinuation = topicContinuation
      Task {
        let ingestion = BrokerFeedIngestion(
          brokerID: JollysMQTTUITestFixture.profileID,
          historySourceID: "ui-test-source",
          historyWriter: DisabledBrokerHistoryWriter()
        )
        let epoch = ConnectionEpochID(
          rawValue: UUID(
            uuidString: "28BD99D5-E270-46B0-9753-E30CD5A274E8"
          )!
        )
        let topics = [
          ("factory/line/temperature", "21.5"),
          ("factory/line/pressure", "101.3"),
          ("factory/other/status", "ready"),
        ]
        for (offset, fixture) in topics.enumerated() {
          await ingestion.ingest(
            BrokerInboundMessage(
              connectionEpoch: epoch,
              ordinal: UInt64(offset + 1),
              topic: fixture.0,
              payload: Data(fixture.1.utf8),
              qos: .atMostOnce,
              retained: false,
              duplicate: false,
              receivedAtMicroseconds: Int64(offset + 1) * 1_000_000
            )
          )
        }
        topicContinuation.yield(await ingestion.flush())
      }
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
