// swift-tools-version:6.2
import PackageDescription
let package = Package(
  name: "Sidelight",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(name: "Sidelight", path: "Sources/Sidelight",
      swiftSettings: [.swiftLanguageMode(.v5)])
  ]
)
