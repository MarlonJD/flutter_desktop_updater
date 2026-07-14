// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DesktopUpdaterInstallHelper",
    platforms: [
        .macOS(.v10_14)
    ],
    products: [
        .executable(name: "DesktopUpdaterInstallHelper", targets: ["DesktopUpdaterInstallHelper"])
    ],
    targets: [
        .executableTarget(
            name: "DesktopUpdaterInstallHelper"
        ),
        .testTarget(
            name: "DesktopUpdaterInstallHelperTests",
            dependencies: ["DesktopUpdaterInstallHelper"]
        )
    ]
)
