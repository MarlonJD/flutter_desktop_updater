// swift-tools-version: 5.9

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment
let helperInfoPlist = environment["DESKTOP_UPDATER_HELPER_INFO_PLIST"]
    ?? packageDirectory.appendingPathComponent(
        "Configuration/Helper-Info.plist"
    ).path
let helperLaunchdPlist = environment["DESKTOP_UPDATER_HELPER_LAUNCHD_PLIST"]
    ?? packageDirectory.appendingPathComponent(
        "Configuration/Helper-Launchd.plist"
    ).path

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
            name: "DesktopUpdaterInstallHelper",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", helperInfoPlist,
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__launchd_plist",
                    "-Xlinker", helperLaunchdPlist,
                ])
            ]
        ),
        .testTarget(
            name: "DesktopUpdaterInstallHelperTests",
            dependencies: ["DesktopUpdaterInstallHelper"]
        )
    ]
)
