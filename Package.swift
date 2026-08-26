// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TextSnap",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TextSnap",
            path: "Sources/TextSnap"
        )
    ]
)
