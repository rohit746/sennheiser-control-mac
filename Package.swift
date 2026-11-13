// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SennheiserControl",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "GAIA3", path: "Sources/GAIA3"),
        .executableTarget(
            name: "SennheiserControl",
            dependencies: ["GAIA3"],
            path: "Sources/SennheiserControl",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(name: "GAIA3Tests", dependencies: ["GAIA3"], path: "Tests/GAIA3Tests"),
        .testTarget(name: "SennheiserControlTests", dependencies: ["SennheiserControl", "GAIA3"],
                    path: "Tests/SennheiserControlTests"),
    ]
)
