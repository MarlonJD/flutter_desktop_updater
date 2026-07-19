import Darwin
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
            artifactSHA256: String(repeating: "a", count: 64),
            artifactLength: 1
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
            artifactSHA256: String(repeating: "b", count: 64),
            artifactLength: 1
        )
        XCTAssertThrowsError(
            try MacVerifiedInstallerHandoff(
                verifier: verifier,
                runner: runner
            ).execute(dmgExpectation)
        )
        XCTAssertEqual(runner.kind, .pkg)
    }

    func testSystemInstallerVerifierUsesFixedExecutablesAndLiteralPathArgument()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stage ; touch should-not-exist \(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = root.appendingPathComponent("installer.pkg")
        let bytes = Data("package".utf8)
        try bytes.write(to: installer)
        let application = try InstalledApplicationFixture()
        defer { application.remove() }
        let runner = RecordingInstallerCommandRunner(
            receiptVersions: ["com.example.app.pkg": "2.0.0"],
            expandedApplicationSource: application.bundleURL
        )
        let expectation = MacVerifiedInstallerExpectation(
            installerURL: installer,
            kind: .pkg,
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: macPrivilegeSHA256(bytes),
            artifactLength: Int64(bytes.count),
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "a", count: 64)
        )

        _ = try SystemMacVerifiedInstallerChecker(
            commandRunner: runner,
            ownershipValidator: AllowingInstallerOwnershipValidator()
        ).verifyInstaller(expectation)

        XCTAssertEqual(
            runner.commands.map(\.executable),
            [
                "/usr/sbin/pkgutil", "/usr/sbin/spctl", "/usr/bin/xcrun",
                "/usr/sbin/pkgutil", "/usr/bin/lsbom",
            ]
        )
        XCTAssertEqual(runner.commands[0].arguments, [
            "--check-signature", installer.path,
        ])
        XCTAssertEqual(runner.commands[1].arguments, [
            "--assess", "--type", "install", "--verbose=2",
            installer.path,
        ])
        XCTAssertEqual(runner.commands[2].arguments, [
            "stapler", "validate", installer.path,
        ])
        XCTAssertEqual(runner.commands[3].arguments[0 ... 1], [
            "--expand-full", installer.path,
        ])
        XCTAssertEqual(runner.commands[4].arguments[0 ... 1], ["-p", "fmug"])
    }

    func testSystemInstallerVerifierAcceptsRealProductbuildBundleTopology()
        throws
    {
        let application = try InstalledApplicationFixture(
            includeFrameworks: true
        )
        defer { application.remove() }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let component = output.appendingPathComponent("component.pkg")
        let installer = output.appendingPathComponent("installer.pkg")
        _ = try runInstallerTestProcess(
            "/usr/bin/pkgbuild",
            [
                "--root", application.rootURL.path,
                "--install-location", "/Applications",
                "--identifier", "com.example.app.pkg",
                "--version", "2.0.0",
                component.path,
            ]
        )
        _ = try runInstallerTestProcess(
            "/usr/bin/productbuild",
            ["--package", component.path, installer.path]
        )
        let bytes = try Data(contentsOf: installer, options: [.mappedIfSafe])
        let expectation = MacVerifiedInstallerExpectation(
            installerURL: installer,
            kind: .pkg,
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: macPrivilegeSHA256(bytes),
            artifactLength: Int64(bytes.count),
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "a", count: 64)
        )

        let evidence = try SystemMacVerifiedInstallerChecker(
            commandRunner: ProductbuildTopologyCommandRunner(),
            ownershipValidator: AllowingInstallerOwnershipValidator()
        ).verifyInstaller(expectation)

        XCTAssertEqual(
            evidence.receiptVersions,
            ["com.example.app.pkg": "2.0.0"]
        )
        XCTAssertEqual(evidence.executableSHA256, application.executableSHA256)
        XCTAssertEqual(evidence.bundleTreeSHA256, application.bundleTreeSHA256)
    }

    func testSystemInstallerVerifierAcceptsSingleSignedPreinstallTopology()
        throws
    {
        let application = try InstalledApplicationFixture(
            includeFrameworks: true
        )
        defer { application.remove() }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let scripts = output.appendingPathComponent(
            "scripts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: scripts,
            withIntermediateDirectories: false
        )
        let preinstall = scripts.appendingPathComponent("preinstall")
        try Data(
            """
            #!/bin/sh
            set -eu
            /usr/bin/true

            """.utf8
        ).write(to: preinstall)
        XCTAssertEqual(Darwin.chmod(preinstall.path, 0o755), 0)
        let component = output.appendingPathComponent("component.pkg")
        let installer = output.appendingPathComponent("installer.pkg")
        _ = try runInstallerTestProcess(
            "/usr/bin/pkgbuild",
            [
                "--root", application.rootURL.path,
                "--scripts", scripts.path,
                "--install-location", "/Applications",
                "--identifier", "com.example.app.pkg",
                "--version", "2.0.0",
                component.path,
            ]
        )
        _ = try runInstallerTestProcess(
            "/usr/bin/productbuild",
            ["--package", component.path, installer.path]
        )
        let bytes = try Data(contentsOf: installer, options: [.mappedIfSafe])
        let expectation = MacVerifiedInstallerExpectation(
            installerURL: installer,
            kind: .pkg,
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: macPrivilegeSHA256(bytes),
            artifactLength: Int64(bytes.count),
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "a", count: 64)
        )

        let evidence = try SystemMacVerifiedInstallerChecker(
            commandRunner: ProductbuildTopologyCommandRunner(),
            ownershipValidator: AllowingInstallerOwnershipValidator()
        ).verifyInstaller(expectation)

        XCTAssertEqual(
            evidence.receiptVersions,
            ["com.example.app.pkg": "2.0.0"]
        )
        XCTAssertEqual(evidence.executableSHA256, application.executableSHA256)
        XCTAssertEqual(evidence.bundleTreeSHA256, application.bundleTreeSHA256)
    }

    func testSystemInstallerVerifierRejectsSpecialModesFromRealPackageBOM()
        throws
    {
        for relativePath in [
            "Contents/MacOS/Example",
            "Contents/Helpers/DesktopUpdaterInstallHelper",
            "Contents/resource.txt",
        ] {
            let application = try InstalledApplicationFixture()
            defer { application.remove() }
            let privilegedNode = application.bundleURL
                .appendingPathComponent(relativePath)
            XCTAssertEqual(Darwin.chmod(privilegedNode.path, 0o4755), 0)
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: output) }
            let component = output.appendingPathComponent("component.pkg")
            let installer = output.appendingPathComponent("installer.pkg")
            _ = try runInstallerTestProcess(
                "/usr/bin/pkgbuild",
                [
                    "--root", application.rootURL.path,
                    "--install-location", "/Applications",
                    "--identifier", "com.example.app.pkg",
                    "--version", "2.0.0",
                    component.path,
                ]
            )
            _ = try runInstallerTestProcess(
                "/usr/bin/productbuild",
                ["--package", component.path, installer.path]
            )
            let bytes = try Data(
                contentsOf: installer,
                options: [.mappedIfSafe]
            )
            let expectation = MacVerifiedInstallerExpectation(
                installerURL: installer,
                kind: .pkg,
                targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
                packageIdentifier: "com.example.app",
                expectedVersion: "2.0.0",
                expectedBuildNumber: 200,
                designatedRequirement: "identifier com.example.app",
                artifactSHA256: macPrivilegeSHA256(bytes),
                artifactLength: Int64(bytes.count),
                expectedPackageIdentifiers: ["com.example.app.pkg"],
                descriptorSHA256: String(repeating: "d", count: 64),
                provenanceSHA256: String(repeating: "a", count: 64)
            )
            let packagedMode = try installerTestBOMMode(
                component: component,
                relativePath: "Example.app/\(relativePath)",
                output: output
            )
            let verify = {
                try SystemMacVerifiedInstallerChecker(
                    commandRunner: ProductbuildTopologyCommandRunner(),
                    ownershipValidator: AllowingInstallerOwnershipValidator()
                ).verifyInstaller(expectation)
            }
            if packagedMode & 0o7000 == 0 {
                XCTAssertNoThrow(try verify(), relativePath)
            } else {
                XCTAssertThrowsError(try verify(), relativePath)
            }
        }
    }

    func testSystemInstallerVerifierRejectsPreservedNonRootOwnershipFromRealPackageBOM()
        throws
    {
        let application = try InstalledApplicationFixture()
        defer { application.remove() }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let component = output.appendingPathComponent("component.pkg")
        let installer = output.appendingPathComponent("installer.pkg")
        _ = try runInstallerTestProcess(
            "/usr/bin/pkgbuild",
            [
                "--root", application.rootURL.path,
                "--ownership", "preserve",
                "--install-location", "/Applications",
                "--identifier", "com.example.app.pkg",
                "--version", "2.0.0",
                component.path,
            ]
        )
        _ = try runInstallerTestProcess(
            "/usr/bin/productbuild",
            ["--package", component.path, installer.path]
        )
        let bytes = try Data(contentsOf: installer, options: [.mappedIfSafe])
        let expectation = MacVerifiedInstallerExpectation(
            installerURL: installer,
            kind: .pkg,
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: macPrivilegeSHA256(bytes),
            artifactLength: Int64(bytes.count),
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertThrowsError(
            try SystemMacVerifiedInstallerChecker(
                commandRunner: ProductbuildTopologyCommandRunner(),
                ownershipValidator: AllowingInstallerOwnershipValidator()
            ).verifyInstaller(expectation)
        )
    }

    func testSystemInstallerVerifierRejectsUnsafeOrInaccessibleRealBOMModes()
        throws
    {
        for (relativePath, mode) in [
            ("Contents/resource.txt", mode_t(0o666)),
            ("Contents/Helpers", mode_t(0o777)),
            ("Contents/MacOS/Example", mode_t(0o710)),
            (
                "Contents/Helpers/DesktopUpdaterInstallHelper",
                mode_t(0o710)
            ),
            ("Contents", mode_t(0o700)),
            ("Contents/Info.plist", mode_t(0o600)),
        ] {
            let application = try InstalledApplicationFixture()
            defer { application.remove() }
            let writableNode = application.bundleURL
                .appendingPathComponent(relativePath)
            XCTAssertEqual(Darwin.chmod(writableNode.path, mode), 0)
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: output) }
            let component = output.appendingPathComponent("component.pkg")
            let installer = output.appendingPathComponent("installer.pkg")
            _ = try runInstallerTestProcess(
                "/usr/bin/pkgbuild",
                [
                    "--root", application.rootURL.path,
                    "--install-location", "/Applications",
                    "--identifier", "com.example.app.pkg",
                    "--version", "2.0.0",
                    component.path,
                ]
            )
            _ = try runInstallerTestProcess(
                "/usr/bin/productbuild",
                ["--package", component.path, installer.path]
            )
            let bytes = try Data(
                contentsOf: installer,
                options: [.mappedIfSafe]
            )
            let expectation = MacVerifiedInstallerExpectation(
                installerURL: installer,
                kind: .pkg,
                targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
                packageIdentifier: "com.example.app",
                expectedVersion: "2.0.0",
                expectedBuildNumber: 200,
                designatedRequirement: "identifier com.example.app",
                artifactSHA256: macPrivilegeSHA256(bytes),
                artifactLength: Int64(bytes.count),
                expectedPackageIdentifiers: ["com.example.app.pkg"],
                descriptorSHA256: String(repeating: "d", count: 64),
                provenanceSHA256: String(repeating: "a", count: 64)
            )

            XCTAssertThrowsError(
                try SystemMacVerifiedInstallerChecker(
                    commandRunner: ProductbuildTopologyCommandRunner(),
                    ownershipValidator: AllowingInstallerOwnershipValidator()
                ).verifyInstaller(expectation),
                relativePath
            )
        }
    }

    func testSystemInstallerVerifierRejectsOversizedRealPackageInfoPlist()
        throws
    {
        let application = try InstalledApplicationFixture()
        defer { application.remove() }
        try Data(repeating: 0x41, count: 1_048_577).write(
            to: application.bundleURL.appendingPathComponent(
                "Contents/Info.plist"
            )
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let component = output.appendingPathComponent("component.pkg")
        let installer = output.appendingPathComponent("installer.pkg")
        _ = try runInstallerTestProcess(
            "/usr/bin/pkgbuild",
            [
                "--root", application.rootURL.path,
                "--install-location", "/Applications",
                "--identifier", "com.example.app.pkg",
                "--version", "2.0.0",
                component.path,
            ]
        )
        _ = try runInstallerTestProcess(
            "/usr/bin/productbuild",
            ["--package", component.path, installer.path]
        )
        let bytes = try Data(contentsOf: installer, options: [.mappedIfSafe])
        let expectation = MacVerifiedInstallerExpectation(
            installerURL: installer,
            kind: .pkg,
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: macPrivilegeSHA256(bytes),
            artifactLength: Int64(bytes.count),
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertThrowsError(
            try SystemMacVerifiedInstallerChecker(
                commandRunner: ProductbuildTopologyCommandRunner(),
                ownershipValidator: AllowingInstallerOwnershipValidator()
            ).verifyInstaller(expectation)
        )
    }

    func testSystemInstallerVerifierRejectsUnsupportedInstallTopology()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = root.appendingPathComponent("installer.pkg")
        let bytes = Data("package".utf8)
        try bytes.write(to: installer)
        let application = try InstalledApplicationFixture()
        defer { application.remove() }
        let expectation = MacVerifiedInstallerExpectation(
            installerURL: installer,
            kind: .pkg,
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: macPrivilegeSHA256(bytes),
            artifactLength: Int64(bytes.count),
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "a", count: 64)
        )

        for mutation in ExpandedPackageMutation.allCases {
            XCTAssertThrowsError(
                try SystemMacVerifiedInstallerChecker(
                    commandRunner: RecordingInstallerCommandRunner(
                        expandedApplicationSource: application.bundleURL,
                        expandedMutation: mutation
                    )
                ).verifyInstaller(expectation),
                mutation.rawValue
            )
        }
    }

    func testSystemInstallerVerifierBindsInstalledAppAndReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let bundle = root.appendingPathComponent("Example.app")
        let executable = bundle.appendingPathComponent(
            "Contents/MacOS/Example"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executable
        )
        let helper = bundle.appendingPathComponent(
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: helper
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Example",
                "CFBundleShortVersionString": "2.0.0",
                "CFBundleVersion": "200",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        ).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = [
            "--force", "--deep", "--sign", "-", "--identifier",
            "com.example.app",
            "-r=designated => identifier com.example.app",
            bundle.path,
        ]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let executableSHA256 = macPrivilegeSHA256(
            try Data(contentsOf: executable, options: [.mappedIfSafe])
        )
        let bundleTreeSHA256 = try macAuthorizedTreeSHA256(bundle)
        let runner = RecordingInstallerCommandRunner(
            receiptVersions: [
                "com.example.app.pkg": "2.0.0-component.1",
            ]
        )

        try SystemMacVerifiedInstallerChecker(
            commandRunner: runner,
            ownershipValidator: AllowingInstallerOwnershipValidator()
        ).verifyInstalledApplication(
            MacVerifiedInstallerExpectation(
                installerURL: root.appendingPathComponent("installer.pkg"),
                kind: .pkg,
                targetURL: bundle,
                packageIdentifier: "com.example.app",
                expectedVersion: "2.0.0",
                expectedBuildNumber: 200,
                designatedRequirement: "identifier com.example.app",
                artifactSHA256: String(repeating: "a", count: 64),
                artifactLength: 1,
                expectedPackageIdentifiers: ["com.example.app.pkg"],
                expectedReceiptVersions: [
                    "com.example.app.pkg": "2.0.0-component.1",
                ],
                expectedExecutableSHA256: executableSHA256,
                expectedBundleTreeSHA256: bundleTreeSHA256,
                descriptorSHA256: String(repeating: "d", count: 64),
                provenanceSHA256: String(repeating: "b", count: 64)
            )
        )

        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands[0].executable, "/usr/sbin/pkgutil")
        XCTAssertEqual(runner.commands[0].arguments, [
            "--pkg-info-plist", "com.example.app.pkg",
        ])
    }

    func testInstalledReceiptVersionMustMatchHashBoundPackageEvidence()
        throws
    {
        let fixture = try InstalledApplicationFixture()
        defer { fixture.remove() }
        let runner = RecordingInstallerCommandRunner(
            receiptVersions: ["com.example.app.pkg": "1.0.0-stale"]
        )

        XCTAssertThrowsError(
            try SystemMacVerifiedInstallerChecker(
                commandRunner: runner,
                ownershipValidator: AllowingInstallerOwnershipValidator()
            ).verifyInstalledApplication(
                fixture.expectation(
                    receiptVersions: [
                        "com.example.app.pkg": "2.0.0-component.1",
                    ]
                )
            )
        )
    }

    func testInstalledApplicationRejectsNonExecutableMainOrHelper() throws {
        for keyPath in [
            \InstalledApplicationFixture.executableURL,
            \InstalledApplicationFixture.helperURL,
        ] {
            let fixture = try InstalledApplicationFixture()
            defer { fixture.remove() }
            let expectation = fixture.expectation(
                receiptVersions: [
                    "com.example.app.pkg": "2.0.0-component.1",
                ]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: fixture[keyPath: keyPath].path
            )

            XCTAssertThrowsError(
                try SystemMacVerifiedInstallerChecker(
                    commandRunner: RecordingInstallerCommandRunner(
                        receiptVersions: [
                            "com.example.app.pkg": "2.0.0-component.1",
                        ]
                    ),
                    ownershipValidator:
                        AllowingInstallerOwnershipValidator()
                ).verifyInstalledApplication(expectation)
            )
        }
    }

    func testInstalledApplicationMustBeRootOwnedAndNotWritable() throws {
        let fixture = try InstalledApplicationFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try SystemMacVerifiedInstallerChecker(
                commandRunner: RecordingInstallerCommandRunner(
                    receiptVersions: ["com.example.app.pkg": "2.0.0"]
                )
            ).verifyInstalledApplication(
                fixture.expectation(
                    receiptVersions: ["com.example.app.pkg": "2.0.0"]
                )
            )
        )
    }

    func testInstalledApplicationRejectsOversizedInfoPlistBeforeParsing()
        throws
    {
        let fixture = try InstalledApplicationFixture()
        defer { fixture.remove() }
        try Data(repeating: 0x41, count: 1_048_577).write(
            to: fixture.bundleURL.appendingPathComponent(
                "Contents/Info.plist"
            )
        )

        XCTAssertThrowsError(
            try SystemMacVerifiedInstallerChecker(
                commandRunner: RecordingInstallerCommandRunner(
                    receiptVersions: ["com.example.app.pkg": "2.0.0"]
                ),
                ownershipValidator: AllowingInstallerOwnershipValidator()
            ).verifyInstalledApplication(
                fixture.expectation(
                    receiptVersions: ["com.example.app.pkg": "2.0.0"]
                )
            )
        )
    }

    func testInstalledApplicationTreeMustMatchHashBoundPackageEvidence()
        throws
    {
        let expected = try InstalledApplicationFixture(resource: "expected")
        defer { expected.remove() }
        let installed = try InstalledApplicationFixture(resource: "different")
        defer { installed.remove() }
        let expectation = expected.expectation(
            targetURL: installed.bundleURL,
            receiptVersions: ["com.example.app.pkg": "2.0.0"]
        )

        XCTAssertThrowsError(
            try SystemMacVerifiedInstallerChecker(
                commandRunner: RecordingInstallerCommandRunner(
                    receiptVersions: ["com.example.app.pkg": "2.0.0"]
                ),
                ownershipValidator: AllowingInstallerOwnershipValidator()
            ).verifyInstalledApplication(expectation)
        )
    }
}

private final class RecordingInstallerVerifier: MacVerifiedInstallerChecking {
    var installerExpectation: MacVerifiedInstallerExpectation?
    var installedIdentifier: String?
    var installedVersion: String?

    func verifyInstaller(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> MacVerifiedInstallerSecurityEvidence {
        installerExpectation = expectation
        return MacVerifiedInstallerSecurityEvidence(
            receiptVersions: Dictionary(
                uniqueKeysWithValues:
                    expectation.expectedPackageIdentifiers.map {
                        ($0, expectation.expectedVersion)
                    }
            ),
            executableSHA256: String(repeating: "e", count: 64),
            bundleTreeSHA256: String(repeating: "f", count: 64)
        )
    }

    func verifyInstalledPackage(
        identifier: String,
        version: String
    ) throws {
        installedIdentifier = identifier
        installedVersion = version
    }
}

private struct AllowingInstallerOwnershipValidator:
    MacInstalledApplicationOwnershipValidating
{
    func validate(_: URL) throws {}
}

private final class RecordingInstallerRunner: MacFixedInstallerRunning {
    var url: URL?
    var kind: MacVerifiedInstallerKind?

    func spawnVerifiedInstaller(
        at url: URL,
        kind: MacVerifiedInstallerKind
    ) throws -> any MacGatedInstallerWorker {
        self.url = url
        self.kind = kind
        return RecordingInstallerWorker()
    }
}

private final class RecordingInstallerWorker: MacGatedInstallerWorker {
    let identity = MacInstallerWorkerIdentity(
        processIdentifier: 999_999,
        processStartIdentity: "macos:1:1",
        providerTransactionIdentity: "provider-42"
    )

    func releaseAndWait() throws {}
}

private final class RecordingInstallerCommandRunner:
    MacInstallerCommandRunning
{
    struct Command {
        let executable: String
        let arguments: [String]
    }

    private(set) var commands: [Command] = []
    private let receiptVersions: [String: String]
    private let expandedApplicationSource: URL?
    private let expandedMutation: ExpandedPackageMutation?
    private var expandedPayload: URL?

    init(
        receiptVersions: [String: String] = [:],
        expandedApplicationSource: URL? = nil,
        expandedMutation: ExpandedPackageMutation? = nil
    ) {
        self.receiptVersions = receiptVersions
        self.expandedApplicationSource = expandedApplicationSource
        self.expandedMutation = expandedMutation
    }

    func run(executable: String, arguments: [String]) throws -> Data {
        commands.append(Command(executable: executable, arguments: arguments))
        if executable == "/usr/sbin/pkgutil",
           arguments.first == "--pkg-info-plist" {
            return try PropertyListSerialization.data(
                fromPropertyList: [
                    "pkgid": arguments[1],
                    "pkg-version": receiptVersions[arguments[1]]
                        ?? "2.0.0-component.1",
                ],
                format: .xml,
                options: 0
            )
        }
        if executable == "/usr/sbin/pkgutil",
           arguments.first == "--expand-full" {
            let expanded = URL(fileURLWithPath: arguments[2])
            try FileManager.default.createDirectory(
                at: expanded,
                withIntermediateDirectories: true
            )
            let packageRoot = expanded.appendingPathComponent(
                "component.pkg",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: packageRoot,
                withIntermediateDirectories: true
            )
            let installLocation = expandedMutation == .wrongInstallLocation
                ? "/Library" : "/Applications"
            let bundlePath = expandedMutation == .escapedBundlePath
                ? "../Example.app" : "./Example.app"
            try Data(
                """
                <pkg-info identifier="com.example.app.pkg" version="2.0.0" install-location="\(installLocation)" auth="root" relocatable="false" postinstall-action="none"><payload/><bundle-version><bundle id="com.example.app"/></bundle-version><upgrade-bundle><bundle id="com.example.app"/></upgrade-bundle><update-bundle/><atomic-update-bundle/><strict-identifier><bundle id="com.example.app"/></strict-identifier><relocate><bundle id="com.example.app"/></relocate><bundle CFBundleShortVersionString="2.0.0" CFBundleVersion="200" id="com.example.app" path="\(bundlePath)"/></pkg-info>
                """.utf8
            ).write(to: packageRoot.appendingPathComponent("PackageInfo"))
            try Data("bom".utf8).write(
                to: packageRoot.appendingPathComponent("Bom")
            )
            let payload = packageRoot.appendingPathComponent(
                "Payload",
                isDirectory: true
            )
            expandedPayload = payload
            try FileManager.default.createDirectory(
                at: payload,
                withIntermediateDirectories: true
            )
            if let expandedApplicationSource {
                try FileManager.default.copyItem(
                    at: expandedApplicationSource,
                    to: payload.appendingPathComponent("Example.app")
                )
            }
            if expandedMutation == .scripts {
                try FileManager.default.createDirectory(
                    at: packageRoot.appendingPathComponent("Scripts"),
                    withIntermediateDirectories: true
                )
            }
            if expandedMutation == .extraPayload {
                try Data("unrelated root mutation".utf8).write(
                    to: payload.appendingPathComponent("unrelated.txt")
                )
            }
            if expandedMutation == .extraComponent {
                let extra = expanded.appendingPathComponent(
                    "unselected.pkg",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: extra,
                    withIntermediateDirectories: true
                )
                try Data(
                    #"<pkg-info identifier="com.example.unselected" version="1.0.0" install-location="/" auth="root"><payload/></pkg-info>"#.utf8
                ).write(to: extra.appendingPathComponent("PackageInfo"))
            }
            try Data(
                """
                <installer-gui-script minSpecVersion="1"><pkg-ref id="com.example.app.pkg"><bundle-version><bundle CFBundleShortVersionString="2.0.0" CFBundleVersion="200" id="com.example.app" path="Example.app"/></bundle-version></pkg-ref><options customize="never" require-scripts="false"/><choices-outline><line choice="default"><line choice="com.example.app.pkg"/></line></choices-outline><choice id="default"/><choice id="com.example.app.pkg" visible="false"><pkg-ref id="com.example.app.pkg"/></choice><pkg-ref id="com.example.app.pkg" version="2.0.0" onConclusion="none">#component.pkg</pkg-ref></installer-gui-script>
                """.utf8
            ).write(to: expanded.appendingPathComponent("Distribution"))
        }
        if executable == "/usr/bin/lsbom" {
            guard let expandedPayload else {
                throw CocoaError(.fileReadUnknown)
            }
            return try installerTestBOMListing(
                payload: expandedPayload,
                injectSetuidResource: expandedMutation == .setuidBOM
            )
        }
        return Data()
    }
}

private final class ProductbuildTopologyCommandRunner:
    MacInstallerCommandRunning
{
    func run(executable: String, arguments: [String]) throws -> Data {
        if executable == "/usr/sbin/pkgutil",
           arguments.first == "--expand-full" {
            _ = try runInstallerTestProcess(executable, arguments)
        }
        if executable == "/usr/bin/lsbom" {
            return try runInstallerTestProcess(executable, arguments)
        }
        return Data()
    }
}

private enum ExpandedPackageMutation: String, CaseIterable {
    case extraComponent
    case wrongInstallLocation
    case scripts
    case extraPayload
    case escapedBundlePath
    case setuidBOM
}

private func installerTestBOMListing(
    payload: URL,
    injectSetuidResource: Bool
) throws -> Data {
    var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard payload.path.withCString({ Darwin.realpath($0, &canonicalBuffer) })
        != nil else {
        throw CocoaError(.fileReadUnknown)
    }
    let canonicalPayload = URL(
        fileURLWithPath: String(cString: canonicalBuffer)
    )
    var root = stat()
    guard canonicalPayload.path.withCString({ Darwin.lstat($0, &root) }) == 0
    else {
        throw CocoaError(.fileReadUnknown)
    }
    var lines = [
        ".\t\(String(UInt32(root.st_mode), radix: 8))\t0\t0",
    ]
    guard let enumerator = FileManager.default.enumerator(
        at: canonicalPayload,
        includingPropertiesForKeys: nil
    ) else {
        throw CocoaError(.fileReadUnknown)
    }
    let prefix = canonicalPayload.path + "/"
    for case let url as URL in enumerator {
        guard url.path.hasPrefix(prefix) else {
            throw CocoaError(.fileReadUnknown)
        }
        let relative = String(url.path.dropFirst(prefix.count))
        var value = stat()
        guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        var mode = UInt32(value.st_mode)
        if injectSetuidResource,
           relative == "Example.app/Contents/resource.txt" {
            mode |= 0o4000
        }
        lines.append("./\(relative)\t\(String(mode, radix: 8))\t0\t0")
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func installerTestBOMMode(
    component: URL,
    relativePath: String,
    output: URL
) throws -> UInt32 {
    let expanded = output.appendingPathComponent(
        "bom-\(UUID().uuidString)",
        isDirectory: true
    )
    _ = try runInstallerTestProcess(
        "/usr/sbin/pkgutil",
        ["--expand", component.path, expanded.path]
    )
    let listing = try runInstallerTestProcess(
        "/usr/bin/lsbom",
        ["-p", "fmug", expanded.appendingPathComponent("Bom").path]
    )
    let text = String(decoding: listing, as: UTF8.self)
    let prefix = "./\(relativePath)\t"
    guard let line = text.split(separator: "\n").first(where: {
        $0.hasPrefix(prefix)
    }),
        let modeText = line.split(separator: "\t").dropFirst().first,
        let mode = UInt32(modeText, radix: 8) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return mode
}

private final class InstalledApplicationFixture {
    let rootURL: URL
    let bundleURL: URL
    let executableURL: URL
    let helperURL: URL
    let executableSHA256: String
    let bundleTreeSHA256: String

    init(
        resource: String = "resource",
        includeFrameworks: Bool = false
    ) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        bundleURL = rootURL.appendingPathComponent("Example.app")
        executableURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/Example"
        )
        helperURL = bundleURL.appendingPathComponent(
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executableURL
        )
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: helperURL
        )
        if includeFrameworks {
            try createInstallerTestFramework(
                in: bundleURL,
                name: "App",
                identifier: "io.flutter.flutter.app"
            )
            try createInstallerTestFramework(
                in: bundleURL,
                name: "FlutterMacOS",
                identifier: "io.flutter.flutter-macos"
            )
        }
        try Data(resource.utf8).write(
            to: bundleURL.appendingPathComponent("Contents/resource.txt")
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Example",
                "CFBundleShortVersionString": "2.0.0",
                "CFBundleVersion": "200",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        ).write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try signBundle(bundleURL)
        executableSHA256 = macPrivilegeSHA256(
            try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        )
        bundleTreeSHA256 = try macAuthorizedTreeSHA256(bundleURL)
    }

    func expectation(
        targetURL: URL? = nil,
        receiptVersions: [String: String]
    ) -> MacVerifiedInstallerExpectation {
        MacVerifiedInstallerExpectation(
            installerURL: rootURL.appendingPathComponent("installer.pkg"),
            kind: .pkg,
            targetURL: targetURL ?? bundleURL,
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: String(repeating: "a", count: 64),
            artifactLength: 1,
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            expectedReceiptVersions: receiptVersions,
            expectedExecutableSHA256: executableSHA256,
            expectedBundleTreeSHA256: bundleTreeSHA256,
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "b", count: 64)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func createInstallerTestFramework(
    in application: URL,
    name: String,
    identifier: String
) throws {
    let framework = application.appendingPathComponent(
        "Contents/Frameworks/\(name).framework",
        isDirectory: true
    )
    let version = framework.appendingPathComponent(
        "Versions/A",
        isDirectory: true
    )
    let executable = version.appendingPathComponent(name)
    let resources = version.appendingPathComponent(
        "Resources",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: resources,
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/usr/bin/true"),
        to: executable
    )
    try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": name,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "100",
            "CFBundlePackageType": "FMWK",
        ],
        format: .xml,
        options: 0
    ).write(to: resources.appendingPathComponent("Info.plist"))
    try FileManager.default.createSymbolicLink(
        atPath: framework.appendingPathComponent("Versions/Current").path,
        withDestinationPath: "A"
    )
    try FileManager.default.createSymbolicLink(
        atPath: framework.appendingPathComponent(name).path,
        withDestinationPath: "Versions/Current/\(name)"
    )
    try FileManager.default.createSymbolicLink(
        atPath: framework.appendingPathComponent("Resources").path,
        withDestinationPath: "Versions/Current/Resources"
    )
}

private func runInstallerTestProcess(
    _ executable: String,
    _ arguments: [String]
) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "InstallerTopologyTest",
            code: Int(process.terminationStatus),
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(decoding: data, as: UTF8.self),
            ]
        )
    }
    return data
}

private func signBundle(_ bundleURL: URL) throws {
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = [
        "--force", "--deep", "--sign", "-", "--identifier",
        "com.example.app",
        "-r=designated => identifier com.example.app",
        bundleURL.path,
    ]
    try sign.run()
    sign.waitUntilExit()
    guard sign.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}
