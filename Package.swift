// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DesktopUpdaterKit",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "DesktopUpdaterKit", targets: ["DesktopUpdaterKit"])
    ],
    targets: [
        .target(
            name: "DesktopUpdaterKit",
            path: "macos/desktop_updater/Sources/DesktopUpdaterKit"
        ),
        .executableTarget(
            name: "MacApplicationRestartFixture",
            dependencies: ["DesktopUpdaterKit"],
            path: "macos/desktop_updater/Tests/Fixtures/MacApplicationRestartFixture"
        ),
        .executableTarget(
            name: "MacApplicationRestartImpostorFixture",
            dependencies: ["DesktopUpdaterKit"],
            path: "macos/desktop_updater/Tests/Fixtures/MacApplicationRestartImpostorFixture"
        ),
        .testTarget(
            name: "DesktopUpdaterKitTests",
            dependencies: [
                "DesktopUpdaterKit",
                "MacApplicationRestartFixture",
                "MacApplicationRestartImpostorFixture"
            ],
            path: "macos/desktop_updater/Tests/DesktopUpdaterKitTests"
        )
    ]
)
