// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GoodMouse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "GoodMouse", path: "Sources/GoodMouse")
    ]
)
