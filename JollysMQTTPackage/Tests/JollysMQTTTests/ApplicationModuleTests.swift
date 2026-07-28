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
}
