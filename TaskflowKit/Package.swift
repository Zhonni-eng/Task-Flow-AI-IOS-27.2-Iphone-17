// swift-tools-version: 6.0
// TaskflowKit: the platform-free core of Taskflow for iPhone (TaskflowCore) and its SwiftUI
// interface (TaskflowUI). The Xcode app target (Taskflow/) adds SwiftData persistence, the app
// entry point and the iOS resources. The macOS platform is listed only so that the core and the
// interface can be built and tested with the command line tools (`swift build`, `swift test`).
import PackageDescription

let package = Package(
    name: "TaskflowKit",
    defaultLocalization: "ru",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TaskflowCore", targets: ["TaskflowCore"]),
        .library(name: "TaskflowUI", targets: ["TaskflowUI"]),
    ],
    targets: [
        .target(
            name: "TaskflowCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "TaskflowUI",
            dependencies: ["TaskflowCore"]
        ),
        .testTarget(
            name: "TaskflowCoreTests",
            dependencies: ["TaskflowCore"]
        ),
    ]
)
