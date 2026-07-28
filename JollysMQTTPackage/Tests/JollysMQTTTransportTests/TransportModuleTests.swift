import Testing
@testable import JollysMQTTTransport

@Suite("Transport module smoke tests")
struct TransportModuleTests {
    @Test("Transport depends only on the domain module")
    func moduleBoundaries() {
        #expect(TransportModule.dependencies == ["JollysMQTTCore"])
    }
}
