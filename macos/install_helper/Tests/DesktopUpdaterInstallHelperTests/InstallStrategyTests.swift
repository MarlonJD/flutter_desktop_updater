import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class InstallStrategyTests: XCTestCase {
    private let directory = InstallStrategyCapability(
        strategy: .directoryReplace,
        provider: .platformDirectory
    )
    private let file = InstallStrategyCapability(
        strategy: .singleFileReplace,
        provider: .platformFile
    )
    private let installer = InstallStrategyCapability(
        strategy: .verifiedInstallerHandoff,
        provider: .macosInstaller
    )

    func testSelectsOnlyExactPolicyAndProtocolCapability() throws {
        let selector = MacInstallStrategySelector(
            policyCapabilities: [directory, installer],
            protocolCapabilities: [directory, installer]
        )
        XCTAssertEqual(
            try selector.select(
                .init(
                    strategy: .directoryReplace,
                    provider: .platformDirectory
                )
            ),
            directory
        )
        XCTAssertEqual(
            try selector.select(
                .init(
                    strategy: .verifiedInstallerHandoff,
                    provider: .macosInstaller
                )
            ),
            installer
        )
        XCTAssertThrowsError(
            try selector.select(
                .init(
                    strategy: .verifiedInstallerHandoff,
                    provider: .windowsInno
                )
            )
        )
        XCTAssertThrowsError(
            try selector.select(
                .init(
                    strategy: .directoryReplace,
                    provider: .platformFile
                )
            )
        )
    }

    func testRejectsCapabilityDriftAndRootFileWithoutBroker() {
        let selector = MacInstallStrategySelector(
            policyCapabilities: [directory, file],
            protocolCapabilities: [directory]
        )
        XCTAssertThrowsError(
            try selector.select(
                .init(
                    strategy: .singleFileReplace,
                    provider: .platformFile,
                    brokerAuthenticated: false,
                    targetRootOwned: true
                )
            )
        )
        XCTAssertThrowsError(
            try selector.select(
                .init(
                    strategy: .directoryReplace,
                    provider: .platformDirectory,
                    callerArguments: ["attacker"]
                )
            )
        )
    }

    func testVerifiedInstallerUsesFixedRunnerAndPostVerification() throws {
        let verifier = RecordingInstallerVerifier()
        let runner = RecordingInstallerRunner()
        let expectation = MacVerifiedInstallerExpectation(
            installerURL: URL(fileURLWithPath: "/sealed/Example.pkg"),
            kind: .pkg,
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            designatedRequirement: "identifier com.example.installer",
            artifactSHA256: String(repeating: "a", count: 64)
        )

        let result = try MacVerifiedInstallerHandoff(
            verifier: verifier,
            runner: runner
        ).execute(expectation)

        XCTAssertEqual(result, .init(identity: "provider-42", state: .completed))
        XCTAssertEqual(verifier.installerExpectation, expectation)
        XCTAssertEqual(verifier.installedIdentifier, "com.example.app")
        XCTAssertEqual(verifier.installedVersion, "2.0.0")
        XCTAssertEqual(runner.url, expectation.installerURL)
        XCTAssertEqual(runner.kind, .pkg)
        XCTAssertEqual(
            MacVerifiedInstallerHandoff(
                verifier: verifier,
                runner: runner
            ).recover(expectation, transactionIdentity: "provider-42"),
            .init(identity: "provider-42", state: .completed)
        )

        let dmgExpectation = MacVerifiedInstallerExpectation(
            installerURL: URL(fileURLWithPath: "/sealed/Installer.app"),
            kind: .dmgInstallerApplication,
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            designatedRequirement: "identifier com.example.installer",
            artifactSHA256: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(
            try MacVerifiedInstallerHandoff(
                verifier: verifier,
                runner: runner
            ).execute(dmgExpectation),
            .init(identity: "provider-42", state: .completed)
        )
        XCTAssertEqual(runner.kind, .dmgInstallerApplication)
    }
}

private final class RecordingInstallerVerifier: MacVerifiedInstallerChecking {
    var installerExpectation: MacVerifiedInstallerExpectation?
    var installedIdentifier: String?
    var installedVersion: String?

    func verifyInstaller(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws {
        installerExpectation = expectation
    }

    func verifyInstalledPackage(
        identifier: String,
        version: String
    ) throws {
        installedIdentifier = identifier
        installedVersion = version
    }
}

private final class RecordingInstallerRunner: MacFixedInstallerRunning {
    var url: URL?
    var kind: MacVerifiedInstallerKind?

    func launchVerifiedInstaller(
        at url: URL,
        kind: MacVerifiedInstallerKind
    ) throws -> String {
        self.url = url
        self.kind = kind
        return "provider-42"
    }
}
