// swift-tools-version: 6.4
import PackageDescription

/// Swift 6 语言模式（严格并发检查），UI 应用默认 MainActor 隔离 + Approachable Concurrency
let appSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances")
]

let package = Package(
    name: "DesignStudio",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "DesignStudio", targets: ["DesignStudio"])
    ],
    targets: [
        .executableTarget(
            name: "DesignStudio",
            path: "Sources/DesignStudio",
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "DesignStudioTests",
            dependencies: ["DesignStudio"],
            path: "Tests/DesignStudioTests",
            swiftSettings: appSettings
        )
    ]
)
