import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Observation

/// Owns coalesced, ordered preference writes for one connection workspace.
@MainActor
@Observable
final class BrokerChartPreferencesStore {
  private(set) var brokerID: UUID?
  private(set) var isLoaded = false
  private(set) var windowFrame: ChartWindowFrame?
  var onFailure: (@MainActor @Sendable () -> Void)?

  private let repository: any BrokerChartRepositoryProtocol
  private var pending: [UUID: Pending] = [:]
  private var writer: Task<Void, Never>?

  private struct Pending {
    var dashboard: NumericChartDashboardConfiguration?
    var windowFrame: ChartWindowFrame?
  }

  init(repository: any BrokerChartRepositoryProtocol) {
    self.repository = repository
  }

  func load(
    brokerID: UUID,
    fallback: NumericChartDashboardConfiguration
  ) async -> NumericChartDashboardConfiguration {
    await flush()
    isLoaded = false
    self.brokerID = brokerID
    windowFrame = nil
    do {
      let saved = try await repository.load(brokerID: brokerID)
      windowFrame = saved?.windowFrame
      isLoaded = true
      let dashboard = (saved?.dashboard ?? fallback).normalized(
        maximumCardCount: NumericChartDashboardPolicy.default.maximumCardCount,
        brokerID: brokerID
      )
      if saved == nil, !dashboard.cards.isEmpty { saveDashboard(dashboard) }
      return dashboard
    } catch {
      // Preserve unreadable/future-version files; do not overwrite with a fallback.
      onFailure?()
      return fallback
    }
  }

  func saveDashboard(_ dashboard: NumericChartDashboardConfiguration) {
    guard isLoaded, let brokerID else { return }
    pending[brokerID, default: Pending()].dashboard = dashboard
    startWriter()
  }

  func saveWindowFrame(_ frame: ChartWindowFrame) {
    guard isLoaded, let brokerID, frame.isValid, frame != windowFrame else { return }
    windowFrame = frame
    pending[brokerID, default: Pending()].windowFrame = frame
    startWriter()
  }

  func flush() async {
    while let writer { await writer.value }
  }

  private func startWriter() {
    guard writer == nil else { return }
    writer = Task {
      while let (brokerID, change) = pending.first {
        pending[brokerID] = nil
        do {
          try await repository.update(
            brokerID: brokerID,
            dashboard: change.dashboard,
            windowFrame: change.windowFrame
          )
        } catch {
          onFailure?()
        }
      }
      writer = nil
    }
  }
}
