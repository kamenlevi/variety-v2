// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VarietyV2",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VarietyV2",
            path: "Sources/VarietyV2"
        )
    ]
)
