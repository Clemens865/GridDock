// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GridDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GridDock",
            path: "Sources/GridDock",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "GridDockTests",
            dependencies: ["GridDock"],
            path: "Tests/GridDockTests"
        ),
    ]
)
