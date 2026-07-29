import Foundation
import JollysMQTTCore

/// A domain revision independent of CloudKit change tags and wall-clock time.
///
/// UUID canonical text has the same ordering as its 16 network-order bytes,
/// making the tie-breaker stable across processes, architectures, and devices.
public struct ProfileLogicalRevision:
  Codable, Hashable, Comparable, Sendable
{
  public let counter: UInt64
  public let installationID: UUID

  public init(counter: UInt64, installationID: UUID) {
    self.counter = counter
    self.installationID = installationID
  }

  public static func < (
    lhs: ProfileLogicalRevision,
    rhs: ProfileLogicalRevision
  ) -> Bool {
    if lhs.counter != rhs.counter {
      return lhs.counter < rhs.counter
    }
    return lhs.installationID.uuidString
      < rhs.installationID.uuidString
  }

  /// Receiver-independent revision used when decoding a pre-revision v1
  /// profile document or encrypted envelope.
  public static let legacy = ProfileLogicalRevision(
    counter: 0,
    installationID: UUID(
      uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
  )
}

public struct ProfileContentRegister:
  Codable, Hashable, Sendable
{
  public let value: BrokerProfile
  public let revision: ProfileLogicalRevision

  public init(
    value: BrokerProfile,
    revision: ProfileLogicalRevision
  ) {
    self.value = value
    self.revision = revision
  }
}

public struct ProfileRankRegister:
  Codable, Hashable, Sendable
{
  public let value: Int64
  public let revision: ProfileLogicalRevision

  public init(
    value: Int64,
    revision: ProfileLogicalRevision
  ) {
    self.value = value
    self.revision = revision
  }
}

/// One convergent record per profile UUID.
///
/// A tombstone is permanent for its UUID. Its revision records when deletion
/// was observed, but a later live register never revives the same identity.
public struct ProfileReplicaRecord:
  Codable, Hashable, Identifiable, Sendable
{
  public let id: BrokerProfile.ID
  public let content: ProfileContentRegister?
  public let rank: ProfileRankRegister?
  public let tombstone: ProfileLogicalRevision?

  public init(
    id: BrokerProfile.ID,
    content: ProfileContentRegister?,
    rank: ProfileRankRegister?,
    tombstone: ProfileLogicalRevision?
  ) {
    self.id = id
    self.content = content
    self.rank = rank
    self.tombstone = tombstone
  }

  public var visibleProfile: RankedBrokerProfile? {
    guard tombstone == nil, let content, let rank else {
      return nil
    }
    return RankedBrokerProfile(
      profile: content.value,
      reorderRank: rank.value
    )
  }

  public var greatestObservedCounter: UInt64 {
    [
      content?.revision.counter,
      rank?.revision.counter,
      tombstone?.counter,
    ].compactMap(\.self).max() ?? 0
  }
}

public enum ProfileReplicaError: Error, Equatable, Sendable {
  case duplicateRecord(BrokerProfile.ID)
  case mismatchedProfileID(BrokerProfile.ID)
  case invalidProfile(BrokerProfile.ID)
  case incompleteLiveRecord(BrokerProfile.ID)
  case duplicateVisibleProfile(BrokerProfile.ID)
  case reusesDeletedProfileID(BrokerProfile.ID)
  case conflictingContentRevision(
    BrokerProfile.ID,
    ProfileLogicalRevision
  )
  case conflictingRankRevision(
    BrokerProfile.ID,
    ProfileLogicalRevision
  )
  case revisionCounterExhausted
}

/// Pure, deterministic profile replica state. It intentionally contains no
/// CloudKit identifiers, change tags, modification dates, or credentials.
public struct ProfileReplica: Codable, Equatable, Sendable {
  public let records: [ProfileReplicaRecord]

  public init(records: [ProfileReplicaRecord] = []) throws {
    var seen: Set<BrokerProfile.ID> = []
    for record in records {
      guard seen.insert(record.id).inserted else {
        throw ProfileReplicaError.duplicateRecord(record.id)
      }
      if let content = record.content {
        guard content.value.id == record.id else {
          throw ProfileReplicaError.mismatchedProfileID(record.id)
        }
        guard content.value.validationIssues.isEmpty else {
          throw ProfileReplicaError.invalidProfile(record.id)
        }
      }
      if record.tombstone == nil,
        record.content == nil || record.rank == nil
      {
        throw ProfileReplicaError.incompleteLiveRecord(record.id)
      }
    }
    self.records = records.map { record in
      guard record.tombstone != nil else { return record }
      return ProfileReplicaRecord(
        id: record.id,
        content: nil,
        rank: nil,
        tombstone: record.tombstone
      )
    }.sorted(by: Self.recordOrder)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(
      keyedBy: CodingKeys.self
    )
    let decoded = try container.decode(
      [ProfileReplicaRecord].self,
      forKey: .records
    )
    try self.init(records: decoded)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(
      keyedBy: CodingKeys.self
    )
    try container.encode(records, forKey: .records)
  }

  public var visibleProfiles: [RankedBrokerProfile] {
    records.compactMap(\.visibleProfile).sortedForReplicaDisplay
  }

  public var greatestObservedCounter: UInt64 {
    records.map(\.greatestObservedCounter).max() ?? 0
  }

  public func record(
    id: BrokerProfile.ID
  ) -> ProfileReplicaRecord? {
    records.first { $0.id == id }
  }

  /// Applies one local user mutation. Every changed register receives the
  /// same new revision, strictly beyond every counter this replica observed.
  public func applyingLocalSnapshot(
    _ profiles: [RankedBrokerProfile],
    installationID: UUID
  ) throws -> ProfileReplica {
    var incoming: [BrokerProfile.ID: RankedBrokerProfile] = [:]
    for profile in profiles {
      guard incoming[profile.id] == nil else {
        throw ProfileReplicaError.duplicateVisibleProfile(profile.id)
      }
      guard profile.profile.validationIssues.isEmpty else {
        throw ProfileReplicaError.invalidProfile(profile.id)
      }
      incoming[profile.id] = profile
    }

    let existing = Dictionary(
      uniqueKeysWithValues: records.map { ($0.id, $0) }
    )
    var hasChanges = false
    for profile in profiles {
      if let old = existing[profile.id] {
        if old.tombstone != nil {
          throw ProfileReplicaError.reusesDeletedProfileID(profile.id)
        }
        hasChanges =
          hasChanges
          || old.content?.value != profile.profile
          || old.rank?.value != profile.reorderRank
      } else {
        hasChanges = true
      }
    }
    hasChanges =
      hasChanges
      || records.contains {
        $0.tombstone == nil && incoming[$0.id] == nil
      }
    guard hasChanges else { return self }
    guard greatestObservedCounter < UInt64.max else {
      throw ProfileReplicaError.revisionCounterExhausted
    }

    let revision = ProfileLogicalRevision(
      counter: greatestObservedCounter + 1,
      installationID: installationID
    )
    var updated: [ProfileReplicaRecord] = []
    updated.reserveCapacity(max(records.count, profiles.count))

    for old in records {
      guard let incomingProfile = incoming.removeValue(forKey: old.id)
      else {
        if old.tombstone != nil {
          updated.append(old)
        } else {
          updated.append(
            ProfileReplicaRecord(
              id: old.id,
              content: nil,
              rank: nil,
              tombstone: revision
            )
          )
        }
        continue
      }

      let content =
        old.content?.value == incomingProfile.profile
        ? old.content
        : ProfileContentRegister(
          value: incomingProfile.profile,
          revision: revision
        )
      let rank =
        old.rank?.value == incomingProfile.reorderRank
        ? old.rank
        : ProfileRankRegister(
          value: incomingProfile.reorderRank,
          revision: revision
        )
      updated.append(
        ProfileReplicaRecord(
          id: old.id,
          content: content,
          rank: rank,
          tombstone: nil
        )
      )
    }

    for incomingProfile in incoming.values {
      updated.append(
        ProfileReplicaRecord(
          id: incomingProfile.id,
          content: ProfileContentRegister(
            value: incomingProfile.profile,
            revision: revision
          ),
          rank: ProfileRankRegister(
            value: incomingProfile.reorderRank,
            revision: revision
          ),
          tombstone: nil
        )
      )
    }
    return try ProfileReplica(records: updated)
  }

  public func merging(
    _ other: ProfileReplica
  ) throws -> ProfileReplica {
    var merged = Dictionary(
      uniqueKeysWithValues: records.map { ($0.id, $0) }
    )
    for remote in other.records {
      guard let local = merged[remote.id] else {
        merged[remote.id] = remote
        continue
      }
      merged[remote.id] = ProfileReplicaRecord(
        id: local.id,
        content: try Self.latestContent(
          local.content,
          remote.content,
          id: local.id
        ),
        rank: try Self.latestRank(
          local.rank,
          remote.rank,
          id: local.id
        ),
        tombstone: Self.latestRevision(
          local.tombstone,
          remote.tombstone
        )
      )
    }
    return try ProfileReplica(records: Array(merged.values))
  }

  private static func latestContent(
    _ lhs: ProfileContentRegister?,
    _ rhs: ProfileContentRegister?,
    id: BrokerProfile.ID
  ) throws -> ProfileContentRegister? {
    switch (lhs, rhs) {
    case (.none, .none):
      return nil
    case (.some(let value), .none), (.none, .some(let value)):
      return value
    case (.some(let lhs), .some(let rhs)):
      if lhs.revision == rhs.revision, lhs.value != rhs.value {
        throw ProfileReplicaError.conflictingContentRevision(
          id,
          lhs.revision
        )
      }
      return lhs.revision < rhs.revision ? rhs : lhs
    }
  }

  private static func latestRank(
    _ lhs: ProfileRankRegister?,
    _ rhs: ProfileRankRegister?,
    id: BrokerProfile.ID
  ) throws -> ProfileRankRegister? {
    switch (lhs, rhs) {
    case (.none, .none):
      return nil
    case (.some(let value), .none), (.none, .some(let value)):
      return value
    case (.some(let lhs), .some(let rhs)):
      if lhs.revision == rhs.revision, lhs.value != rhs.value {
        throw ProfileReplicaError.conflictingRankRevision(
          id,
          lhs.revision
        )
      }
      return lhs.revision < rhs.revision ? rhs : lhs
    }
  }

  private static func latestRevision(
    _ lhs: ProfileLogicalRevision?,
    _ rhs: ProfileLogicalRevision?
  ) -> ProfileLogicalRevision? {
    switch (lhs, rhs) {
    case (.none, .none):
      return nil
    case (.some(let value), .none), (.none, .some(let value)):
      return value
    case (.some(let lhs), .some(let rhs)):
      return max(lhs, rhs)
    }
  }

  private static func recordOrder(
    _ lhs: ProfileReplicaRecord,
    _ rhs: ProfileReplicaRecord
  ) -> Bool {
    lhs.id.uuidString < rhs.id.uuidString
  }

  private enum CodingKeys: String, CodingKey {
    case records
  }
}

extension Array where Element == RankedBrokerProfile {
  fileprivate var sortedForReplicaDisplay: Self {
    sorted {
      if $0.reorderRank == $1.reorderRank {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.reorderRank < $1.reorderRank
    }
  }
}
