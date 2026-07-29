#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import JollysMQTTCore

  public struct CloudKitProfileSyncConfiguration: Equatable, Sendable {
    public let containerIdentifier: String
    public let zoneName: String
    public let recordType: String
    public let subscriptionID: String

    public init(
      containerIdentifier: String,
      zoneName: String,
      recordType: String = "EncryptedBrokerProfile",
      subscriptionID: String = "encrypted-broker-profiles-v1"
    ) {
      self.containerIdentifier = containerIdentifier
      self.zoneName = zoneName
      self.recordType = recordType
      self.subscriptionID = subscriptionID
    }
  }

  public actor CloudKitProfileSync: ProfileSyncing {
    private let engine: any ProfileSyncEngine
    private var currentStatus: ProfileSyncStatus = .available
    private var latestSynchronizationAttempt: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var synchronizationTail: Task<ProfileSyncExchange, any Error>?

    public init(engine: any ProfileSyncEngine) {
      self.engine = engine
    }

    public static func configured(
      _ configuration: CloudKitProfileSyncConfiguration,
      stateStore: any ProfileSyncStateStoring
    ) async throws -> CloudKitProfileSync {
      let driver = try await CKSyncEngineProfileDriver.make(
        configuration: configuration,
        stateStore: stateStore
      )
      return CloudKitProfileSync(engine: driver)
    }

    public func status() -> ProfileSyncStatus {
      currentStatus
    }

    public func stageLocalProfiles(
      _ snapshot: ProfileSyncSnapshot
    ) async -> ProfileSyncStatus {
      do {
        try await engine.stageLocalProfiles(snapshot)
        switch currentStatus {
        case .syncing, .retryScheduled, .failed:
          return currentStatus
        case .localOnly, .available:
          currentStatus = .available
        }
      } catch is CancellationError {
        return currentStatus
      } catch let failure as ProfileSyncFailure {
        currentStatus =
          failure.isRetryable ? .retryScheduled(failure) : .failed(failure)
      } catch {
        currentStatus = .retryScheduled(
          ProfileSyncFailure(
            kind: .internalFailure,
            isRetryable: true
          )
        )
      }
      return currentStatus
    }

    public func synchronize() async throws -> ProfileSyncExchange {
      try Task.checkCancellation()
      latestSynchronizationAttempt &+= 1
      let attempt = latestSynchronizationAttempt
      let startingCancellationGeneration = cancellationGeneration
      let predecessor = synchronizationTail
      let operationMayStartImmediately = predecessor == nil
      let engine = engine
      let operation = Task<ProfileSyncExchange, any Error> {
        if let predecessor {
          _ = try? await predecessor.value
        }
        try Task.checkCancellation()
        return try await engine.synchronize()
      }
      synchronizationTail = operation
      currentStatus = .syncing
      do {
        let exchange = try await withTaskCancellationHandler {
          try await operation.value
        } onCancel: {
          operation.cancel()
        }
        try Task.checkCancellation()
        if attempt == latestSynchronizationAttempt {
          currentStatus = .available
          synchronizationTail = nil
        }
        return exchange
      } catch is CancellationError {
        operation.cancel()
        if operationMayStartImmediately,
          startingCancellationGeneration == cancellationGeneration
        {
          await engine.cancel()
        }
        if attempt == latestSynchronizationAttempt {
          currentStatus = .available
          synchronizationTail = nil
        }
        throw CancellationError()
      } catch let failure as ProfileSyncFailure {
        if attempt == latestSynchronizationAttempt {
          currentStatus =
            failure.isRetryable ? .retryScheduled(failure) : .failed(failure)
          synchronizationTail = nil
        }
        throw failure
      } catch {
        let failure = CloudKitProfileSync.classify(error)
        if attempt == latestSynchronizationAttempt {
          currentStatus =
            failure.isRetryable ? .retryScheduled(failure) : .failed(failure)
          synchronizationTail = nil
        }
        throw failure
      }
    }

    public func cancel() async {
      cancellationGeneration &+= 1
      await engine.cancel()
      currentStatus = .available
    }

    fileprivate static func classify(
      _ error: any Error
    ) -> ProfileSyncFailure {
      guard let cloudError = error as? CKError else {
        return ProfileSyncFailure(
          kind: .internalFailure,
          isRetryable: true
        )
      }

      let retryAfter =
        (cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?
        .doubleValue
      switch cloudError.code {
      case .networkUnavailable, .networkFailure:
        return ProfileSyncFailure(
          kind: .offline,
          isRetryable: true,
          retryAfterSeconds: retryAfter
        )
      case .requestRateLimited, .serviceUnavailable, .zoneBusy:
        return ProfileSyncFailure(
          kind: .rateLimited,
          isRetryable: true,
          retryAfterSeconds: retryAfter
        )
      case .notAuthenticated, .missingEntitlement,
        .permissionFailure:
        return ProfileSyncFailure(
          kind: .unavailable,
          isRetryable: false
        )
      default:
        return ProfileSyncFailure(
          kind: .internalFailure,
          isRetryable: true,
          retryAfterSeconds: retryAfter
        )
      }
    }
  }

  struct CloudKitProfileRecordCodec: Sendable {
    static let encryptedPayloadKey = "profilePayload"

    let zoneID: CKRecordZone.ID
    let recordType: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(zoneName: String, recordType: String) {
      self.zoneID = CKRecordZone.ID(zoneName: zoneName)
      self.recordType = recordType
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      self.encoder = encoder
      self.decoder = JSONDecoder()
    }

    func encode(_ rankedProfile: RankedBrokerProfile) throws -> CKRecord {
      try encodeReplicaRecord(
        ProfileReplicaRecord(
          id: rankedProfile.id,
          content: ProfileContentRegister(
            value: rankedProfile.profile,
            revision: .legacy
          ),
          rank: ProfileRankRegister(
            value: rankedProfile.reorderRank,
            revision: .legacy
          ),
          tombstone: nil
        )
      )
    }

    func encodeReplicaRecord(
      _ replicaRecord: ProfileReplicaRecord
    ) throws -> CKRecord {
      let envelope = EncryptedProfileEnvelopeV2(
        version: EncryptedProfileEnvelopeV2.currentVersion,
        record: replicaRecord
      )
      let recordID = CKRecord.ID(
        recordName: replicaRecord.id.uuidString.lowercased(),
        zoneID: zoneID
      )
      let record = CKRecord(
        recordType: recordType,
        recordID: recordID
      )
      record.encryptedValues[Self.encryptedPayloadKey] =
        try encoder.encode(envelope)
      return record
    }

    func decode(_ record: CKRecord) throws -> RankedBrokerProfile {
      guard let visible = try decodeReplicaRecord(record).visibleProfile
      else {
        throw ProfileSyncFailure(
          kind: .invalidRemoteProfile,
          isRetryable: false
        )
      }
      return visible
    }

    func decodeReplicaRecord(
      _ record: CKRecord
    ) throws -> ProfileReplicaRecord {
      guard record.recordType == recordType,
        record.recordID.zoneID == zoneID,
        let recordID = UUID(uuidString: record.recordID.recordName),
        Set(record.allKeys()) == [
          Self.encryptedPayloadKey
        ],
        Set(record.encryptedValues.allKeys()) == [
          Self.encryptedPayloadKey
        ],
        record[Self.encryptedPayloadKey] == nil,
        let data =
          record.encryptedValues[Self.encryptedPayloadKey]
          as? Data
      else {
        throw ProfileSyncFailure(
          kind: .corruptRemotePayload,
          isRetryable: false
        )
      }

      let header: EncryptedProfileEnvelopeHeader
      do {
        header = try decoder.decode(
          EncryptedProfileEnvelopeHeader.self,
          from: data
        )
      } catch {
        throw ProfileSyncFailure(
          kind: .corruptRemotePayload,
          isRetryable: false
        )
      }

      let replicaRecord: ProfileReplicaRecord
      do {
        switch header.version {
        case 1:
          let legacy = try decoder.decode(
            EncryptedProfileEnvelopeV1.self,
            from: data
          )
          replicaRecord = ProfileReplicaRecord(
            id: legacy.rankedProfile.id,
            content: ProfileContentRegister(
              value: legacy.rankedProfile.profile,
              revision: .legacy
            ),
            rank: ProfileRankRegister(
              value: legacy.rankedProfile.reorderRank,
              revision: .legacy
            ),
            tombstone: nil
          )
        case EncryptedProfileEnvelopeV2.currentVersion:
          replicaRecord = try decoder.decode(
            EncryptedProfileEnvelopeV2.self,
            from: data
          ).record
        default:
          throw ProfileSyncFailure(
            kind: .corruptRemotePayload,
            isRetryable: false
          )
        }
      } catch let failure as ProfileSyncFailure {
        throw failure
      } catch {
        throw ProfileSyncFailure(
          kind: .corruptRemotePayload,
          isRetryable: false
        )
      }

      guard replicaRecord.id == recordID,
        let canonical = try? ProfileReplica(
          records: [replicaRecord]
        ).records.first
      else {
        throw ProfileSyncFailure(
          kind: .invalidRemoteProfile,
          isRetryable: false
        )
      }
      return canonical
    }
  }

  private struct EncryptedProfileEnvelopeHeader:
    Decodable, Sendable
  {
    let version: Int
  }

  private struct EncryptedProfileEnvelopeV1: Codable, Sendable {
    let version: Int
    let rankedProfile: RankedBrokerProfile
  }

  private struct EncryptedProfileEnvelopeV2: Codable, Sendable {
    static let currentVersion = 2

    let version: Int
    let record: ProfileReplicaRecord
  }

  struct CloudKitFailedProfileSave: Sendable {
    let record: CKRecord
    let error: CKError
  }

  actor CKSyncEngineProfileDelegate: CKSyncEngineDelegate {
    private let codec: CloudKitProfileRecordCodec
    private let stateStore: any ProfileSyncStateStoring

    private var stagedSnapshot: ProfileSyncSnapshot?
    private var fetchedRecords: [BrokerProfile.ID: ProfileReplicaRecord] = [:]
    private var transportBases: [BrokerProfile.ID: CKRecord] = [:]
    private var operationFailure: ProfileSyncFailure?

    init(
      codec: CloudKitProfileRecordCodec,
      stateStore: any ProfileSyncStateStoring
    ) {
      self.codec = codec
      self.stateStore = stateStore
    }

    func stage(_ snapshot: ProfileSyncSnapshot) {
      guard
        snapshot.generation
          >= (stagedSnapshot?.generation ?? 0)
      else { return }
      stagedSnapshot = snapshot
    }

    func beginOperation() {
      operationFailure = nil
    }

    func makeExchange() throws -> ProfileSyncExchange {
      try takeFetchedExchangeBeforeSend() ?? .noChanges
    }

    /// Drains fetched domain records before any send is allowed. The driver
    /// returns this exchange to the repository, which merges and re-stages the
    /// converged snapshot before a later send operation.
    func takeFetchedExchangeBeforeSend() throws -> ProfileSyncExchange? {
      if let operationFailure {
        self.operationFailure = nil
        throw operationFailure
      }
      guard !fetchedRecords.isEmpty else {
        return nil
      }

      let changes = fetchedRecords.values.sorted {
        $0.id.uuidString < $1.id.uuidString
      }
      fetchedRecords.removeAll(keepingCapacity: true)
      return ProfileSyncExchange(
        remoteRecords: changes
      )
    }

    func acceptFetchedRecord(_ record: CKRecord) {
      do {
        let replicaRecord = try codec.decodeReplicaRecord(record)
        fetchedRecords[replicaRecord.id] = replicaRecord
        transportBases[replicaRecord.id] = record
      } catch let failure as ProfileSyncFailure {
        recordOperationFailure(failure)
      } catch {
        recordOperationFailure(
          ProfileSyncFailure(
            kind: .corruptRemotePayload,
            isRetryable: false
          )
        )
      }
    }

    func acceptFailedRecordSaves(
      _ failures: [CloudKitFailedProfileSave]
    ) {
      for failed in failures.sorted(by: {
        $0.record.recordID.recordName
          < $1.record.recordID.recordName
      }) {
        if failed.error.code == .serverRecordChanged,
          let serverRecord =
            failed.error.userInfo[
              CKRecordChangedErrorServerRecordKey
            ] as? CKRecord
        {
          acceptFetchedRecord(serverRecord)
        } else {
          recordOperationFailure(
            CloudKitProfileSync.classify(failed.error)
          )
        }
      }
    }

    func record(for recordID: CKRecord.ID) throws -> CKRecord? {
      guard recordID.zoneID == codec.zoneID,
        let id = UUID(uuidString: recordID.recordName),
        let replicaRecord = try stagedRecords().first(
          where: { $0.id == id }
        )
      else {
        return nil
      }
      let encoded = try codec.encodeReplicaRecord(replicaRecord)
      guard let transportBase = transportBases[id] else {
        return encoded
      }
      transportBase.encryptedValues[
        CloudKitProfileRecordCodec.encryptedPayloadKey
      ] =
        encoded.encryptedValues[
          CloudKitProfileRecordCodec.encryptedPayloadKey
        ]
      return transportBase
    }

    private func stagedRecords() throws -> [ProfileReplicaRecord] {
      guard let stagedSnapshot else { return [] }
      if let records = stagedSnapshot.replicaRecords {
        return records
      }
      return try ProfileReplica(
        records: stagedSnapshot.profiles.map {
          ProfileReplicaRecord(
            id: $0.id,
            content: ProfileContentRegister(
              value: $0.profile,
              revision: .legacy
            ),
            rank: ProfileRankRegister(
              value: $0.reorderRank,
              revision: .legacy
            ),
            tombstone: nil
          )
        }
      ).records
    }

    func handleEvent(
      _ event: CKSyncEngine.Event,
      syncEngine: CKSyncEngine
    ) async {
      switch event {
      case .stateUpdate(let update):
        do {
          let data = try PropertyListEncoder().encode(
            update.stateSerialization
          )
          try await stateStore.save(data)
        } catch is CancellationError {
          operationFailure = ProfileSyncFailure(
            kind: .internalFailure,
            isRetryable: true
          )
        } catch {
          operationFailure = ProfileSyncFailure(
            kind: .internalFailure,
            isRetryable: true
          )
        }

      case .fetchedRecordZoneChanges(let changes):
        for modification in changes.modifications
        where modification.record.recordID.zoneID == codec.zoneID {
          acceptFetchedRecord(modification.record)
        }

      case .sentRecordZoneChanges(let sent):
        for saved in sent.savedRecords {
          if let id = UUID(uuidString: saved.recordID.recordName) {
            transportBases[id] = saved
          }
        }
        acceptFailedRecordSaves(
          sent.failedRecordSaves.map {
            CloudKitFailedProfileSave(
              record: $0.record,
              error: $0.error
            )
          }
        )
        for recordID in sent.failedRecordDeletes.keys.sorted(by: {
          $0.recordName < $1.recordName
        }) {
          if let error = sent.failedRecordDeletes[recordID] {
            recordOperationFailure(
              CloudKitProfileSync.classify(error)
            )
          }
        }

      case .sentDatabaseChanges(let sent):
        if let failed = sent.failedZoneSaves.first {
          operationFailure = CloudKitProfileSync.classify(
            failed.error
          )
        } else if let error = sent.failedZoneDeletes.values.first {
          operationFailure = CloudKitProfileSync.classify(error)
        }

      case .didFetchRecordZoneChanges(let finished):
        if let error = finished.error {
          operationFailure = CloudKitProfileSync.classify(error)
        }

      case .accountChange, .fetchedDatabaseChanges,
        .willFetchChanges, .willFetchRecordZoneChanges,
        .didFetchChanges, .willSendChanges, .didSendChanges:
        break
      @unknown default:
        break
      }
    }

    private func recordOperationFailure(
      _ failure: ProfileSyncFailure
    ) {
      if operationFailure == nil {
        operationFailure = failure
      }
    }

    func nextRecordZoneChangeBatch(
      _ context: CKSyncEngine.SendChangesContext,
      syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      await CKSyncEngine.RecordZoneChangeBatch(
        pendingChanges:
          syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
          },
        recordProvider: { [self] recordID in
          try? await record(for: recordID)
        }
      )
    }
  }

  private actor CKSyncEngineProfileDriver: ProfileSyncEngine {
    private let engine: CKSyncEngine
    private let delegate: CKSyncEngineProfileDelegate
    private let codec: CloudKitProfileRecordCodec

    private init(
      engine: CKSyncEngine,
      delegate: CKSyncEngineProfileDelegate,
      codec: CloudKitProfileRecordCodec
    ) {
      self.engine = engine
      self.delegate = delegate
      self.codec = codec
    }

    static func make(
      configuration: CloudKitProfileSyncConfiguration,
      stateStore: any ProfileSyncStateStoring
    ) async throws -> CKSyncEngineProfileDriver {
      let candidates = try await stateStore.loadCandidates()
      let selection = selectProfileSyncState(
        from: candidates,
        decode: { data in decodeState(data) }
      )
      if selection.usedBackup {
        try await stateStore.restoreBackup()
      }
      let codec = CloudKitProfileRecordCodec(
        zoneName: configuration.zoneName,
        recordType: configuration.recordType
      )
      let delegate = CKSyncEngineProfileDelegate(
        codec: codec,
        stateStore: stateStore
      )
      var engineConfiguration = CKSyncEngine.Configuration(
        database:
          CKContainer(
            identifier: configuration.containerIdentifier
          ).privateCloudDatabase,
        stateSerialization: selection.state,
        delegate: delegate
      )
      engineConfiguration.automaticallySync = true
      engineConfiguration.subscriptionID =
        configuration.subscriptionID
      let engine = CKSyncEngine(engineConfiguration)
      return CKSyncEngineProfileDriver(
        engine: engine,
        delegate: delegate,
        codec: codec
      )
    }

    func stageLocalProfiles(
      _ snapshot: ProfileSyncSnapshot
    ) async throws {
      try Task.checkCancellation()
      await delegate.stage(snapshot)
      engine.state.add(
        pendingDatabaseChanges: [
          .saveZone(CKRecordZone(zoneID: codec.zoneID))
        ]
      )
      engine.state.add(
        pendingRecordZoneChanges: (snapshot.replicaRecords?.map(\.id)
          ?? snapshot.profiles.map(\.id)).map {
            .saveRecord(
              CKRecord.ID(
                recordName: $0.uuidString.lowercased(),
                zoneID: codec.zoneID
              )
            )
          }
      )
    }

    func synchronize() async throws -> ProfileSyncExchange {
      try Task.checkCancellation()
      await delegate.beginOperation()
      do {
        try await engine.fetchChanges(
          CKSyncEngine.FetchChangesOptions(
            scope: .zoneIDs([codec.zoneID])
          )
        )
        try Task.checkCancellation()
        if let fetched =
          try await delegate.takeFetchedExchangeBeforeSend()
        {
          return fetched
        }
        try await engine.sendChanges(
          CKSyncEngine.SendChangesOptions(
            scope: .zoneIDs([codec.zoneID])
          )
        )
        try Task.checkCancellation()
        return try await delegate.makeExchange()
      } catch is CancellationError {
        await engine.cancelOperations()
        throw CancellationError()
      }
    }

    func cancel() async {
      await engine.cancelOperations()
    }

    private static func decodeState(
      _ data: Data
    ) -> CKSyncEngine.State.Serialization? {
      return try? PropertyListDecoder().decode(
        CKSyncEngine.State.Serialization.self,
        from: data
      )
    }
  }

  extension Array where Element == RankedBrokerProfile {
    fileprivate var sortedForProfileSync: Self {
      sorted {
        if $0.reorderRank == $1.reorderRank {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.reorderRank < $1.reorderRank
      }
    }
  }
#endif
