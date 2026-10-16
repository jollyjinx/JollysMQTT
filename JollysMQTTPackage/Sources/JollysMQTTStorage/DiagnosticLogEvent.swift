import Foundation
import JollysMQTTCore

/// Only allow-listed values cross the diagnostic boundary. Never pass raw
/// framework messages, profiles, endpoints, topics, payloads, or credentials.
public enum DiagnosticLogEvent: Sendable {
  case applicationStarted
  case connectionAttempt
  case connecting
  case subscribing
  case connected
  case connectionClosed
  case connectionCancelled
  case connectionFailed(BrokerFeedDiagnostic)
  case publishCompleted
  case publishFailed
  case historyRecovery(succeeded: Bool)
  case cloudKitFailure(operation: CloudKitOperation, code: Int, partialCodes: [Int])
  case cloudKitConflicts(count: Int)
  case profileSyncStatus(ProfileSyncStatus)

  public enum CloudKitOperation: String, Sendable {
    case fetch, send, saveState, saveZone, saveRecord, deleteRecord
  }

  var message: String {
    switch self {
    case .applicationStarted: "application.started"
    case .connectionAttempt: "connection.attempt"
    case .connecting: "connection.connecting"
    case .subscribing: "connection.subscribing"
    case .connected: "connection.connected"
    case .connectionClosed: "connection.closed"
    case .connectionCancelled: "connection.cancelled"
    case .connectionFailed(let diagnostic): "connection.failed \(diagnostic)"
    case .publishCompleted: "publish.completed"
    case .publishFailed: "publish.failed"
    case .historyRecovery(let succeeded): "history.recovery succeeded=\(succeeded)"
    case .cloudKitFailure(let operation, let code, let partialCodes):
      "cloudkit.\(operation.rawValue).failed code=\(code) partialCodes=\(partialCodes.prefix(32).sorted())"
    case .cloudKitConflicts(let count): "cloudkit.conflicts.merge count=\(count)"
    case .profileSyncStatus(let status):
      switch status {
      case .localOnly: "profiles.localOnly"
      case .cloudSyncDisabled: "profiles.cloudSyncDisabled"
      case .cloudSyncPreferenceSaveFailed: "profiles.preferenceSaveFailed"
      case .available: "profiles.available"
      case .syncing: "profiles.syncing"
      case .failed(let failure), .retryScheduled(let failure):
        "profiles.failed kind=\(failure.kind.rawValue) retryable=\(failure.isRetryable)"
      case .recoveryRequired(let recovery):
        "profiles.recoveryRequired reason=\(recovery.reason.rawValue)"
      }
    }
  }
}
