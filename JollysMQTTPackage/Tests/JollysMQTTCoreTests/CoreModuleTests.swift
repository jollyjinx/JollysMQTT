import Testing
@testable import JollysMQTTCore

@Suite("Core module smoke tests")
struct CoreModuleTests {
    @Test("Core module exposes its stable identity")
    func moduleIdentity() {
        #expect(CoreModule.name == "JollysMQTTCore")
    }
}
