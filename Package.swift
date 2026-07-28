// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUsageTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AIUsageTracker",
            path: "Sources/AIUsageTracker"
        )
    ]
)
