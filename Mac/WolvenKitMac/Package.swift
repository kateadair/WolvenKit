// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WolvenKitMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WolvenKitMac", targets: ["WolvenKitMac"])
    ],
    targets: [
        .executableTarget(
            name: "WolvenKitMac",
            path: "Sources/WolvenKitMac"
        ),
        .testTarget(
            name: "WolvenKitMacTests",
            dependencies: ["WolvenKitMac"],
            path: "Tests/WolvenKitMacTests"
        )
    ]
)
