import CommonCrypto
import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacSealedInstallPolicyTests: XCTestCase {
    func testLoadsEveryAuthorityFieldFromCanonicalSealedPolicy() throws {
        let fixture = try privilegedPolicyFixture()
        let policy = try MacSealedInstallPolicyV1.load(
            sealedJSON: fixture.data,
            expectedSHA256: fixture.sha256
        )

        XCTAssertEqual(policy.policyVersion, 3)
        XCTAssertEqual(
            policy.policyID,
            "com.example.desktop-updater.privileged"
        )
        XCTAssertEqual(policy.applicationPackageID, "com.example.app")
        XCTAssertEqual(
            policy.helperServiceID,
            "com.example.desktop-updater.helper"
        )
        XCTAssertEqual(policy.allowedInstallRoots, ["/Applications"])
        XCTAssertEqual(
            policy.allowedTargetClasses,
            ["applicationBundle", "protectedApplication"]
        )
        XCTAssertTrue(
            policy.allowedStrategies.contains(
                MacSealedInstallStrategy(
                    strategy: "directoryReplace",
                    provider: "platformDirectory"
                )
            )
        )
        XCTAssertEqual(policy.releaseRootPublicKeys.count, 1)
        XCTAssertEqual(
            policy.releaseRootPublicKeys[0].keyID,
            "stable-2026"
        )
        XCTAssertEqual(policy.releaseRootPublicKeys[0].publicKey.count, 32)
        XCTAssertEqual(policy.minimumHelperProtocolVersion, 1)
        XCTAssertEqual(policy.canonicalSHA256, fixture.sha256)
    }

    func testRejectsDigestDriftUnknownAuthorityAndNoncanonicalPolicy() throws {
        let fixture = try privilegedPolicyFixture()
        XCTAssertThrowsError(
            try MacSealedInstallPolicyV1.load(
                sealedJSON: fixture.data,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? MacSealedInstallPolicyError, .digestMismatch)
        }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.data)
                as? [String: Any]
        )
        object["callerReleaseRootPublicKeys"] = ["attacker"]
        let injected = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try MacSealedInstallPolicyV1.load(
                sealedJSON: injected,
                expectedSHA256: sha256(injected)
            )
        ) { error in
            XCTAssertEqual(
                error as? MacSealedInstallPolicyError,
                .unknownOrMissingField
            )
        }

        let pretty = try JSONSerialization.data(
            withJSONObject: object.filter {
                $0.key != "callerReleaseRootPublicKeys"
            },
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertThrowsError(
            try MacSealedInstallPolicyV1.load(
                sealedJSON: pretty,
                expectedSHA256: sha256(pretty)
            )
        ) { error in
            XCTAssertEqual(
                error as? MacSealedInstallPolicyError,
                .nonCanonicalJSON
            )
        }
    }

    func testPolicyAuthorizesOnlyExactRequestAndCanonicalRoot() throws {
        let fixture = try privilegedPolicyFixture()
        let policy = try MacSealedInstallPolicyV1.load(
            sealedJSON: fixture.data,
            expectedSHA256: fixture.sha256
        )
        let request = try policyBoundDirectoryRequest()

        XCTAssertNoThrow(
            try policy.authorize(
                request,
                canonicalTargetURL: URL(
                    fileURLWithPath: "/Applications/Example.app"
                )
            )
        )
        for target in [
            "/tmp/Example.app",
            "/Applications/Nested/Example.app",
            "/Applications/../tmp/Example.app",
        ] {
            XCTAssertThrowsError(
                try policy.authorize(
                    request,
                    canonicalTargetURL: URL(fileURLWithPath: target)
                )
            )
        }

        let wrongPackage = try policyBoundDirectoryRequest(
            packageID: "com.attacker.app"
        )
        XCTAssertThrowsError(
            try policy.authorize(
                wrongPackage,
                canonicalTargetURL: URL(
                    fileURLWithPath: "/Applications/Example.app"
                )
            )
        )
    }
}

private func privilegedPolicyFixture() throws -> (data: Data, sha256: String) {
    let object = try fixtureObject("policy-cases.json")
    let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
    let value = try XCTUnwrap(
        cases.first { $0["name"] as? String == "valid privileged policy" }
    )
    let canonical = try XCTUnwrap(value["canonicalJson"] as? String)
    return (
        Data(canonical.utf8),
        try XCTUnwrap(value["canonicalSha256"] as? String)
    )
}

private func policyBoundDirectoryRequest(
    packageID: String = "com.example.app"
) throws
    -> NativeInstallTransactionRequestV1
{
    let object = try fixtureObject("valid-requests.json")
    let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
    var request = try XCTUnwrap(
        try XCTUnwrap(cases.first)["request"] as? [String: Any]
    )
    request["policyId"] = "com.example.desktop-updater.privileged"
    request["packageId"] = packageID
    var caller = try XCTUnwrap(request["caller"] as? [String: Any])
    caller["packageId"] = packageID
    request["caller"] = caller
    request["target"] = [
        "class": "applicationBundle",
        "pathHint": "/Applications/Example.app",
        "targetNameHint": "Example.app",
        "executableRelativePath": "Contents/MacOS/Example",
        "identityProofSha256": String(repeating: "a", count: 64),
    ]
    let data = try JSONSerialization.data(
        withJSONObject: request,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return try NativeInstallTransactionRequestV1.parse(data)
}

private func fixtureObject(_ name: String) throws -> [String: Any] {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate
            .appendingPathComponent("fixtures/compat/native-install-helper/v1")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: file))
                    as? [String: Any]
            )
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func sha256(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { bytes in
        _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}
