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
        let index: [String: Any] = [
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
        ]
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
                requireDescriptorSignature: false,
                pinnedPublicKeysById: [:]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .packageIdentityMismatch)
        XCTAssertTrue(transport.artifactRequests.isEmpty)
    }
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
