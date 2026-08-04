import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacPrivilegeBootstrapTests: XCTestCase {
    func testFixedPrivilegedCommandRunsServiceRuntime() throws {
        let runtime = RecordingMacPrivilegedServiceRuntime()

        let output = try HelperCommand.privilegedService.execute(
            protocolInput: Data(),
            privilegedServiceRuntime: runtime
        )

        XCTAssertNil(output)
        XCTAssertEqual(runtime.runCount, 1)
    }

    func testPackageEmbedsOnlyTheHelperPolicyInfoSection() throws {
        let package = try String(
            contentsOf: helperPackageRoot()
                .appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(package.contains("__info_plist"))
        XCTAssertTrue(package.contains("Configuration/Helper-Info.plist"))
        XCTAssertFalse(package.contains("__launchd_plist"))
    }

    func testLaunchdUsesTheFixedBundledProgram() throws {
        let data = try Data(
            contentsOf: helperPackageRoot()
                .appendingPathComponent(
                    "Configuration/Helper-Launchd.plist"
                )
        )
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            object["BundleProgram"] as? String,
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        XCTAssertNil(object["Program"])
        XCTAssertNil(object["ProgramArguments"])
    }

    func testPrivilegedRuntimeRejectsNonRootBeforeStartingXPC() {
        XCTAssertThrowsError(
            try MacPrivilegedBootstrapEnvironment.validate(
                effectiveUserIdentifier: 501
            )
        ) { error in
            XCTAssertEqual(
                error as? MacPrivilegeError,
                .privilegedServiceRequiresRoot
            )
        }
        XCTAssertNoThrow(
            try MacPrivilegedBootstrapEnvironment.validate(
                effectiveUserIdentifier: 0
            )
        )
    }
}

private final class RecordingMacPrivilegedServiceRuntime:
    MacPrivilegedServiceRunning
{
    var runCount = 0

    func run() throws {
        runCount += 1
    }
}

private func helperPackageRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("Package.swift").path
        ), FileManager.default.fileExists(
            atPath: candidate
                .appendingPathComponent("Configuration/Helper-Info.plist")
                .path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
