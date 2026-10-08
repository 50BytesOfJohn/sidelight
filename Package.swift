// swift-tools-version:6.2
import PackageDescription
let package = Package(
  name: "SidePanel",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(name: "SidePanel", path: "Sources/SidePanel",
      swiftSettings: [.swiftLanguageMode(.v5)])
  ]
)
