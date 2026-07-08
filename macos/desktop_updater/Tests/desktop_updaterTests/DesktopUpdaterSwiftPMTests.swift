import XCTest
@testable import desktop_updater

final class DesktopUpdaterSwiftPMTests: XCTestCase {
    func testPluginTypeIsAvailableFromSwiftPackage() {
        XCTAssertNotNil(DesktopUpdaterPlugin.self)
    }

    func testPluginSourceIncludesInstallUpdateHandoff() throws {
        let source = try String(
            contentsOfFile: "Sources/desktop_updater/DesktopUpdaterPlugin.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("installUpdate"))
        XCTAssertTrue(source.contains("checkMacOSInstallLocation"))
        XCTAssertTrue(source.contains("moveMacOSAppToApplications"))
    }
}
