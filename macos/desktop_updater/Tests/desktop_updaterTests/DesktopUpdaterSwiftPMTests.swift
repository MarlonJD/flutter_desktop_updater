import XCTest
import FlutterMacOS
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
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("desktop_updater_forged_stage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
        }

        let plugin = DesktopUpdaterPlugin()
        let completed = expectation(description: "installUpdate returns forged-payload error")
        let call = FlutterMethodCall(
            methodName: "installUpdate",
            arguments: [
                "stagingPath": stagingRoot.path,
                "stageProvenanceSha256": String(repeating: "f", count: 64),
                "transactionId": "123e4567-e89b-42d3-a456-426614174000",
            ]
        )

        plugin.handle(call) { result in
            guard let error = result as? FlutterError else {
                XCTFail("Expected FlutterError, got \(String(describing: result))")
                completed.fulfill()
                return
            }
            XCTAssertEqual(error.code, "InstallError")
            XCTAssertTrue(
                (error.message ?? "").contains("provenance") ||
                    (error.message ?? "").contains("stage") ||
                    (error.message ?? "").contains("manifest")
            )
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }
}
