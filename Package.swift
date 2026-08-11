// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blooper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Blooper", path: "Sources/Blooper"),
        .testTarget(name: "BlooperTests", dependencies: ["Blooper"], path: "Tests/BlooperTests"),
    ]
)
