// swift-tools-version: 5.9

import PackageDescription
import Foundation

let packagePath = ProcessInfo.processInfo.environment[
    "DESKTOP_UPDATER_PACKAGE_PATH"
] ?? "../../.."

let package = Package(
    name: "MacOSRuntimeCompile",
    platforms: [
        .macOS("10.15")
    ],
    dependencies: [
        .package(name: "flutter_desktop_updater", path: packagePath)
    ],
    targets: [
        .executableTarget(
            name: "MacOSRuntimeCompile",
            dependencies: [
                .product(
                    name: "DesktopUpdaterKit",
                    package: "flutter_desktop_updater"
                )
            ]
        )
    ]
)
