import Testing
@testable import JollysMQTTStorage

@Suite("Storage module smoke tests")
struct StorageModuleTests {
    @Test("Storage links the system SQLite library")
    func sqliteLinkage() {
        #expect(StorageModule.sqliteVersion.isEmpty == false)
    }

    @Test("Storage keeps domain and SQLite dependencies explicit")
    func moduleBoundaries() {
        #expect(StorageModule.dependencies == ["JollysMQTTCore", "CSQLite"])
    }
}
