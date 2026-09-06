// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "WardriveAtlas",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "WardriveAtlasCore", targets: ["WardriveAtlasCore"]),
    .executable(name: "WardriveAtlas", targets: ["WardriveAtlasApp"]),
  ],
  targets: [
    .target(name: "WardriveAtlasCore", resources: [.process("Resources")]),
    .executableTarget(
      name: "WardriveAtlasApp", dependencies: ["WardriveAtlasCore"],
      resources: [.process("Resources")]),
    .testTarget(
      name: "WardriveAtlasCoreTests", dependencies: ["WardriveAtlasCore"],
      resources: [.process("Fixtures")]),
  ],
  swiftLanguageModes: [.v5]
)
