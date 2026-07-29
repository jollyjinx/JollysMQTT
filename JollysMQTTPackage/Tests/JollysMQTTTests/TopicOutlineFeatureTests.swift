import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTT

@Suite("Topic outline feature")
@MainActor
struct TopicOutlineFeatureTests {
  @Test(
    "Selection and expansion retain exact broker-topic identity across revisions and every sort mode",
    arguments: BrokerTopicSortMode.allCases
  )
  func stableIdentityAcrossUpdatesAndSorting(
    sortMode: BrokerTopicSortMode
  ) async throws {
    let brokerID = UUID()
    let ingestion = makeIngestion(brokerID: brokerID)
    let epoch = ConnectionEpochID()
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 1,
        topic: "root/alpha",
        receivedAt: 10
      )
    )
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 2,
        topic: "root/beta",
        receivedAt: 20
      )
    )
    let first = await ingestion.flush()
    var state = TopicOutlineFeature.State(
      selectedTopic: "root/beta",
      expandedTopics: ["root"],
      sortMode: sortMode
    )

    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(first)
    )
    let selectedID = try #require(
      state.rows.first(where: \.isSelected)?.id
    )
    let expandedID = try #require(
      state.rows.first { $0.fullTopic == "root" }
    ).id

    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 3,
        topic: "root/alpha",
        receivedAt: 30
      )
    )
    let second = await ingestion.flush()
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(second)
    )

    #expect(
      selectedID
        == BrokerTopicID(
          brokerID: brokerID,
          fullTopic: "root/beta"
        )
    )
    #expect(state.rows.first(where: \.isSelected)?.id == selectedID)
    #expect(state.expandedTopicIDs == [expandedID])
    #expect(
      state.rows.first { $0.id == expandedID }?.isExpanded == true
    )
  }

  @Test("Search folds paths and indexed summaries while retaining ancestors")
  func searchUsesCurrentIndexAndAncestors() async {
    let ingestion = makeIngestion(
      brokerID: UUID(),
      maximumPayloadSummaryCharacters: 16
    )
    let epoch = ConnectionEpochID()
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 1,
        topic: "Plant/Café/Temperature",
        payload: Data(#"{"a":"RUNNING","hidden":"not indexed"}"#.utf8),
        receivedAt: 1
      )
    )
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 2,
        topic: "other/value",
        payload: Data("offline".utf8),
        receivedAt: 2
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State()
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )
    #expect(
      snapshot.roots.first?.children.first?.children.first?
        .foldedFullTopicSearchText
        == "plant/cafe/temperature"
    )

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .setSearchText("cafe")
    )
    #expect(
      state.rows.map(\.fullTopic)
        == ["Plant", "Plant/Café", "Plant/Café/Temperature"]
    )

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .setSearchText("RUNNING")
    )
    #expect(
      state.rows.map(\.fullTopic)
        == ["Plant", "Plant/Café", "Plant/Café/Temperature"]
    )

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .setSearchText("not indexed")
    )
    #expect(state.rows.isEmpty)
  }

  @Test("A branch summary match does not advertise filtered-out children")
  func branchSummaryMatchUsesVisibleChildren() async throws {
    let ingestion = makeIngestion(brokerID: UUID())
    let epoch = ConnectionEpochID()
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 1,
        topic: "root",
        payload: Data("needle".utf8),
        receivedAt: 1
      )
    )
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 2,
        topic: "root/child",
        payload: Data("unrelated".utf8),
        receivedAt: 2
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State()
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .setSearchText("needle")
    )

    let row = try #require(state.rows.first)
    #expect(state.rows.map(\.fullTopic) == ["root"])
    #expect(row.hasChildren)
    #expect(!row.hasVisibleChildren)
    #expect(row.descendantValueTopicCount == 1)
    #expect(row.descendantMessageCount == 1)
    #expect(!row.isExpanded)
    #expect(!row.isExpansionForced)
    #expect(!row.allowsExpansionToggle)
  }

  @Test("Search-forced expansion cannot mutate persisted expansion")
  func searchForcedExpansionHasNoDisclosureAction() async throws {
    let ingestion = makeIngestion(brokerID: UUID())
    await ingestion.ingest(
      .outlineFixture(
        epoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "root/needle",
        receivedAt: 1
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State()
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )
    TopicOutlineFeature.reduce(
      state: &state,
      intent: .setSearchText("needle")
    )

    let root = try #require(
      state.rows.first { $0.fullTopic == "root" }
    )
    #expect(root.hasChildren)
    #expect(root.hasVisibleChildren)
    #expect(root.isExpanded)
    #expect(root.isExpansionForced)
    #expect(!root.allowsExpansionToggle)

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .toggleExpansion(root.id)
    )

    #expect(state.expandedTopics.isEmpty)
    #expect(state.rows.first { $0.id == root.id }?.isExpanded == true)

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .setSearchText("")
    )
    #expect(state.rows.map(\.fullTopic) == ["root"])
  }

  @Test("Same-path identities from another broker cannot select or expand")
  func wrongBrokerIdentityIsRejected() async throws {
    let brokerID = UUID()
    let ingestion = makeIngestion(brokerID: brokerID)
    await ingestion.ingest(
      .outlineFixture(
        epoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "root/value",
        receivedAt: 1
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State()
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )
    let root = try #require(
      state.rows.first { $0.fullTopic == "root" }
    )
    let wrongBrokerRoot = BrokerTopicID(
      brokerID: UUID(),
      fullTopic: root.fullTopic
    )

    TopicOutlineFeature.reduce(
      state: &state,
      intent: .toggleExpansion(wrongBrokerRoot)
    )
    TopicOutlineFeature.reduce(
      state: &state,
      intent: .selectTopic(wrongBrokerRoot)
    )

    #expect(state.expandedTopics.isEmpty)
    #expect(state.selectedTopic == nil)
    #expect(state.rows.map(\.fullTopic) == ["root"])
  }

  @Test("A queued snapshot from the previous broker is rejected after reset")
  func brokerResetRejectsQueuedPriorSnapshot() async {
    let firstBrokerID = UUID()
    let secondBrokerID = UUID()
    let firstIngestion = makeIngestion(brokerID: firstBrokerID)
    let secondIngestion = makeIngestion(brokerID: secondBrokerID)
    await firstIngestion.ingest(
      .outlineFixture(
        epoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "private/first",
        receivedAt: 1
      )
    )
    await secondIngestion.ingest(
      .outlineFixture(
        epoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "public/second",
        receivedAt: 2
      )
    )
    let firstSnapshot = await firstIngestion.flush()
    let secondSnapshot = await secondIngestion.flush()
    var state = TopicOutlineFeature.State(
      selectedTopic: "private/first",
      expandedTopics: ["private"],
      expectedBrokerID: firstBrokerID
    )
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(firstSnapshot)
    )
    #expect(!state.rows.isEmpty)

    state = TopicOutlineFeature.State(
      expectedBrokerID: secondBrokerID
    )

    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(.empty)
    )
    #expect(state.expectedBrokerID == secondBrokerID)

    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(firstSnapshot)
    )
    #expect(state.snapshot == .empty)
    #expect(state.rows.isEmpty)
    #expect(state.selectedTopic == nil)

    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(secondSnapshot)
    )
    #expect(state.snapshot == secondSnapshot)
    #expect(state.rows.map(\.fullTopic) == ["public"])
    #expect(state.selectedTopic == nil)
  }

  @Test("Rows expose descendant counts and latest delivery context")
  func contextualRowMetadata() async throws {
    let ingestion = makeIngestion(brokerID: UUID())
    let epoch = ConnectionEpochID()
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 1,
        topic: "root",
        payload: Data("42".utf8),
        qos: .exactlyOnce,
        retained: true,
        receivedAt: 1
      )
    )
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 2,
        topic: "root/child",
        payload: Data(#"{"ok":true}"#.utf8),
        qos: .atMostOnce,
        retained: false,
        receivedAt: 2
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State(expandedTopics: ["root"])
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )

    let root = try #require(
      state.rows.first { $0.fullTopic == "root" }
    )
    #expect(root.descendantValueTopicCount == 1)
    #expect(root.descendantMessageCount == 1)
    #expect(root.retained)
    #expect(root.qos == .exactlyOnce)
    #expect(root.payloadSummary?.display == "42")
    #expect(root.payloadSummary?.kind == .scalar)

    let child = try #require(
      state.rows.first { $0.fullTopic == "root/child" }
    )
    #expect(!child.retained)
    #expect(child.qos == .atMostOnce)
    #expect(child.payloadSummary?.kind == .json)
  }

  @Test("Sort modes use deterministic identity-preserving tie breakers")
  func deterministicSortModes() async throws {
    let brokerID = UUID()
    let ingestion = makeIngestion(brokerID: brokerID)
    let epoch = ConnectionEpochID()
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 1,
        topic: "root/zulu/leaf",
        receivedAt: 10
      )
    )
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 2,
        topic: "root/alpha",
        receivedAt: 20
      )
    )
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 3,
        topic: "root/zulu/second",
        receivedAt: 30
      )
    )
    await ingestion.ingest(
      .outlineFixture(
        epoch: epoch,
        ordinal: 4,
        topic: "root/alpha",
        receivedAt: 40
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State(expandedTopics: ["root"])
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )

    let expected: [BrokerTopicSortMode: [String]] = [
      .name: ["root/alpha", "root/zulu"],
      .recentActivity: ["root/alpha", "root/zulu"],
      .descendantMessages: ["root/zulu", "root/alpha"],
      .descendantTopics: ["root/zulu", "root/alpha"],
    ]
    let identities = Set(
      state.rows.filter { $0.depth == 1 }.map(\.id)
    )

    for mode in BrokerTopicSortMode.allCases {
      TopicOutlineFeature.reduce(
        state: &state,
        intent: .setSortMode(mode)
      )
      #expect(
        state.rows.filter { $0.depth == 1 }.map(\.fullTopic)
          == expected[mode]
      )
      #expect(
        Set(state.rows.filter { $0.depth == 1 }.map(\.id))
          == identities
      )
    }
  }

  @Test("Freeze bounds pending changes and Jump to Live adopts only newest")
  func boundedFreezeAndAtomicJumpToLive() {
    var state = TopicOutlineFeature.State(pendingChangeLimit: 999)
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(.outlineFixture(revision: 1, messages: 10))
    )
    TopicOutlineFeature.reduce(state: &state, intent: .freezeView)

    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(.outlineFixture(revision: 2, messages: 11))
    )
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(.outlineFixture(revision: 50, messages: 5_000))
    )

    #expect(state.isFrozen)
    #expect(state.snapshot.revision == 1)
    #expect(state.pendingChangeCount == 999)
    #expect(state.pendingChangeCountIsCapped)

    TopicOutlineFeature.reduce(state: &state, intent: .jumpToLive)

    #expect(!state.isFrozen)
    #expect(state.snapshot.revision == 50)
    #expect(state.pendingChangeCount == 0)
    #expect(!state.pendingChangeCountIsCapped)
  }

  @Test("Empty MQTT levels remain separately identifiable rows")
  func emptyLevelsAreDistinguishable() async {
    let brokerID = UUID()
    let ingestion = makeIngestion(brokerID: brokerID)
    await ingestion.ingest(
      .outlineFixture(
        epoch: ConnectionEpochID(),
        ordinal: 1,
        topic: "/root//value",
        receivedAt: 1
      )
    )
    let snapshot = await ingestion.flush()
    var state = TopicOutlineFeature.State(
      expandedTopics: ["", "/root", "/root/"]
    )
    TopicOutlineFeature.reduce(
      state: &state,
      action: .snapshotReceived(snapshot)
    )

    let emptyRows = state.rows.filter(\.level.isEmpty)
    #expect(emptyRows.map(\.fullTopic) == ["", "/root/"])
    #expect(Set(emptyRows.map(\.id)).count == 2)
    #expect(
      emptyRows.map(\.id)
        == [
          BrokerTopicID(brokerID: brokerID, fullTopic: ""),
          BrokerTopicID(brokerID: brokerID, fullTopic: "/root/"),
        ]
    )
  }

  private func makeIngestion(
    brokerID: UUID,
    maximumPayloadSummaryCharacters: Int = 256
  ) -> BrokerFeedIngestion {
    BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: "source",
      historyWriter: DisabledBrokerHistoryWriter(),
      policy: .init(
        historyBatchSize: 64,
        historyFlushIntervalSeconds: 60,
        maximumSnapshotRate: 10,
        maximumPayloadSummaryCharacters:
          maximumPayloadSummaryCharacters
      )
    )
  }
}

extension BrokerInboundMessage {
  fileprivate static func outlineFixture(
    epoch: ConnectionEpochID,
    ordinal: UInt64,
    topic: String,
    payload: Data = Data("value".utf8),
    qos: MQTTQualityOfService = .atLeastOnce,
    retained: Bool = true,
    receivedAt: Int64
  ) -> Self {
    Self(
      connectionEpoch: epoch,
      ordinal: ordinal,
      topic: topic,
      payload: payload,
      qos: qos,
      retained: retained,
      duplicate: false,
      receivedAtMicroseconds: receivedAt
    )
  }
}

extension BrokerTopicTreeSnapshot {
  fileprivate static func outlineFixture(
    revision: UInt64,
    messages: UInt64
  ) -> Self {
    Self(
      revision: revision,
      roots: [],
      totalMessageCount: messages,
      valueTopicCount: 0,
      historyIsHealthy: true,
      unpersistedMessageCount: 0
    )
  }
}
