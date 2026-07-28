import Foundation

public struct WorkspaceID: Codable, Hashable, Identifiable, Sendable {
  public let rawValue: UUID

  public var id: UUID { rawValue }

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}
