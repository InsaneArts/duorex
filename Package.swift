// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "duorex",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../simhost"),
    ],
    targets: [
        .executableTarget(
            name: "duorex",
            dependencies: [.product(name: "SimHostKit", package: "simhost")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "duorexTests",
            dependencies: ["duorex", .product(name: "SimHostKit", package: "simhost")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
