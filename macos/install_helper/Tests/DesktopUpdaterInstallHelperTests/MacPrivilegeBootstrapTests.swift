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

    func testPackageEmbedsBothSMJobBlessMetadataSections() throws {
        let package = try String(
            contentsOf: helperPackageRoot()
                .appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(package.contains("__info_plist"))
        XCTAssertTrue(package.contains("Configuration/Helper-Info.plist"))
        XCTAssertTrue(package.contains("__launchd_plist"))
        XCTAssertTrue(package.contains("Configuration/Helper-Launchd.plist"))
    }

    func testLaunchdLetsServiceManagementSetTheFixedProgramArgument() throws {
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
            object["ProgramArguments"] as? [String],
            [
                "/Library/PrivilegedHelperTools/"
                    + "com.example.desktop-updater.helper",
            ]
        )
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
