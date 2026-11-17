// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "duorex",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "duorex",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "duorexTests",
            dependencies: ["duorex"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
