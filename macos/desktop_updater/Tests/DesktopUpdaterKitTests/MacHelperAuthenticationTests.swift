import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacHelperAuthenticationTests: XCTestCase {
    func testValidPeerAndFixedHelperAuthenticateAgainstSealedPolicy() throws {
        let fixture = try AuthenticationFixture()
        let session = try fixture.authenticator.authenticate(
            fixture.request,
            peerAuditToken: fixture.auditToken,
            canonicalRequestSHA256: fixture.request.requestSHA256,
            expectedTransactionNonce: fixture.expectedTransactionNonce
        )

        XCTAssertEqual(session.transactionID, fixture.request.transactionID)
        XCTAssertEqual(session.applicationBundleIdentifier, "com.example.app")
        XCTAssertEqual(
            session.helperBundleIdentifier,
            "com.example.desktop-updater.helper"
        )
        XCTAssertEqual(
            fixture.checker.staticURL?.path,
            "/Applications/Example.app/Contents/Helpers/"
                + "DesktopUpdaterInstallHelper"
        )
    }

    func testAuthenticationFailsClosedForEveryBoundIdentity() throws {
        let mutations: [(String, (AuthenticationFixture) -> Void)] = [
            ("wrong Team ID", { $0.checker.helper.teamIdentifier = "ATTACKER" }),
            ("wrong bundle ID", { $0.checker.caller.bundleIdentifier = "com.attacker.app" }),
            ("wrong designated requirement", { $0.checker.caller.satisfiesRequirement = false }),
            ("helper digest mismatch", { $0.request.helperSHA256 = String(repeating: "b", count: 64) }),
            ("policy digest mismatch", { $0.request.policySHA256 = String(repeating: "c", count: 64) }),
            ("protocol downgrade", { $0.request.protocolVersion = 0 }),
            ("transaction nonce mismatch", {
                $0.request.transactionNonce = String(repeating: "B", count: 43)
            }),
            ("stale audit token", { $0.request.callerAuditToken = Data(repeating: 9, count: 32) }),
            ("replaced nested helper", { $0.checker.helper.sha256 = String(repeating: "d", count: 64) }),
        ]

        for (name, mutate) in mutations {
            let fixture = try AuthenticationFixture()
            mutate(fixture)
            XCTAssertThrowsError(
                try fixture.authenticator.authenticate(
                    fixture.request,
                    peerAuditToken: fixture.auditToken,
                    canonicalRequestSHA256: fixture.request.requestSHA256,
                    expectedTransactionNonce: fixture.expectedTransactionNonce
                ),
                name
            )
        }
    }

    func testPolicyLoaderRejectsDigestMismatchAndUnknownAuthority() throws {
        let fixture = try policyFixture()
        XCTAssertThrowsError(
            try HelperPolicy.load(
                sealedJSON: fixture.data,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.data) as? [String: Any]
        )
        object["callerReleaseRootPublicKeys"] = ["attacker"]
        let injected = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try HelperPolicy.load(
                sealedJSON: injected,
                expectedSHA256: HelperSHA256.hex(injected)
            )
        )
    }
}

private final class AuthenticationFixture {
    let auditToken = Data(repeating: 7, count: 32)
    let expectedTransactionNonce = String(repeating: "A", count: 43)
    let checker: TestIdentityChecker
    let authenticator: HelperAuthenticator
    var request: HelperAuthenticationRequestV1

    init() throws {
        let fixture = try policyFixture()
        let policy = try HelperPolicy.load(
            sealedJSON: fixture.data,
            expectedSHA256: fixture.sha256
        )
        let helperDigest = String(repeating: "a", count: 64)
        checker = TestIdentityChecker(
            caller: HelperCodeIdentity(
                bundleIdentifier: "com.example.app",
                teamIdentifier: "EXAMPLETEAM",
                designatedRequirement: policy.allowedApplicationSigner.value,
                sha256: String(repeating: "e", count: 64),
                satisfiesRequirement: true
            ),
            helper: HelperCodeIdentity(
                bundleIdentifier: "com.example.desktop-updater.helper",
                teamIdentifier: "EXAMPLETEAM",
                designatedRequirement: policy.allowedHelperSigner.value,
                sha256: helperDigest,
                satisfiesRequirement: true
            )
        )
        authenticator = HelperAuthenticator(
            policy: policy,
            applicationBundleURL: URL(
                fileURLWithPath: "/Applications/Example.app"
            ),
            identityChecker: checker
        )
        request = HelperAuthenticationRequestV1(
            schemaVersion: 1,
            protocolVersion: 1,
            transactionID: "00000000-0000-4000-8000-000000000001",
            policyID: policy.policyID,
            policySHA256: policy.canonicalSHA256,
            requestSHA256: String(repeating: "f", count: 64),
            helperSHA256: helperDigest,
            transactionNonce: expectedTransactionNonce,
            callerAuditToken: auditToken
        )
    }
}

private final class TestIdentityChecker: HelperCodeIdentityChecking {
    var caller: HelperCodeIdentity
    var helper: HelperCodeIdentity
    var staticURL: URL?

    init(caller: HelperCodeIdentity, helper: HelperCodeIdentity) {
        self.caller = caller
        self.helper = helper
    }

    func runningCodeIdentity(
        auditToken _: Data,
        requirement _: String
    ) throws -> HelperCodeIdentity {
        caller
    }

    func staticCodeIdentity(
        at url: URL,
        requirement _: String
    ) throws -> HelperCodeIdentity {
        staticURL = url
        return helper
    }
}

private func policyFixture() throws -> (data: Data, sha256: String) {
    let root = try helperRepositoryRoot()
    let fixtureURL = root
        .appendingPathComponent("fixtures/compat/native-install-helper/v1")
        .appendingPathComponent("policy-cases.json")
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
            as? [String: Any]
    )
    let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
    let entry = try XCTUnwrap(
        cases.first { $0["name"] as? String == "valid privileged policy" }
    )
    let canonicalJSON = try XCTUnwrap(entry["canonicalJson"] as? String)
    return (
        Data(canonicalJSON.utf8),
        try XCTUnwrap(entry["canonicalSha256"] as? String)
    )
}

private func helperRepositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if FileManager.default.fileExists(
            atPath: candidate
                .appendingPathComponent("fixtures/compat/native-install-helper/v1")
                .path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
