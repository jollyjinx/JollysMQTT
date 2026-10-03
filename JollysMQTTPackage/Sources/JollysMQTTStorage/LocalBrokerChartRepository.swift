import Foundation
import JollysMQTTCore

/// Device-local screen coordinates, independent of any particular connection window.
public struct ChartWindowFrame: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && width >= 320 && height >= 320
  }
}

public struct BrokerChartPreferences: Codable, Equatable, Sendable {
  public var dashboard: NumericChartDashboardConfiguration
  public var windowFrame: ChartWindowFrame?

  public init(
    dashboard: NumericChartDashboardConfiguration = .init(),
    windowFrame: ChartWindowFrame? = nil
  ) {
    self.dashboard = dashboard
    self.windowFrame = windowFrame
  }
}

public protocol BrokerChartRepositoryProtocol: Sendable {
  func load(brokerID: UUID) async throws -> BrokerChartPreferences?
  /// Partial updates prevent window movement from overwriting another window's cards.
  func update(
    brokerID: UUID,
    dashboard: NumericChartDashboardConfiguration?,
    windowFrame: ChartWindowFrame?
  ) async throws
}

public actor MemoryBrokerChartRepository: BrokerChartRepositoryProtocol {
  private var records: [UUID: BrokerChartPreferences] = [:]

  public init() {}

  public func load(brokerID: UUID) -> BrokerChartPreferences? { records[brokerID] }

  public func update(
    brokerID: UUID,
    dashboard: NumericChartDashboardConfiguration?,
    windowFrame: ChartWindowFrame?
  ) {
    var record = records[brokerID] ?? .init()
    if let dashboard { record.dashboard = dashboard }
    if let windowFrame, windowFrame.isValid { record.windowFrame = windowFrame }
    records[brokerID] = record
  }
}

/// These records deliberately outlive the seven-day closed-workspace retention.
public actor LocalBrokerChartRepository: BrokerChartRepositoryProtocol {
  private let directoryURL: URL
  private let filePolicy: any WorkspaceFilePolicy

  public init(
    directoryURL: URL,
    filePolicy: any WorkspaceFilePolicy = SystemWorkspaceFilePolicy()
  ) {
    self.directoryURL = directoryURL
    self.filePolicy = filePolicy
  }

  public func load(brokerID: UUID) async throws -> BrokerChartPreferences? {
    let url = fileURL(brokerID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    try await filePolicy.apply(to: url)
    return try read(brokerID)
  }

  public func update(
    brokerID: UUID,
    dashboard: NumericChartDashboardConfiguration?,
    windowFrame: ChartWindowFrame?
  ) async throws {
    // No suspension between reading and atomically replacing a record.
    var record = try read(brokerID) ?? .init()
    if let dashboard {
      record.dashboard = dashboard.normalized(
        maximumCardCount: NumericChartDashboardPolicy.default.maximumCardCount,
        brokerID: brokerID
      )
    }
    if let windowFrame, windowFrame.isValid { record.windowFrame = windowFrame }
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(Document(version: 1, preferences: record))
    let url = fileURL(brokerID)
    try data.write(to: url, options: .atomic)
    try await filePolicy.apply(to: url)
  }

  private func read(_ brokerID: UUID) throws -> BrokerChartPreferences? {
    let url = fileURL(brokerID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let version = try JSONDecoder().decode(Version.self, from: data).version
    guard version == 1 else {
      throw LocalWorkspaceRepositoryError.unsupportedVersion(version)
    }
    return try JSONDecoder().decode(Document.self, from: data).preferences
  }

  private func fileURL(_ brokerID: UUID) -> URL {
    directoryURL.appending(path: "\(brokerID.uuidString.lowercased()).json")
  }

  private struct Version: Decodable { let version: Int }
  private struct Document: Codable {
    let version: Int
    let preferences: BrokerChartPreferences
  }
}
