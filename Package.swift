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
        .testTarget(
            name: "DesktopUpdaterKitTests",
            dependencies: ["DesktopUpdaterKit"],
            path: "macos/desktop_updater/Tests/DesktopUpdaterKitTests"
        )
    ]
)
