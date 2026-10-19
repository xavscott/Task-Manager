// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTaskManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacTaskManager", targets: ["MacTaskManager"])],
    targets: [.executableTarget(name: "MacTaskManager")]
)
