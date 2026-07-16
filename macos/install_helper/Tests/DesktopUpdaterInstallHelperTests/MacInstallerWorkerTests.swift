import Darwin
import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacInstallerWorkerTests: XCTestCase {
    func testEOFBeforeGateReleaseExitsWithoutMutation() throws {
        var executedPath: String?

        try MacInstallerWorkerRuntime.run(
            requestData: Data(),
            effectiveUserIdentifier: 0,
            installerExecutor: { executedPath = $0 }
        )

        XCTAssertNil(executedPath)
    }

    func testReleasedGateAcceptsOnlyProtectedPackagePath() throws {
        let path = "/Library/PrivilegedHelperTools/"
            + ".desktop-updater-stages-"
            + String(repeating: "a", count: 64)
            + "/desktop-updater-stage-"
            + "10000000-0000-4000-8000-000000000001/installer.pkg"
        var executedPath: String?

        try MacInstallerWorkerRuntime.run(
            requestData: try MacInstallerWorkerRequest(
                installerPath: path
            ).encode(),
            effectiveUserIdentifier: 0,
            installerExecutor: { executedPath = $0 }
        )

        XCTAssertEqual(executedPath, path)
    }

    func testReleasedGateRejectsCallerChosenTemporaryPackage() throws {
        let request = try MacInstallerWorkerRequest(
            installerPath: "/tmp/"
                + ".desktop-updater-stages-"
                + String(repeating: "a", count: 64)
                + "/desktop-updater-stage-"
                + "10000000-0000-4000-8000-000000000001/installer.pkg"
        ).encode()
        var executed = false

        XCTAssertThrowsError(
            try MacInstallerWorkerRuntime.run(
                requestData: request,
                effectiveUserIdentifier: 0,
                installerExecutor: { _ in executed = true }
            )
        ) { error in
            XCTAssertEqual(
                error as? MacInstallerWorkerError,
                .invalidRequest
            )
        }
        XCTAssertFalse(executed)
    }

    func testReleasedGateRequiresRoot() throws {
        let path = "/Library/PrivilegedHelperTools/"
            + ".desktop-updater-stages-"
            + String(repeating: "a", count: 64)
            + "/desktop-updater-stage-"
            + "10000000-0000-4000-8000-000000000001/installer.pkg"

        XCTAssertThrowsError(
            try MacInstallerWorkerRuntime.run(
                requestData: try MacInstallerWorkerRequest(
                    installerPath: path
                ).encode(),
                effectiveUserIdentifier: 501,
                installerExecutor: { _ in XCTFail("must not execute") }
            )
        ) { error in
            XCTAssertEqual(
                error as? MacInstallerWorkerError,
                .requiresRoot
            )
        }
    }
}
