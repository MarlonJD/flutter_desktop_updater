import CryptoKit
import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class UpdateClientTests: XCTestCase {
    func testCheckForUpdateVerifiesBindingAndSignature() async throws {
        let signatureFixture = try fixtureObject(
            "canonical-signature-cases.json"
        )
        let signatureCase = try XCTUnwrap(
            (signatureFixture["cases"] as? [[String: Any]])?.first
        )
        let descriptor = try XCTUnwrap(
            signatureCase["descriptor"] as? [String: Any]
        )
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let index = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "supportPolicy": [
                "minimumSupportedVersion": "2.7.0",
                "enforcedAfter": "2020-01-01T00:00:00.000Z",
            ],
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ])
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
            descriptorURL: try JSONSerialization.data(withJSONObject: descriptor),
        ])
        let publicKey = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(
                signatureCase["publicKeyBase64"] as? String
            ))
        )
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                installationIdentity: "swift-client-test",
                pinnedPublicKeysById: [
                    "native-contract-stable": publicKey
                ]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .updateAvailable)
        XCTAssertEqual(result.supportPolicyStatus, .blocked)
        XCTAssertEqual(result.descriptor?.artifact.kind, "zip")
        XCTAssertEqual(transport.requestedURLs, [indexURL, descriptorURL])
        XCTAssertTrue(
            client.diagnostics.redactedLogLines().contains {
                $0.contains("Verified selected native release descriptor")
            }
        )
    }

    func testCheckForUpdateRejectsDescriptorBindingBeforeArtifactDownload()
        async throws
    {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let index: [String: Any] = [
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ]
        let signatureRoot = try fixtureObject(
            "canonical-signature-cases.json"
        )
        var descriptor = try XCTUnwrap(
            signatureRoot["signatureBlanking"] as? [String: Any]
        )
        descriptor = try XCTUnwrap(
            descriptor["signedDescriptor"] as? [String: Any]
        )
        descriptor["packageId"] = "com.example.other"
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
            descriptorURL: try JSONSerialization.data(withJSONObject: descriptor),
        ])
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                requireIndexSignature: false,
                requireDescriptorSignature: false,
                pinnedPublicKeysById: [:]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .packageIdentityMismatch)
        XCTAssertTrue(transport.artifactRequests.isEmpty)
    }

    func testCheckForUpdateRejectsTamperedIndexBeforeSelection() async throws {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let signed = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "supportPolicy": [
                "minimumSupportedVersion": "2.7.0",
                "enforcedAfter": "2026-08-01T00:00:00.000Z",
            ],
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "mandatory": true,
                "freshInstall": [
                    "downloadUrl": "https://updates.example.test/fresh",
                    "message": "Download the current installer.",
                ],
                "rollout": ["percentage": 100, "salt": "stable-2026"],
                "release": descriptorURL.absoluteString,
            ]],
        ])
        let publicKey = signingPrivateKey.publicKey.rawRepresentation
        let mutations: [([String: Any]) throws -> [String: Any]] = [
            { json in try mutateIndexItem(json, key: "mandatory", value: false) },
            { json in
                try mutateIndexItem(
                    json,
                    key: "release",
                    value: "https://evil.example.test/release.json"
                )
            },
            { json in
                try mutateNestedIndexItem(
                    json,
                    object: "freshInstall",
                    key: "downloadUrl",
                    value: "https://evil.example.test/fresh"
                )
            },
            { json in
                try mutateNestedIndexItem(
                    json,
                    object: "rollout",
                    key: "percentage",
                    value: 99
                )
            },
            { json in
                var result = json
                var policy = try XCTUnwrap(
                    result["supportPolicy"] as? [String: Any]
                )
                policy["enforcedAfter"] = "2027-01-01T00:00:00.000Z"
                result["supportPolicy"] = policy
                return result
            },
        ]

        for mutation in mutations {
            let tampered = try mutation(signed)
            let transport = FixtureRuntimeTransport(metadata: [
                indexURL: try JSONSerialization.data(withJSONObject: tampered),
            ])
            let client = UpdateClient(
                configuration: try RuntimeConfiguration(
                    appArchiveUrl: indexURL,
                    expectedPackageId: "com.example.native-contract",
                    currentVersion: "2.6.0",
                    currentBuildNumber: 260,
                    currentUpdaterVersion: "2.7.0",
                    platform: "macos",
                    pinnedPublicKeysById: [
                        "native-contract-stable": publicKey
                    ]
                ),
                transport: transport
            )

            let result = await client.checkForUpdate()

            XCTAssertEqual(result.outcome, .signatureFailure)
            XCTAssertEqual(transport.requestedURLs, [indexURL])
        }
    }

    func testStrictClientRejectsUnsignedIndexBeforeSelection() async throws {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let index: [String: Any] = [
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ]
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
        ])
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                pinnedPublicKeysById: [
                    "native-contract-stable":
                        signingPrivateKey.publicKey.rawRepresentation
                ]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .signatureFailure)
        XCTAssertEqual(transport.requestedURLs, [indexURL])
    }

    func testBlankIndexSignatureFieldsMapToSignatureFailure() async throws {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let signed = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ])
        for field in ["algorithm", "publicKeyId"] {
            var candidate = signed
            var signature = try XCTUnwrap(
                candidate["signature"] as? [String: Any]
            )
            signature[field] = ""
            candidate["signature"] = signature
            let transport = FixtureRuntimeTransport(metadata: [
                indexURL: try JSONSerialization.data(
                    withJSONObject: candidate
                ),
            ])
            let client = UpdateClient(
                configuration: try RuntimeConfiguration(
                    appArchiveUrl: indexURL,
                    expectedPackageId: "com.example.native-contract",
                    currentVersion: "2.6.0",
                    currentBuildNumber: 260,
                    currentUpdaterVersion: "2.7.0",
                    platform: "macos",
                    pinnedPublicKeysById: [
                        "native-contract-stable":
                            signingPrivateKey.publicKey.rawRepresentation
                    ]
                ),
                transport: transport
            )

            let result = await client.checkForUpdate()

            XCTAssertEqual(result.outcome, .signatureFailure, field)
            XCTAssertEqual(transport.requestedURLs, [indexURL], field)
        }
    }

    func testFreshInstallRequiresVerifiedDescriptorBeforeReturning() async throws {
        let fixture = try fixtureObject("canonical-signature-cases.json")
        let signatureCase = try XCTUnwrap(
            (fixture["cases"] as? [[String: Any]])?.first
        )
        let descriptor = try XCTUnwrap(
            signatureCase["descriptor"] as? [String: Any]
        )
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let index = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "freshInstall": [
                    "downloadUrl": "https://updates.example.test/fresh"
                ],
                "release": descriptorURL.absoluteString,
            ]],
        ])
        let publicKey = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(
                signatureCase["publicKeyBase64"] as? String
            ))
        )
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
            descriptorURL: try JSONSerialization.data(withJSONObject: descriptor),
        ])
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                pinnedPublicKeysById: [
                    "native-contract-stable": publicKey
                ]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .freshInstallRequired)
        XCTAssertNotNil(result.descriptor)
        XCTAssertEqual(transport.requestedURLs, [indexURL, descriptorURL])
        XCTAssertTrue(transport.artifactRequests.isEmpty)
    }
}

private let signingPrivateKey = try! Curve25519.Signing.PrivateKey(
    rawRepresentation: Data(0 ..< 32)
)

private func signedIndex(_ json: [String: Any]) throws -> [String: Any] {
    var unsigned = json
    unsigned["signature"] = [
        "algorithm": "ed25519",
        "publicKeyId": "native-contract-stable",
        "value": "",
    ]
    let index = try ReleaseIndex(
        jsonData: JSONSerialization.data(withJSONObject: unsigned)
    )
    let signature = try signingPrivateKey.signature(
        for: index.canonicalSignatureBytes()
    )
    unsigned["signature"] = [
        "algorithm": "ed25519",
        "publicKeyId": "native-contract-stable",
        "value": signature.base64EncodedString(),
    ]
    return unsigned
}

private func mutateIndexItem(
    _ json: [String: Any],
    key: String,
    value: Any
) throws -> [String: Any] {
    var result = json
    var items = try XCTUnwrap(result["items"] as? [[String: Any]])
    items[0][key] = value
    result["items"] = items
    return result
}

private func mutateNestedIndexItem(
    _ json: [String: Any],
    object: String,
    key: String,
    value: Any
) throws -> [String: Any] {
    var result = json
    var items = try XCTUnwrap(result["items"] as? [[String: Any]])
    var nested = try XCTUnwrap(items[0][object] as? [String: Any])
    nested[key] = value
    items[0][object] = nested
    result["items"] = items
    return result
}

private final class FixtureRuntimeTransport: RuntimeUpdateTransport {
    private let metadata: [URL: Data]
    private(set) var requestedURLs: [URL] = []
    private(set) var artifactRequests: [RuntimeArtifactDownload] = []

    init(metadata: [URL: Data]) {
        self.metadata = metadata
    }

    func downloadMetadata(
        from url: URL,
        configuration _: RuntimeConfiguration
    ) async throws -> Data {
        requestedURLs.append(url)
        guard let data = metadata[url] else {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }

    func downloadArtifact(
        _ request: RuntimeArtifactDownload,
        configuration _: RuntimeConfiguration,
        progress _: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws {
        artifactRequests.append(request)
    }
}

private func fixtureObject(_ name: String) throws -> [String: Any] {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate
            .appendingPathComponent("fixtures")
            .appendingPathComponent("compat")
            .appendingPathComponent("native-contract")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            return try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: file)
                ) as? [String: Any]
            )
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
