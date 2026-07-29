import Foundation
import JollysMQTTCore
import Testing

@Suite("Retained deletion scope")
struct RetainedDeletionScopeTests {
  @Test(
    "A selected subtree yields unique current local value topics in stable order"
  )
  func currentLocalValuesOnly() async {
    let brokerID = UUID()
    let ingestion = BrokerFeedIngestion(
      brokerID: brokerID,
      historySourceID: "scope",
      historyWriter: DisabledBrokerHistoryWriter()
    )
    let oldEpoch = ConnectionEpochID()
    await ingestion.beginConnectionEpoch(oldEpoch)
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: oldEpoch,
        ordinal: 1,
        topic: "plant"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: oldEpoch,
        ordinal: 2,
        topic: "plant/stale"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: oldEpoch,
        ordinal: 3,
        topic: "plant/current/z"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: oldEpoch,
        ordinal: 4,
        topic: "plant/current/a"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: oldEpoch,
        ordinal: 5,
        topic: "plantation/not-a-descendant"
      )
    )

    let currentEpoch = ConnectionEpochID()
    await ingestion.beginConnectionEpoch(currentEpoch)
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: currentEpoch,
        ordinal: 1,
        topic: "plant/current/z"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: currentEpoch,
        ordinal: 2,
        topic: "plant/current/a"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: currentEpoch,
        ordinal: 3,
        topic: "plant/current/a"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: currentEpoch,
        ordinal: 4,
        topic: "plant/current/ä"
      )
    )
    await ingestion.ingest(
      .retainedScopeFixture(
        epoch: currentEpoch,
        ordinal: 5,
        topic: "plant/current/é"
      )
    )
    let snapshot = await ingestion.flush()

    #expect(
      snapshot.locallyKnownCurrentValueTopics(
        in: BrokerTopicID(
          brokerID: brokerID,
          fullTopic: "plant"
        )
      )
        == [
          "plant/current/a",
          "plant/current/z",
          "plant/current/ä",
          "plant/current/é",
        ]
    )
    #expect(
      snapshot.locallyKnownCurrentValueTopics(
        in: BrokerTopicID(
          brokerID: UUID(),
          fullTopic: "plant"
        )
      ).isEmpty
    )
  }
}

extension BrokerInboundMessage {
  fileprivate static func retainedScopeFixture(
    epoch: ConnectionEpochID,
    ordinal: UInt64,
    topic: String
  ) -> Self {
    Self(
      connectionEpoch: epoch,
      ordinal: ordinal,
      topic: topic,
      payload: Data("value".utf8),
      qos: .atMostOnce,
      retained: false,
      duplicate: false,
      receivedAtMicroseconds: Int64(ordinal)
    )
  }
}
