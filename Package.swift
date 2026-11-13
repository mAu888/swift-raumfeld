// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RaumfeldKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "RaumfeldKit", targets: ["RaumfeldKit"]),
        .executable(name: "raumfeld", targets: ["raumfeld-cli"]),
    ],
    targets: [
        .target(name: "RaumfeldKit"),
        .executableTarget(
            name: "raumfeld-cli",
            dependencies: ["RaumfeldKit"]
        ),
        .testTarget(
            name: "RaumfeldKitTests",
            dependencies: ["RaumfeldKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
