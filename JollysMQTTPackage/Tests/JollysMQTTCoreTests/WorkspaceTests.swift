import Foundation
import JollysMQTTCore
import Testing

@Suite("Workspace identity")
struct WorkspaceIdentityTests {
  @Test("Fresh workspace identities are unique and Codable")
  func identityIsUniqueAndCodable() throws {
    let first = WorkspaceID()
    let second = WorkspaceID()

    #expect(first != second)

    let encoded = try JSONEncoder().encode(first)
    let decoded = try JSONDecoder().decode(WorkspaceID.self, from: encoded)
    #expect(decoded == first)
  }
}
