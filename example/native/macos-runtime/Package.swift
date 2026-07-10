// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacOSRuntimeCompile",
    platforms: [
        .macOS("10.15")
    ],
    dependencies: [
        .package(path: "../../..")
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
