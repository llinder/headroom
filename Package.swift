// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableUpcomingFeature("ExistentialAny")]

let package = Package(
    name: "headroom",
    platforms: [.macOS(.v14)],
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
        .executableTarget(name: "headroom", dependencies: ["HeadroomCore"], swiftSettings: swiftSettings),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"], swiftSettings: swiftSettings),
    ]
)
