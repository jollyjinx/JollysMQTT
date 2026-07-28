// swift-tools-version: 6.2

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
  name: "JollysMQTTPackage",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "JollysMQTTCore", targets: ["JollysMQTTCore"]),
    .library(name: "JollysMQTTTransport", targets: ["JollysMQTTTransport"]),
    .library(name: "JollysMQTTStorage", targets: ["JollysMQTTStorage"]),
    .library(name: "JollysMQTT", targets: ["JollysMQTT"]),
    .executable(
      name: "JollysMQTTOverloadProbe",
      targets: ["JollysMQTTOverloadProbe"]
    ),
    .executable(
      name: "JollysMQTTStorageProbe",
      targets: ["JollysMQTTStorageProbe"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/swift-server-community/mqtt-nio.git",
      exact: "3.0.0-alpha.2"
    )
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "JollysMQTTCore",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "JollysMQTTTransport",
      dependencies: [
        "JollysMQTTCore",
        .product(name: "MQTTNIO", package: "mqtt-nio"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "JollysMQTTStorage",
      dependencies: ["JollysMQTTCore", "CSQLite"],
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "JollysMQTT",
      dependencies: [
        "JollysMQTTCore",
        "JollysMQTTTransport",
        "JollysMQTTStorage",
      ],
      resources: [.process("Resources")],
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "JollysMQTTOverloadProbe",
      dependencies: ["JollysMQTTTransport"],
      resources: [.copy("Resources")],
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "JollysMQTTStorageProbe",
      dependencies: ["JollysMQTTStorage"],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "JollysMQTTCoreTests",
      dependencies: ["JollysMQTTCore"],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "JollysMQTTTransportTests",
      dependencies: ["JollysMQTTTransport"],
      resources: [.copy("Fixtures")],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "JollysMQTTStorageTests",
      dependencies: ["JollysMQTTStorage"],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "JollysMQTTTests",
      dependencies: [
        "JollysMQTT",
        "JollysMQTTCore",
        "JollysMQTTStorage",
        "JollysMQTTTransport",
      ],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
