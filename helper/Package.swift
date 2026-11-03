// swift-tools-version:5.9
// Pure logic shared with the Xcode app target, built here only for `swift test`.
import PackageDescription

let package = Package(
    name: "SKCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SKCore", path: "Sources/SKCore"),
        .testTarget(name: "SKCoreTests", dependencies: ["SKCore"], path: "Tests/SKCoreTests"),
    ]
)
