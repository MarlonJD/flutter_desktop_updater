import XCTest
@testable import desktop_updater

final class DesktopUpdaterSwiftPMTests: XCTestCase {
    func testRelaunchSuppressionIsRestrictedToTheExactSmokeBundle() {
        let target = URL(
            fileURLWithPath: "/Applications/Desktop Updater Smoke.app"
        )
        let environment = [
            "DESKTOP_UPDATER_CONTROLLER_SMOKE": "1",
            "DESKTOP_UPDATER_CONTROLLER_SMOKE_TARGET": target.path,
            "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1",
        ]

        XCTAssertTrue(
            DesktopUpdaterPlugin.smokeRelaunchSuppressionAllowed(
                environment: environment,
                bundleIdentifier: "com.example.desktopUpdaterSmoke",
                bundleURL: target
            )
        )
        XCTAssertFalse(
            DesktopUpdaterPlugin.smokeRelaunchSuppressionAllowed(
                environment: environment,
                bundleIdentifier: "com.example.production",
                bundleURL: target
            )
        )
        XCTAssertFalse(
            DesktopUpdaterPlugin.smokeRelaunchSuppressionAllowed(
                environment: environment,
                bundleIdentifier: "com.example.desktopUpdaterSmoke",
                bundleURL: URL(fileURLWithPath: "/tmp/Smoke.app")
            )
        )
        XCTAssertFalse(
            DesktopUpdaterPlugin.smokeRelaunchSuppressionAllowed(
                environment: [
                    "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1"
                ],
                bundleIdentifier: "com.example.desktopUpdaterSmoke",
                bundleURL: target
            )
        )
    }

    func testPluginTypeIsAvailableFromSwiftPackage() {
        XCTAssertNotNil(DesktopUpdaterPlugin.self)
    }

    func testPluginSourceIncludesInstallUpdateHandoff() throws {
        let source = try String(
            contentsOfFile: "Sources/desktop_updater/DesktopUpdaterPlugin.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("installUpdate"))
        XCTAssertTrue(source.contains("prepareInstall"))
        XCTAssertTrue(source.contains("commitAfterExit"))
        XCTAssertFalse(source.contains("scheduleInstallAndRelaunch"))
        XCTAssertTrue(source.contains("queryInstallTransaction"))
        XCTAssertTrue(source.contains("recoverPendingInstallTransaction"))
        XCTAssertTrue(source.contains("checkMacOSInstallLocation"))
        XCTAssertTrue(source.contains("moveMacOSAppToApplications"))
    }

}
