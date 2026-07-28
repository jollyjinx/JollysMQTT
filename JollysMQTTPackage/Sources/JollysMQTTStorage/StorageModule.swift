import CSQLite
import JollysMQTTCore

public enum StorageModule: Sendable {
    public static let name = "JollysMQTTStorage"
    public static let dependencies = [CoreModule.name, "CSQLite"]

    public static var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }
}
