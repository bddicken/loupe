// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Loupe",
            path: "Sources/Loupe",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
