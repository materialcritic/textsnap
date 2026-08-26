// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TextSnap",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TextSnap",
            path: "Sources/TextSnap"
        )
    ]
)
