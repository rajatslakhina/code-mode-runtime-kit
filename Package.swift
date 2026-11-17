// swift-tools-version: 6.0
import PackageDescription

// Library only. The runnable demo lives in a separate repository
// (code-mode-runtime-demo-app) that consumes this package as a remote,
// version-pinned dependency. There is deliberately no executable target here.
let package = Package(
    name: "CodeModeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CodeModeKit", targets: ["CodeModeKit"]),
    ],
    targets: [
        .target(name: "CodeModeKit"),
        .testTarget(name: "CodeModeKitTests", dependencies: ["CodeModeKit"]),
    ]
)
