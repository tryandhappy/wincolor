// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wincolor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "wincolor",
            path: "Sources/wincolor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
