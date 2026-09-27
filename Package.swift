// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AresTranslator",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "AresTranslator",
            path: "Sources/AresTranslator"
        ),
        .executableTarget(
            name: "GCTest",
            path: "Sources/GCTest",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("GameController"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
