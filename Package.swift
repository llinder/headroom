// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableUpcomingFeature("ExistentialAny")]

let package = Package(
    name: "headroom",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "headroom", targets: ["headroom"]),
        .executable(name: "headroomd", targets: ["headroomd"]),
    ],
    targets: [
        .target(
            name: "HeadroomCore",
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("IOKit")]
        ),
        .executableTarget(name: "headroomd", dependencies: ["HeadroomCore"], swiftSettings: swiftSettings),
        .target(name: "HeadroomCLI", dependencies: ["HeadroomCore"], swiftSettings: swiftSettings),
        .executableTarget(name: "headroom", dependencies: ["HeadroomCLI"], swiftSettings: swiftSettings),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"], swiftSettings: swiftSettings),
        .testTarget(name: "HeadroomCLITests", dependencies: ["HeadroomCLI", "HeadroomCore"], swiftSettings: swiftSettings),
    ]
)
