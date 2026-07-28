import JollysMQTTCore
import JollysMQTTStorage
import JollysMQTTTransport
import SwiftUI

public struct JollysMQTTRootView: View {
    public init() {}

    public var body: some View {
        JollysMQTTEmptyState()
    }
}

private struct JollysMQTTEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(
                "No Brokers",
                bundle: .module,
                comment: "Title of the initial empty broker-list screen."
            )
            .font(.title2)

            Text(
                "Broker profiles will appear here.",
                bundle: .module,
                comment: "Description on the initial empty broker-list screen."
            )
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .navigationTitle(
            Text(
                "JollysMQTT",
                bundle: .module,
                comment: "Application title shown in navigation chrome."
            )
        )
    }
}

public enum ApplicationModule: Sendable {
    public static let name = "JollysMQTT"
    public static let dependencies = [
        CoreModule.name,
        TransportModule.name,
        StorageModule.name,
    ]
}
