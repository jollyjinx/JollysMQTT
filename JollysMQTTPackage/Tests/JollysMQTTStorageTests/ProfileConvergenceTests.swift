import Foundation
import JollysMQTTCore
import Testing

@testable import JollysMQTTStorage

@Suite("Profile replica convergence")
struct ProfileConvergenceTests {
  private let installationA = UUID(
    uuidString: "00000000-0000-0000-0000-00000000000A"
  )!
  private let installationB = UUID(
    uuidString: "00000000-0000-0000-0000-00000000000B"
  )!
  private let profileID = UUID(
    uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
  )!

  @Test("Equal-counter content edits use installation ID as the deterministic tie-breaker")
  func equalCounterContentEditsConverge() throws {
    let a = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "A"),
          contentRevision: revision(7, installationA),
          rank: 1_024,
          rankRevision: revision(1, installationA)
        )
      ]
    )
    let b = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "B"),
          contentRevision: revision(7, installationB),
          rank: 1_024,
          rankRevision: revision(1, installationA)
        )
      ]
    )

    #expect(try a.merging(b) == b.merging(a))
    #expect(try a.merging(b).visibleProfiles.map(\.profile.name) == ["B"])
  }

  @Test("Unrelated edits survive a merge")
  func unrelatedEditsSurvive() throws {
    let secondID = UUID(
      uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    let a = try ProfileReplica(
      records: [
        record(
          profile: profile(id: profileID, name: "First"),
          contentRevision: revision(3, installationA),
          rank: 1_024,
          rankRevision: revision(3, installationA)
        )
      ]
    )
    let b = try ProfileReplica(
      records: [
        record(
          profile: profile(id: secondID, name: "Second"),
          contentRevision: revision(5, installationB),
          rank: 2_048,
          rankRevision: revision(5, installationB)
        )
      ]
    )

    let merged = try a.merging(b)

    #expect(merged.visibleProfiles.map(\.profile.name) == ["First", "Second"])
  }

  @Test("A reorder and a concurrent content edit update independent registers")
  func reorderDoesNotOverwriteContent() throws {
    let baseline = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "Original"),
          contentRevision: revision(2, installationA),
          rank: 1_024,
          rankRevision: revision(2, installationA)
        )
      ]
    )
    let contentEdit = try baseline.applyingLocalSnapshot(
      [
        RankedBrokerProfile(
          profile: profile(name: "Edited"),
          reorderRank: 1_024
        )
      ],
      installationID: installationA
    )
    let reorder = try baseline.applyingLocalSnapshot(
      [
        RankedBrokerProfile(
          profile: baseline.visibleProfiles[0].profile,
          reorderRank: 9_999
        )
      ],
      installationID: installationB
    )

    let merged = try contentEdit.merging(reorder)
    let visible = try #require(merged.visibleProfiles.first)

    #expect(contentEdit.visibleProfiles.map(\.profile.name) == ["Edited"])
    #expect(reorder.visibleProfiles.map(\.profile.name) == ["Original"])
    #expect(
      contentEdit.records[0].content?.revision
        == revision(3, installationA)
    )
    #expect(
      reorder.records[0].content?.revision
        == revision(2, installationA)
    )
    #expect(
      merged.records[0].content?.revision
        == revision(3, installationA)
    )
    #expect(visible.profile.name == "Edited")
    #expect(visible.reorderRank == 9_999)
  }

  @Test("Each local mutation advances beyond the greatest observed counter")
  func localMutationAdvancesGlobalCounter() throws {
    let firstID = profileID
    let secondID = UUID(
      uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    let remote = try ProfileReplica(
      records: [
        record(
          profile: profile(id: firstID, name: "First"),
          contentRevision: revision(40, installationB),
          rank: 1_024,
          rankRevision: revision(3, installationB)
        ),
        record(
          profile: profile(id: secondID, name: "Second"),
          contentRevision: revision(2, installationB),
          rank: 2_048,
          rankRevision: revision(55, installationB)
        ),
      ]
    )

    let changed = try remote.applyingLocalSnapshot(
      [
        RankedBrokerProfile(
          profile: profile(id: firstID, name: "Locally edited"),
          reorderRank: 1_024
        ),
        RankedBrokerProfile(
          profile: profile(id: secondID, name: "Second"),
          reorderRank: 2_048
        ),
      ],
      installationID: installationA
    )
    let edited = try #require(changed.record(id: firstID))

    #expect(edited.content?.revision == revision(56, installationA))
    #expect(changed.greatestObservedCounter == 56)
  }

  @Test("A tombstone prevents a stale device from resurrecting a profile")
  func tombstonePreventsStaleResurrection() throws {
    let live = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "Live"),
          contentRevision: revision(9, installationA),
          rank: 1_024,
          rankRevision: revision(9, installationA)
        )
      ]
    )
    let deleted = try live.applyingLocalSnapshot(
      [],
      installationID: installationB
    )

    let converged = try deleted.merging(live)

    #expect(converged.visibleProfiles.isEmpty)
    #expect(converged.records.count == 1)
    #expect(converged.records[0].tombstone != nil)
    #expect(try converged.merging(live) == converged)
    let invalidLaterLive = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "Later stale live edit"),
          contentRevision: revision(999, installationA),
          rank: 1_024,
          rankRevision: revision(999, installationA)
        )
      ]
    )
    #expect(
      try converged.merging(invalidLaterLive).visibleProfiles.isEmpty
    )
    #expect(throws: ProfileReplicaError.reusesDeletedProfileID(profileID)) {
      try converged.applyingLocalSnapshot(
        [
          RankedBrokerProfile(
            profile: profile(name: "Forbidden recreation"),
            reorderRank: 1_024
          )
        ],
        installationID: installationA
      )
    }
  }

  @Test("Revision counter exhaustion fails instead of wrapping")
  func revisionCounterExhaustionFails() throws {
    let exhausted = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "Exhausted"),
          contentRevision: revision(UInt64.max, installationA),
          rank: 1_024,
          rankRevision: revision(1, installationA)
        )
      ]
    )

    #expect(throws: ProfileReplicaError.revisionCounterExhausted) {
      try exhausted.applyingLocalSnapshot(
        [
          RankedBrokerProfile(
            profile: profile(name: "Cannot mutate"),
            reorderRank: 1_024
          )
        ],
        installationID: installationA
      )
    }
  }

  @Test("Merge is idempotent, commutative, and associative")
  func mergeLaws() throws {
    let base = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "Base"),
          contentRevision: revision(1, installationA),
          rank: 1_024,
          rankRevision: revision(1, installationA)
        )
      ]
    )
    let a = try base.applyingLocalSnapshot(
      [
        RankedBrokerProfile(
          profile: profile(name: "A"),
          reorderRank: 1_024
        )
      ],
      installationID: installationA
    )
    let b = try base.applyingLocalSnapshot(
      [
        RankedBrokerProfile(
          profile: profile(name: "Base"),
          reorderRank: 8_192
        )
      ],
      installationID: installationB
    )
    let c = try base.applyingLocalSnapshot(
      [],
      installationID: installationB
    )

    #expect(try a.merging(a) == a)
    #expect(try a.merging(b) == b.merging(a))
    #expect(
      try a.merging(b).merging(c)
        == a.merging(b.merging(c))
    )
  }

  @Test("Divergent values at one identical revision are rejected")
  func identicalRevisionForkIsRejected() throws {
    let sharedRevision = revision(7, installationA)
    let a = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "A"),
          contentRevision: sharedRevision,
          rank: 1_024,
          rankRevision: sharedRevision
        )
      ]
    )
    let b = try ProfileReplica(
      records: [
        record(
          profile: profile(name: "B"),
          contentRevision: sharedRevision,
          rank: 1_024,
          rankRevision: sharedRevision
        )
      ]
    )

    #expect(
      throws:
        ProfileReplicaError.conflictingContentRevision(
          profileID,
          sharedRevision
        )
    ) {
      try a.merging(b)
    }
    #expect(
      throws:
        ProfileReplicaError.conflictingContentRevision(
          profileID,
          sharedRevision
        )
    ) {
      try b.merging(a)
    }
  }

  @Test("Decoding revalidates records and rejects duplicate identities")
  func decodingRevalidatesRecords() throws {
    struct UnvalidatedReplica: Encodable {
      let records: [ProfileReplicaRecord]
    }
    let value = record(
      profile: profile(name: "Duplicate"),
      contentRevision: revision(1, installationA),
      rank: 1_024,
      rankRevision: revision(1, installationA)
    )
    let bytes = try JSONEncoder().encode(
      UnvalidatedReplica(records: [value, value])
    )

    #expect(throws: ProfileReplicaError.duplicateRecord(profileID)) {
      try JSONDecoder().decode(ProfileReplica.self, from: bytes)
    }
  }

  @Test("The local-first repository persists the merged content and rank registers")
  func localFirstRepositoryMergesReplicaRecords() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = LocalProfileRepository(
      fileURL: fileURL,
      installationID: installationA
    )
    let original = profile(name: "Original")
    try await local.replaceAll(
      [RankedBrokerProfile(profile: original, reorderRank: 1_024)]
    )
    let baseline = try await local.loadReplica()
    let remotelyEdited = BrokerProfile(
      id: original.id,
      name: "Remote edit",
      host: original.host,
      port: original.port,
      transport: original.transport,
      username: original.username,
      clientIDPolicy: original.clientIDPolicy,
      cleanSession: original.cleanSession,
      keepAliveSeconds: original.keepAliveSeconds,
      reconnectPolicy: original.reconnectPolicy,
      subscriptions: original.subscriptions
    )
    let remote = try baseline.applyingLocalSnapshot(
      [
        RankedBrokerProfile(
          profile: remotelyEdited,
          reorderRank: 1_024
        )
      ],
      installationID: installationB
    )
    try await local.replaceAll(
      [RankedBrokerProfile(profile: original, reorderRank: 9_999)]
    )
    let sync = ImmediateProfileSync(
      exchange: ProfileSyncExchange(remoteRecords: remote.records)
    )
    let repository = LocalFirstProfileRepository(local: local, sync: sync)

    _ = try await repository.synchronize()
    let merged = try await repository.load()

    #expect(merged.map(\.profile.name) == ["Remote edit"])
    #expect(merged.map(\.reorderRank) == [9_999])
    #expect(await sync.latestSnapshot()?.replicaRecords != nil)
  }

  @Test("A local deletion persists its tombstone and rejects UUID reuse")
  func localDeletionPersistsTombstone() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "profiles.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = LocalProfileRepository(
      fileURL: fileURL,
      installationID: installationA
    )
    let deletedProfile = RankedBrokerProfile(
      profile: profile(name: "Delete me"),
      reorderRank: 1_024
    )
    try await local.replaceAll([deletedProfile])
    try await local.replaceAll([])

    let replica = try await LocalProfileRepository(
      fileURL: fileURL,
      installationID: installationA
    ).loadReplica()

    #expect(replica.visibleProfiles.isEmpty)
    #expect(replica.records.first?.tombstone != nil)
    await #expect(
      throws: ProfileReplicaError.reusesDeletedProfileID(profileID)
    ) {
      try await local.replaceAll([deletedProfile])
    }
  }

  private func revision(
    _ counter: UInt64,
    _ installationID: UUID
  ) -> ProfileLogicalRevision {
    ProfileLogicalRevision(
      counter: counter,
      installationID: installationID
    )
  }

  private func record(
    profile: BrokerProfile,
    contentRevision: ProfileLogicalRevision,
    rank: Int64,
    rankRevision: ProfileLogicalRevision
  ) -> ProfileReplicaRecord {
    ProfileReplicaRecord(
      id: profile.id,
      content: ProfileContentRegister(
        value: profile,
        revision: contentRevision
      ),
      rank: ProfileRankRegister(
        value: rank,
        revision: rankRevision
      ),
      tombstone: nil
    )
  }

  private func profile(
    id: UUID? = nil,
    name: String
  ) -> BrokerProfile {
    BrokerProfile(
      id: id ?? profileID,
      name: name,
      host: "broker.example",
      port: 8_883,
      transport: .tls,
      username: "operator",
      clientIDPolicy: .stableGenerated,
      cleanSession: true,
      keepAliveSeconds: 60,
      reconnectPolicy: .standard,
      subscriptions: [
        SubscriptionDefinition(filter: "site/#", qos: .atLeastOnce)
      ]
    )
  }
}

private actor ImmediateProfileSync: ProfileSyncing {
  private let exchange: ProfileSyncExchange
  private var snapshots: [ProfileSyncSnapshot] = []

  init(exchange: ProfileSyncExchange) {
    self.exchange = exchange
  }

  func status() -> ProfileSyncStatus {
    .available
  }

  func stageLocalProfiles(
    _ snapshot: ProfileSyncSnapshot
  ) -> ProfileSyncStatus {
    snapshots.append(snapshot)
    return .available
  }

  func synchronize() -> ProfileSyncExchange {
    exchange
  }

  func cancel() {}

  func latestSnapshot() -> ProfileSyncSnapshot? {
    snapshots.last
  }
}
