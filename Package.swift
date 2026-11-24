// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "duorex",
    platforms: [.macOS(.v15)],
    dependencies: [
        // One revision of simhost, so that a build of duorex always gets the same code.
        .package(url: "https://github.com/InsaneArts/simhost.git", revision: "2b0009490c8464c9a4db46779f8c30d2601c9bf4"),
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
