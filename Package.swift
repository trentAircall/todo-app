// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ToDoApp",
    platforms: [.macOS(.v13)],
    targets: [
        // The task model and file format, split out from the app so it can
        // be unit-tested without SwiftUI/AppKit. Its JavaScript twin lives
        // in mcp-server/taskfile.js, and ToDoCoreTests checks the two agree.
        .target(
            name: "ToDoCore",
            path: "Sources/ToDoCore"
        ),
        .executableTarget(
            name: "ToDoApp",
            dependencies: ["ToDoCore"],
            path: "Sources/ToDoApp"
        ),
        // Fixtures are read from Tests/fixtures/ via #filePath rather than
        // declared as bundle resources: the same files are read by the
        // Node suite in mcp-server/test/, so they can't live inside either
        // language's build output.
        .testTarget(
            name: "ToDoCoreTests",
            dependencies: ["ToDoCore"],
            path: "Tests/ToDoCoreTests"
        ),
    ]
)
