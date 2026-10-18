// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevDisk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DevDisk", path: "Sources/DevDisk")
    ]
)
