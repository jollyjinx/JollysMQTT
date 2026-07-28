import JollysMQTTCore

public enum TransportModule: Sendable {
    public static let name = "JollysMQTTTransport"
    public static let dependencies = [CoreModule.name]
}
