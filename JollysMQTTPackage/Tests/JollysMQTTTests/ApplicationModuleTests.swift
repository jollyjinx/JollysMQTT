import JollysMQTTStorage
import Testing

@testable import JollysMQTT

@Suite("Application composition module smoke tests")
struct ApplicationModuleTests {
  @Test("Composition module joins the three implementation layers")
  func moduleBoundaries() {
    #expect(
      ApplicationModule.dependencies == [
        "JollysMQTTCore",
        "JollysMQTTTransport",
        "JollysMQTTStorage",
      ]
    )
  }

  @Test("Live composition defaults to a local-first, local-only profile repository")
  func localFirstProfileComposition() async throws {
    let repository = try #require(
      JollysMQTTAppDependencies.shared.profileRepository
        as? LocalFirstProfileRepository
    )
    #expect(await repository.syncStatus() == .localOnly)
  }
}
