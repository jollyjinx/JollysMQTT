import Foundation
import Testing

@Suite("Release metadata source contract")
struct ReleaseMetadataTests {
  @Test("Version, privacy, and build-family metadata remain explicit")
  func releaseMetadata() throws {
    let project = try sourceText("project.yml")
    let info = try propertyList("JollysMQTTApp/Info.plist")

    #expect(project.occurrences(of: "MARKETING_VERSION: 0.1.0") == 1)
    #expect(project.occurrences(of: "CURRENT_PROJECT_VERSION: 1") == 1)
    #expect(project.contains("Official Development: debug"))
    #expect(project.contains("Official Release: release"))
    #expect(project.contains("JOLLYS_MQTT_PROFILE_SYNC_MODE: localOnly"))
    #expect(project.contains("JOLLYS_MQTT_PROFILE_SYNC_MODE: cloudKit"))
    #expect(project.contains("JOLLYS_MQTT_CLOUDKIT_ENVIRONMENT: Development"))
    #expect(project.contains("JOLLYS_MQTT_CLOUDKIT_ENVIRONMENT: Production"))
    #expect(project.contains("JOLLYS_MQTT_APS_ENVIRONMENT: development"))
    #expect(project.contains("JOLLYS_MQTT_APS_ENVIRONMENT: production"))
    #expect(!project.contains("DEVELOPMENT_TEAM:"))
    #expect(!project.contains("PROVISIONING_PROFILE_SPECIFIER:"))

    #expect(info["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
    #expect(info["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
    #expect(
      info["NSLocalNetworkUsageDescription"] as? String
        == "JollysMQTT uses the local network to connect to MQTT brokers you configure."
    )
  }

  @Test("Entitlement families keep least-privilege allow-lists")
  func releaseEntitlements() throws {
    let ordinaryMac = try propertyList(
      "JollysMQTTApp/JollysMQTT.macOS.entitlements"
    )
    let officialIOS = try propertyList(
      "JollysMQTTApp/JollysMQTT.official.iOS.entitlements"
    )
    let officialMac = try propertyList(
      "JollysMQTTApp/JollysMQTT.official.macOS.entitlements"
    )
    let cloudKeys: Set<String> = [
      "com.apple.developer.icloud-container-environment",
      "com.apple.developer.icloud-container-identifiers",
      "com.apple.developer.icloud-services",
    ]
    let sandboxKeys: Set<String> = [
      "com.apple.security.app-sandbox",
      "com.apple.security.network.client",
    ]

    #expect(Set(ordinaryMac.keys) == sandboxKeys)
    #expect(Set(officialIOS.keys) == cloudKeys.union(["aps-environment"]))
    #expect(
      Set(officialMac.keys)
        == cloudKeys.union(sandboxKeys).union([
          "com.apple.developer.aps-environment"
        ])
    )
    #expect(ordinaryMac.values.allSatisfy { ($0 as? Bool) == true })
    try expectOfficialCloudKitValues(officialIOS, pushKey: "aps-environment")
    try expectOfficialCloudKitValues(
      officialMac,
      pushKey: "com.apple.developer.aps-environment"
    )
  }

  @Test("The app icon catalog declares every required iOS and macOS slot")
  func appIconCatalogSlots() throws {
    let data = try sourceData(
      "JollysMQTTApp/Assets.xcassets/AppIcon.appiconset/Contents.json"
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let images = try #require(object["images"] as? [[String: String]])
    let actual = Set(
      images.map {
        [
          $0["platform"] ?? "",
          $0["idiom"] ?? "",
          $0["size"] ?? "",
          $0["scale"] ?? "",
        ].joined(separator: "|")
      }
    )
    let expected: Set<String> = [
      "ios|universal|1024x1024|",
      "|mac|16x16|1x",
      "|mac|16x16|2x",
      "|mac|32x32|1x",
      "|mac|32x32|2x",
      "|mac|128x128|1x",
      "|mac|128x128|2x",
      "|mac|256x256|1x",
      "|mac|256x256|2x",
      "|mac|512x512|1x",
      "|mac|512x512|2x",
    ]

    #expect(actual == expected)
  }

  private func expectOfficialCloudKitValues(
    _ entitlements: [String: Any],
    pushKey: String
  ) throws {
    #expect(
      entitlements[pushKey] as? String
        == "$(JOLLYS_MQTT_APS_ENVIRONMENT)"
    )
    #expect(
      entitlements["com.apple.developer.icloud-container-environment"]
        as? String == "$(JOLLYS_MQTT_CLOUDKIT_ENVIRONMENT)"
    )
    #expect(
      entitlements["com.apple.developer.icloud-container-identifiers"]
        as? [String]
        == ["$(JOLLYS_MQTT_CLOUDKIT_CONTAINER_IDENTIFIER)"]
    )
    #expect(
      entitlements["com.apple.developer.icloud-services"] as? [String]
        == ["CloudKit"]
    )
  }

  private func propertyList(_ path: String) throws -> [String: Any] {
    let object = try PropertyListSerialization.propertyList(
      from: sourceData(path),
      options: [],
      format: nil
    )
    return try #require(object as? [String: Any])
  }

  private func sourceText(_ path: String) throws -> String {
    try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
  }

  private func sourceData(_ path: String) throws -> Data {
    try Data(contentsOf: repositoryRoot.appending(path: path))
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

extension String {
  fileprivate func occurrences(of substring: String) -> Int {
    components(separatedBy: substring).count - 1
  }
}
