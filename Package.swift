// swift-tools-version: 6.2
import PackageDescription

/// Approachable Concurrency: `async` functions run on the caller's actor unless marked `@concurrent`,
/// and conformances of main-actor types are inferred as main-actor isolated.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Sidelight",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Sidelight", targets: ["Sidelight"])
    ],
    dependencies: [
        // Software updates. A binary framework that scripts/build-app.sh embeds in the app bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // The app: AppKit/SwiftUI, isolated to the main actor by default.
        .executableTarget(
            name: "Sidelight",
            dependencies: ["SidelightCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: approachableConcurrency + [.defaultIsolation(MainActor.self)]
        ),
        // UI-free domain logic: configuration schema, protocols, parsers, geometry. Nonisolated and Sendable.
        .target(
            name: "SidelightCore",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "SidelightCoreTests",
            dependencies: ["SidelightCore"],
            swiftSettings: approachableConcurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)
