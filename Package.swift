// swift-tools-version: 5.9
import PackageDescription

// AIUsageTracker — internal AI usage / Claude spend tracker (MVP, mock data).
//
// NOTE: The build instructions call for a macOS Xcode App project. Full Xcode is not
// installed in this environment (only Command Line Tools), so we use a Swift Package
// executable target instead. This compiles + verifies with `swift build` at every step
// and opens directly in Xcode later (File > Open > Package.swift). The folder layout
// (Models / DataSource / Views / ViewModels) matches the doc exactly.
let package = Package(
    name: "AIUsageTracker",
    platforms: [
        .macOS(.v13) // MenuBarExtra + Swift Charts require macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "AIUsageTracker",
            path: "Sources/AIUsageTracker"
        )
    ]
)
