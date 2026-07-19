// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Marduk",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "marduk",
            path: "Sources"
        ),
        .testTarget(
            name: "MardukTests",
            dependencies: ["marduk"],
            path: "Tests/MardukTests"
        )
    ]
)
