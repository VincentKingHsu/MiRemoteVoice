// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiRemoteBridge",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "MiRemoteBridge",
            path: "Sources/MiRemoteBridge"
        )
    ]
)
