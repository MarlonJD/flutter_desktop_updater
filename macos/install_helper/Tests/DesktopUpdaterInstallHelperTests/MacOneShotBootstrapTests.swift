import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacOneShotBootstrapTests: XCTestCase {
    func testBuildsAuthenticatedProductionRuntimeFromEmbeddedPolicy() throws {
        let fixture = try MacOneShotBootstrapFixture()
        defer { fixture.remove() }
        let checker = BootstrapIdentityChecker(
            identity: MacSignedExecutableIdentity(
                bundleIdentifier: fixture.helperServiceID,
                teamIdentifier: "TEAM123456",
                designatedRequirement: fixture.helperRequirement,
                sha256: "",
                isSignatureValid: true
            )
        )

        let runtime = try MacOneShotBootstrap.makeRuntime(
            infoDictionary: fixture.infoDictionary,
            executableURL: fixture.executableURL,
            identityChecker: checker
        )

        XCTAssertEqual(
            runtime.helperEndpointIdentitySHA256,
            macPrivilegeSHA256(fixture.executableData)
        )
        XCTAssertEqual(checker.inspectedURL, fixture.executableURL)
        XCTAssertEqual(checker.requirement, fixture.helperRequirement)
    }

    func testRejectsHelperWhoseSignedIdentityDoesNotMatchSealedPolicy()
        throws
    {
        let fixture = try MacOneShotBootstrapFixture()
        defer { fixture.remove() }
        let checker = BootstrapIdentityChecker(
            identity: MacSignedExecutableIdentity(
                bundleIdentifier: "com.attacker.helper",
                teamIdentifier: "TEAM123456",
                designatedRequirement: fixture.helperRequirement,
                sha256: "",
                isSignatureValid: true
            )
        )

        XCTAssertThrowsError(
            try MacOneShotBootstrap.makeRuntime(
                infoDictionary: fixture.infoDictionary,
                executableURL: fixture.executableURL,
                identityChecker: checker
            )
        ) { error in
            XCTAssertEqual(
                error as? MacOneShotAuthorizationError,
                .invalidHelperIdentity
            )
        }
    }

    func testBuildsAuthenticatedPersistentRecoveryRuntimeFromEmbeddedPolicy()
        throws
    {
        let fixture = try MacOneShotBootstrapFixture()
        defer { fixture.remove() }
        let checker = BootstrapIdentityChecker(
            identity: MacSignedExecutableIdentity(
                bundleIdentifier: fixture.helperServiceID,
                teamIdentifier: "TEAM123456",
                designatedRequirement: fixture.helperRequirement,
                sha256: "",
                isSignatureValid: true
            )
        )

        let runtime = try MacOneShotBootstrap.makeRecoveryRuntime(
            infoDictionary: fixture.infoDictionary,
            executableURL: fixture.executableURL,
            identityChecker: checker
        )

        XCTAssertEqual(
            runtime.helperEndpointIdentitySHA256,
            macPrivilegeSHA256(fixture.executableData)
        )
        XCTAssertEqual(checker.inspectedURL, fixture.executableURL)
        XCTAssertEqual(checker.requirement, fixture.helperRequirement)
    }
}

private final class BootstrapIdentityChecker:
    MacSignedExecutableIdentityChecking
{
    let result: MacSignedExecutableIdentity
    private(set) var inspectedURL: URL?
    private(set) var requirement: String?

    init(identity: MacSignedExecutableIdentity) {
        result = identity
    }

    func identity(
        at url: URL,
        requirement: String
    ) throws -> MacSignedExecutableIdentity {
        inspectedURL = url
        self.requirement = requirement
        return result
    }

    func runningIdentity(
        auditToken _: Data,
        requirement _: String
    ) throws -> MacSignedExecutableIdentity {
        throw MacPrivilegeError.peerAuthenticationFailed
    }
}

private final class MacOneShotBootstrapFixture {
    let rootURL: URL
    let executableURL: URL
    let executableData = Data("signed helper executable".utf8)
    let helperServiceID = "com.example.desktop-updater.helper"
    let helperRequirement =
        "identifier com.example.desktop-updater.helper"
    let infoDictionary: [String: Any]

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        executableURL = rootURL.appendingPathComponent(
            "DesktopUpdaterInstallHelper"
        )
        try executableData.write(to: executableURL)
        let policy: [String: Any] = [
            "policyVersion": 1,
            "policyId": "com.example.desktop-updater.test",
            "applicationPackageId": "com.example.app",
            "helperServiceId": helperServiceID,
            "allowedApplicationSigner": [
                "kind": "appleDesignatedRequirement",
                "value": "identifier com.example.app",
            ],
            "allowedHelperSigner": [
                "kind": "appleDesignatedRequirement",
                "value": helperRequirement,
            ],
            "allowedTargetClasses": ["applicationBundle"],
            "allowedInstallRoots": [rootURL.path],
            "releaseRootPublicKeys": [[
                "keyId": "stable-2026",
                "algorithm": "ed25519",
                "publicKeyBase64": Data(repeating: 1, count: 32)
                    .base64EncodedString(),
            ]],
            "allowedStrategies": [[
                "strategy": "directoryReplace",
                "provider": "platformDirectory",
            ]],
            "minimumHelperProtocolVersion": 1,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: policy)
        let canonical = try NativeStrictJSON.canonicalize(encoded)
        infoDictionary = [
            "CFBundleIdentifier": helperServiceID,
            "DesktopUpdaterSealedPolicy": canonical,
            "DesktopUpdaterSealedPolicySHA256":
                macPrivilegeSHA256(canonical),
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
