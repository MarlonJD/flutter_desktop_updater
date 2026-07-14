import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacPrivilegeServiceTests: XCTestCase {
    func testConfigurationPlistsMatchReciprocalRequirementsAndMachLabel()
        throws
    {
        let configuration = try sealedPrivilegeConfiguration()
        let directory = try helperRepositoryRoot()
            .appendingPathComponent("macos/install_helper/Configuration")

        try configuration.validatePlists(in: directory)
        XCTAssertEqual(
            configuration.serviceIdentifier,
            "com.example.desktop-updater.helper"
        )
    }

    func testHelperInfoReloadsTheSealedPolicyAndDigest() throws {
        let infoURL = try helperRepositoryRoot()
            .appendingPathComponent(
                "macos/install_helper/Configuration/Helper-Info.plist"
            )
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            options: [],
            format: nil
        )
        let info = try XCTUnwrap(value as? [String: Any])

        XCTAssertEqual(
            try MacPrivilegeConfiguration.fromEmbeddedInfoDictionary(info),
            try sealedPrivilegeConfiguration()
        )
    }

    func testRejectsPrivilegeConfigurationWithWrongSealedDigest() throws {
        let fixture = try sealedPrivilegePolicyFixture()

        XCTAssertThrowsError(
            try MacPrivilegeConfiguration.fromSealedPolicy(
                fixture.data,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        )
    }

    func testXPCRequirementBindsCallerToSignedHelperTeam() throws {
        XCTAssertEqual(
            try MacXPCPeerRequirement.make(
                applicationRequirement:
                    "identifier com.example.app and anchor apple generic",
                helperTeamIdentifier: "EXAMPLETEAM"
            ),
            "(identifier com.example.app and anchor apple generic) "
                + "and certificate leaf[subject.OU] = \"EXAMPLETEAM\""
        )
        for invalid in ["", "TEAM WITH SPACE", "TEAM\" OR true"] {
            XCTAssertThrowsError(
                try MacXPCPeerRequirement.make(
                    applicationRequirement: "identifier com.example.app",
                    helperTeamIdentifier: invalid
                )
            )
        }
    }

    func testBlessesOnlyIdenticalFixedNestedPayloads() throws {
        let fixture = try PrivilegeFixture()
        defer { fixture.remove() }

        try fixture.service.installPrivilegedHelper()

        XCTAssertEqual(
            fixture.installer.installedLabels,
            ["com.example.desktop-updater.helper"]
        )
        XCTAssertEqual(
            fixture.checker.checkedURLs.map(\.path),
            [
                fixture.applicationURL.path,
                fixture.oneShotURL.path,
                fixture.privilegedURL.path,
            ]
        )
    }

    func testRejectsWrongTeamUnsignedNestedHelperAndPayloadMismatch() throws {
        let mutations: [(String, (PrivilegeFixture) throws -> Void)] = [
            ("wrong team", { $0.checker.privilegedIdentity.teamIdentifier = "ATTACKER" }),
            ("unsigned helper", { $0.checker.privilegedIdentity.isSignatureValid = false }),
            ("payload mismatch", {
                try Data("different".utf8).write(to: $0.privilegedURL)
            }),
        ]

        for (name, mutate) in mutations {
            let fixture = try PrivilegeFixture()
            defer { fixture.remove() }
            try mutate(fixture)
            XCTAssertThrowsError(
                try fixture.service.installPrivilegedHelper(),
                name
            )
            XCTAssertTrue(fixture.installer.installedLabels.isEmpty)
        }
    }

    func testRejectsSpoofedXPCAuditToken() throws {
        let fixture = try PrivilegeFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try fixture.service.authenticatePrivilegedPeer(
                connectionAuditToken: Data(repeating: 1, count: 32),
                claimedAuditToken: Data(repeating: 2, count: 32)
            )
        ) { error in
            XCTAssertEqual(
                error as? MacPrivilegeError,
                .peerAuthenticationFailed
            )
        }
    }

    func testAuthenticatesXPCPeerFromConnectionAuditToken() throws {
        let fixture = try PrivilegeFixture()
        defer { fixture.remove() }
        let token = Data(repeating: 1, count: 32)

        let identity = try fixture.service.authenticatePrivilegedPeer(
            connectionAuditToken: token,
            claimedAuditToken: token
        )

        XCTAssertEqual(identity.bundleIdentifier, "com.example.app")
        XCTAssertEqual(fixture.checker.runningAuditTokens, [token])
    }

    func testInvalidBlessingAndAuthorizationCancellationFailClosed() throws {
        for failure in [
            MacPrivilegeInstallError.invalidBlessing,
            .authorizationCancelled,
        ] {
            let fixture = try PrivilegeFixture(installerFailure: failure)
            defer { fixture.remove() }

            XCTAssertThrowsError(
                try fixture.service.installPrivilegedHelper()
            ) { error in
                XCTAssertEqual(error as? MacPrivilegeInstallError, failure)
            }
        }
    }
}

private final class PrivilegeFixture {
    let rootURL: URL
    let applicationURL: URL
    let oneShotURL: URL
    let privilegedURL: URL
    let checker: FixturePrivilegeIdentityChecker
    let installer: FixturePrivilegeInstaller
    let service: MacPrivilegeService

    init(installerFailure: MacPrivilegeInstallError? = nil) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        applicationURL = rootURL.appendingPathComponent("Example.app")
        oneShotURL = applicationURL.appendingPathComponent(
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        privilegedURL = applicationURL.appendingPathComponent(
            "Contents/Library/LaunchServices/"
                + "com.example.desktop-updater.helper"
        )
        try FileManager.default.createDirectory(
            at: oneShotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: privilegedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = Data("identical signed helper".utf8)
        try bytes.write(to: oneShotURL)
        try bytes.write(to: privilegedURL)

        let identity = MacSignedExecutableIdentity(
            bundleIdentifier: "com.example.desktop-updater.helper",
            teamIdentifier: "EXAMPLETEAM",
            designatedRequirement:
                "identifier com.example.desktop-updater.helper "
                + "and anchor apple generic",
            sha256: macPrivilegeSHA256(bytes),
            isSignatureValid: true
        )
        let applicationIdentity = MacSignedExecutableIdentity(
            bundleIdentifier: "com.example.app",
            teamIdentifier: "EXAMPLETEAM",
            designatedRequirement:
                "identifier com.example.app and anchor apple generic",
            sha256: "",
            isSignatureValid: true
        )
        checker = FixturePrivilegeIdentityChecker(
            applicationIdentity: applicationIdentity,
            oneShotIdentity: identity,
            privilegedIdentity: identity
        )
        installer = FixturePrivilegeInstaller(failure: installerFailure)
        service = MacPrivilegeService(
            configuration: try sealedPrivilegeConfiguration(),
            applicationBundleURL: applicationURL,
            identityChecker: checker,
            installer: installer
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class FixturePrivilegeIdentityChecker:
    MacSignedExecutableIdentityChecking
{
    var oneShotIdentity: MacSignedExecutableIdentity
    var privilegedIdentity: MacSignedExecutableIdentity
    var applicationIdentity: MacSignedExecutableIdentity
    var checkedURLs: [URL] = []
    var runningAuditTokens: [Data] = []

    init(
        applicationIdentity: MacSignedExecutableIdentity,
        oneShotIdentity: MacSignedExecutableIdentity,
        privilegedIdentity: MacSignedExecutableIdentity
    ) {
        self.applicationIdentity = applicationIdentity
        self.oneShotIdentity = oneShotIdentity
        self.privilegedIdentity = privilegedIdentity
    }

    func identity(
        at url: URL,
        requirement _: String
    ) throws -> MacSignedExecutableIdentity {
        checkedURLs.append(url)
        if url.path.hasSuffix("Example.app") {
            return applicationIdentity
        }
        if url.lastPathComponent == "DesktopUpdaterInstallHelper" {
            return oneShotIdentity
        }
        return privilegedIdentity
    }

    func runningIdentity(
        auditToken: Data,
        requirement _: String
    ) throws -> MacSignedExecutableIdentity {
        runningAuditTokens.append(auditToken)
        return applicationIdentity
    }
}

private final class FixturePrivilegeInstaller: MacPrivilegeInstalling {
    var installedLabels: [String] = []
    let failure: MacPrivilegeInstallError?

    init(failure: MacPrivilegeInstallError?) {
        self.failure = failure
    }

    func install(serviceIdentifier: String) throws {
        if let failure {
            throw failure
        }
        installedLabels.append(serviceIdentifier)
    }
}

private func helperRepositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("macos/install_helper").path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func sealedPrivilegeConfiguration() throws
    -> MacPrivilegeConfiguration
{
    let fixture = try sealedPrivilegePolicyFixture()
    return try MacPrivilegeConfiguration.fromSealedPolicy(
        fixture.data,
        expectedSHA256: fixture.sha256
    )
}

private func sealedPrivilegePolicyFixture() throws
    -> (data: Data, sha256: String)
{
    let fixtureURL = try helperRepositoryRoot()
        .appendingPathComponent(
            "fixtures/compat/native-install-helper/v1/policy-cases.json"
        )
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
            as? [String: Any]
    )
    let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
    let fixture = try XCTUnwrap(
        cases.first { $0["name"] as? String == "valid privileged policy" }
    )
    let canonicalJSON = try XCTUnwrap(fixture["canonicalJson"] as? String)
    return (
        Data(canonicalJSON.utf8),
        try XCTUnwrap(fixture["canonicalSha256"] as? String)
    )
}
