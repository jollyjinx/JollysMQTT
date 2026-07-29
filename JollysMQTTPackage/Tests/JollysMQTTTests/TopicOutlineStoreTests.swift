import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTT

@Suite("Topic outline store")
@MainActor
struct TopicOutlineStoreTests {
  @Test("Main-actor state accepts newest revisions and rejects stale delivery")
  func newestRevisionWins() async {
    let feed = TopicSnapshotFeed()
    let store = TopicOutlineStore(feed: feed)
    let observation = Task {
      await store.observe()
    }
    await feed.emit(.fixture(revision: 3, messages: 30))
    while store.snapshot.revision < 3 {
      await Task.yield()
    }

    await feed.emit(.fixture(revision: 2, messages: 20))
    await Task.yield()

    #expect(store.snapshot.revision == 3)
    #expect(store.snapshot.totalMessageCount == 30)
    observation.cancel()
    await feed.finish()
    await observation.value
  }

  @Test("Resetting for another broker rejects a queued prior snapshot")
  func brokerResetRejectsQueuedSnapshot() async {
    let firstBrokerID = UUID()
    let secondBrokerID = UUID()
    let firstSnapshot = await makeSnapshot(
      brokerID: firstBrokerID,
      topic: "private/first"
    )
    let secondSnapshot = await makeSnapshot(
      brokerID: secondBrokerID,
      topic: "public/second"
    )
    let store = TopicOutlineStore(feed: TopicSnapshotFeed())
    store.restorePresentation(
      selectedTopic: "private/first",
      expandedTopics: ["private"],
      searchText: "",
      sortMode: .name,
      expectedBrokerID: firstBrokerID
    )
    store.receive(firstSnapshot)
    #expect(!store.state.rows.isEmpty)

    store.restorePresentation(
      selectedTopic: nil,
      expandedTopics: [],
      searchText: "",
      sortMode: .name,
      expectedBrokerID: secondBrokerID
    )
    store.receive(.empty)
    store.receive(firstSnapshot)

    #expect(store.state.expectedBrokerID == secondBrokerID)
    #expect(store.snapshot == .empty)
    #expect(store.state.rows.isEmpty)
    #expect(store.state.selectedTopic == nil)

    store.receive(secondSnapshot)

    #expect(store.snapshot == secondSnapshot)
    #expect(store.state.rows.map(\.fullTopic) == ["public"])
    #expect(store.state.selectedTopic == nil)
  }

  private func makeSnapshot(
    brokerID: UUID,
    topic: String
  ) async -> BrokerTopicTreeSnapshot {
    let ingestion = BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: "source",
      historyWriter: DisabledBrokerHistoryWriter()
    )
    await ingestion.ingest(
      BrokerInboundMessage(
        connectionEpoch: ConnectionEpochID(),
        ordinal: 1,
        topic: topic,
        payload: Data("value".utf8),
        qos: .atMostOnce,
        retained: false,
        duplicate: false,
        receivedAtMicroseconds: 1
      )
    )
    return await ingestion.flush()
  }
}

private actor TopicSnapshotFeed: BrokerFeedLeaseControlling {
  private let stream: AsyncStream<BrokerTopicTreeSnapshot>
  private let continuation: AsyncStream<BrokerTopicTreeSnapshot>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: BrokerTopicTreeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
  }

  func topicSnapshots() -> AsyncStream<BrokerTopicTreeSnapshot> {
    stream
  }

  func emit(_ snapshot: BrokerTopicTreeSnapshot) {
    continuation.yield(snapshot)
  }

  func finish() {
    continuation.finish()
  }

  func snapshots() -> AsyncStream<BrokerFeedSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: BrokerFeedSnapshot.self
    )
    continuation.finish()
    return stream
  }

  func connect(_ configuration: BrokerFeedConfiguration) {}
  func retry() {}
  func cancel() {}
  func setSceneActive(_ isActive: Bool) {}
  func release() {}
}

extension BrokerTopicTreeSnapshot {
  fileprivate static func fixture(
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
