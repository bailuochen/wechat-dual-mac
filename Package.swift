// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatDual",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WeChatDual", targets: ["WeChatDual"])],
    targets: [
        .target(name: "CloneCore"),
        .executableTarget(name: "WeChatDual", dependencies: ["CloneCore"]),
        .testTarget(name: "CloneCoreTests", dependencies: ["CloneCore"])
    ]
)
