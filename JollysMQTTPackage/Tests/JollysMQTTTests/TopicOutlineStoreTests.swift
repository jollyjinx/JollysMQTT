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
