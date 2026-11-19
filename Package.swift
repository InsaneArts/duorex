// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "duorex",
    platforms: [.macOS(.v15)],
    dependencies: [
        // One revision of simhost, so that a build of duorex always gets the same code.
        .package(url: "https://github.com/InsaneArts/simhost.git", revision: "c724aa2ecf956696a72d4135face911bfc933d43"),
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
