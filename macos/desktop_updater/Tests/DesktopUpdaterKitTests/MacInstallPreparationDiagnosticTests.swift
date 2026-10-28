import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class MacInstallPreparationDiagnosticTests: XCTestCase {
    func testMissingHostMetadataProducesActionableFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents, withIntermediateDirectories: true
        )
        let info: [String: String] = [
            "CFBundleIdentifier": "com.example.diagnostics",
            "CFBundleExecutable": "Example",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(
            try SystemMacInstallRequestEvidenceBuilder().build(for:
                MacInstallTarget(
                    processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    bundleURL: root
                )
            )
        ) { error in
            XCTAssertEqual(error as? MacInstallPreparationError, .hostMetadataInvalid)
            XCTAssertEqual(
                MacInstallPreparationDiagnostic.details(
                    for: error, phase: .installPreparation
                )["action"], "rebuildAndReinstallHost"
            )
        }
    }

    func testConfigurationFailuresHaveSpecificBoundedReasons() {
        for error in [
            MacInstallPreparationError.helperMissing,
            .helperNotExecutable, .helperSignatureInvalid, .helperPolicyInvalid,
            .helperReleaseKeysInvalid, .hostMetadataInvalid,
        ] {
            let details = MacInstallPreparationDiagnostic.details(
                for: error, phase: .helperConfiguration
            )
            XCTAssertEqual(details["phase"], "helperConfiguration")
            XCTAssertEqual(details["reason"], error.rawValue)
            XCTAssertEqual(details["action"], "rebuildAndReinstallHost")
            XCTAssertEqual(Set(details.keys), ["phase", "reason", "action"])
        }
    }

    func testEndpointAndBindingFailuresRemainDistinguishable() {
        XCTAssertEqual(
            MacInstallPreparationDiagnostic.details(
                for: MacInstallClientError.endpointUnavailable,
                phase: .installPreparation
            )["reason"],
            "helperEndpointUnavailable"
        )
        XCTAssertEqual(
            MacInstallPreparationDiagnostic.details(
                for: MacInstallPreparationError.stageBindingMismatch,
                phase: .stageVerification
            )["reason"],
            "stageBindingMismatch"
        )
    }

    func testUnknownErrorsNeverExposeNativeTextPathsOrUserInfo() throws {
        let secret = "/Users/private/secret-policy.json bearer secret-token"
        let error = NSError(
            domain: secret, code: 9123,
            userInfo: [NSLocalizedDescriptionKey: secret,
                       NSFilePathErrorKey: secret,
                       NSUnderlyingErrorKey: NSError(domain: secret, code: 1)]
        )
        for phase in MacInstallPreparationPhase.allCases {
            let details = MacInstallPreparationDiagnostic.details(
                for: error, phase: phase
            )
            XCTAssertEqual(Set(details.keys), ["phase", "reason", "action"])
            XCTAssertEqual(details["phase"], phase.rawValue)
            XCTAssertEqual(details["reason"], "\(phase.rawValue)Failed")
            let encoded = String(
                data: try JSONSerialization.data(withJSONObject: details),
                encoding: .utf8
            )!
            XCTAssertFalse(encoded.contains("secret"))
            XCTAssertFalse(encoded.contains("Users"))
            XCTAssertFalse(encoded.contains("9123"))
            XCTAssertLessThan(encoded.count, 256)
        }
    }
}
