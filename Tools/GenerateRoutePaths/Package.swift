// swift-tools-version: 5.9
import PackageDescription

// Authoring-time only. Deliberately NOT part of WayWalkResearch.xcodeproj —
// nothing here ships to a participant's phone.
let package = Package(
    name: "GenerateRoutePaths",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "GenerateRoutePaths", path: "Sources")
    ]
)
