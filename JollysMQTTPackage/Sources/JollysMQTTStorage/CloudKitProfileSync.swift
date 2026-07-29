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
      let envelope = EncryptedProfileEnvelope(
        version: EncryptedProfileEnvelope.currentVersion,
        rankedProfile: rankedProfile
      )
      let recordID = CKRecord.ID(
        recordName: rankedProfile.id.uuidString.lowercased(),
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

      let envelope: EncryptedProfileEnvelope
      do {
        envelope = try decoder.decode(
          EncryptedProfileEnvelope.self,
          from: data
        )
      } catch {
        throw ProfileSyncFailure(
          kind: .corruptRemotePayload,
          isRetryable: false
        )
      }
      guard envelope.version == EncryptedProfileEnvelope.currentVersion,
        envelope.rankedProfile.id == recordID,
        envelope.rankedProfile.profile.validationIssues.isEmpty
      else {
        throw ProfileSyncFailure(
          kind: .invalidRemoteProfile,
          isRetryable: false
        )
      }
      return envelope.rankedProfile
    }
  }

  private struct EncryptedProfileEnvelope: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let rankedProfile: RankedBrokerProfile
  }

  private actor CKSyncEngineProfileDelegate: CKSyncEngineDelegate {
    private let codec: CloudKitProfileRecordCodec
    private let stateStore: any ProfileSyncStateStoring

    private var stagedSnapshot: ProfileSyncSnapshot?
    private var fetchedProfiles: [BrokerProfile.ID: RankedBrokerProfile] = [:]
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
      if let operationFailure {
        self.operationFailure = nil
        throw operationFailure
      }
      guard !fetchedProfiles.isEmpty else {
        return .noChanges
      }

      var merged = Dictionary(
        uniqueKeysWithValues: (stagedSnapshot?.profiles ?? []).map { ($0.id, $0) }
      )
      merged.merge(fetchedProfiles) { _, remote in remote }
      fetchedProfiles.removeAll(keepingCapacity: true)
      return ProfileSyncExchange(
        remoteProfiles:
          Array(merged.values).sortedForProfileSync
      )
    }

    func record(for recordID: CKRecord.ID) throws -> CKRecord? {
      guard recordID.zoneID == codec.zoneID,
        let id = UUID(uuidString: recordID.recordName),
        let profile = stagedSnapshot?.profiles.first(
          where: { $0.id == id }
        )
      else {
        return nil
      }
      return try codec.encode(profile)
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
          do {
            let profile = try codec.decode(modification.record)
            fetchedProfiles[profile.id] = profile
          } catch let failure as ProfileSyncFailure {
            operationFailure = failure
          } catch {
            operationFailure = ProfileSyncFailure(
              kind: .corruptRemotePayload,
              isRetryable: false
            )
          }
        }

      case .sentRecordZoneChanges(let sent):
        if let failed = sent.failedRecordSaves.first {
          operationFailure = CloudKitProfileSync.classify(
            failed.error
          )
        } else if let error = sent.failedRecordDeletes.values.first {
          operationFailure = CloudKitProfileSync.classify(error)
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
        pendingRecordZoneChanges: snapshot.profiles.map {
          .saveRecord(
            CKRecord.ID(
              recordName: $0.id.uuidString.lowercased(),
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
