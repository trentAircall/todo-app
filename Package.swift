// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ToDoApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ToDoApp",
            path: "Sources/ToDoApp"
        )
    ]
)
