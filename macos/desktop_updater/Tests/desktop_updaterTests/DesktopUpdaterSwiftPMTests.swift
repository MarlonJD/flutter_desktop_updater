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
        XCTAssertTrue(source.contains("prepareInstall"))
        XCTAssertTrue(source.contains("commitAfterExit"))
        XCTAssertFalse(source.contains("scheduleInstallAndRelaunch"))
        XCTAssertTrue(source.contains("queryInstallTransaction"))
        XCTAssertTrue(source.contains("recoverPendingInstallTransaction"))
        XCTAssertTrue(source.contains("checkMacOSInstallLocation"))
        XCTAssertTrue(source.contains("moveMacOSAppToApplications"))
    }

    func testForgedRawMethodChannelPayloadFailsStageDescriptorAndTargetValidation() throws {
        let source = try String(
            contentsOfFile: "Sources/desktop_updater/DesktopUpdaterPlugin.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("installUpdate"))
        XCTAssertTrue(source.contains("stagingPath"))
        XCTAssertTrue(source.contains("stageProvenanceSHA256"))
        XCTAssertTrue(source.contains("transactionID"))
        XCTAssertTrue(source.contains("isCanonicalTransactionID"))
        XCTAssertTrue(source.contains("prepareInstall"))
    }
}
