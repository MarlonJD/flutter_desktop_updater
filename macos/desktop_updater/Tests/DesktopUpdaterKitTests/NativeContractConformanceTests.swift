import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class NativeContractConformanceTests: XCTestCase {
    func testSelectionAndPolicyFixturesMatchDart() throws {
        let fixture = try fixtureObject("selection-cases.json")

        for entry in try dictionaries(fixture["selectionCases"]) {
            let index = try ReleaseIndex(
                jsonData: try JSONSerialization.data(
                    withJSONObject: try required(entry, "index")
                )
            )
            let selected = try selectReleaseIndexItem(
                index: index,
                platform: try string(entry, "platform"),
                channel: try string(entry, "channel"),
                currentVersion: try DesktopVersion(
                    try string(entry, "currentVersion")
                ),
                installationIdentity: entry["identity"] as? String
            )

            XCTAssertEqual(selected?.version, entry["selectedVersion"] as? String)
            XCTAssertEqual(
                selected?.buildNumber,
                (entry["selectedBuildNumber"] as? NSNumber)?.int64Value
            )
            XCTAssertEqual(selected?.platform, entry["selectedPlatform"] as? String)
            XCTAssertEqual(selected?.channel, entry["selectedChannel"] as? String)
            XCTAssertEqual(selected?.release.absoluteString, entry["selectedRelease"] as? String)
        }

        for entry in try dictionaries(fixture["supportPolicyCases"]) {
            let policy = try ReleaseSupportPolicy(
                json: try dictionary(entry["policy"])
            )
            let version = try DesktopVersion(try string(entry, "currentVersion"))
            let now = try XCTUnwrap(
                ISO8601DateFormatter.fixture.date(
                    from: try string(entry, "now")
                )
            )
            XCTAssertEqual(policy.applies(to: version), entry["expectedApplies"] as? Bool)
            XCTAssertEqual(
                policy.isEnforced(currentVersion: version, now: now),
                entry["expectedEnforced"] as? Bool
            )
        }

        for entry in try dictionaries(fixture["minimumUpdaterCases"]) {
            let supported = try DesktopVersion(
                try string(entry, "current")
            ) >= DesktopVersion(try string(entry, "required"))
            XCTAssertEqual(supported, entry["expectedSupported"] as? Bool)
        }
        for entry in try dictionaries(fixture["minimumOSCases"]) {
            let descriptor = try ReleaseDescriptor(
                jsonData: try JSONSerialization.data(
                    withJSONObject: try required(entry, "descriptor")
                )
            )
            let outcome = try UpdatePolicy.descriptorOutcome(
                descriptor: descriptor,
                currentUpdaterVersion: DesktopVersion("99.0.0"),
                platform: try string(entry, "platform"),
                minimumOSSupported: { _, _ in
                    (entry["callbackResult"] as? Bool) ?? false
                }
            )
            let expected = RuntimeOutcome(
                rawValue: try string(entry, "expectedOutcome")
            )
            XCTAssertEqual(outcome, expected)
        }
    }

    func testFreshInstallFixturesExecuteUpdateClient() async throws {
        let fixture = try fixtureObject("selection-cases.json")
        let signatures = try fixtureObject("canonical-signature-cases.json")
        let valid = try XCTUnwrap(try dictionaries(signatures["cases"]).first)
        let descriptor = try dictionary(valid["descriptor"])
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/2.7.0/release.json"
        )!
        let publicKey = try XCTUnwrap(
            Data(base64Encoded: try string(valid, "publicKeyBase64"))
        )
        for entry in try dictionaries(fixture["freshInstallCases"]) {
            let index: [String: Any] = [
                "schemaVersion": 3,
                "appName": "Example.app",
                "items": [[
                    "version": try string(descriptor, "version"),
                    "buildNumber": try required(descriptor, "buildNumber"),
                    "platform": try string(descriptor, "platform"),
                    "channel": try string(descriptor, "channel"),
                    "mandatory": true,
                    "release": descriptorURL.absoluteString,
                    "freshInstall": try required(entry, "input"),
                ]],
            ]
            let transport = FixtureRuntimeTransport(metadata: [
                indexURL: try JSONSerialization.data(withJSONObject: index),
                descriptorURL: try JSONSerialization.data(
                    withJSONObject: descriptor
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
                    requireIndexSignature: false,
                    pinnedPublicKeysById: [
                        try string(valid, "publicKeyId"): publicKey,
                    ]
                ),
                transport: transport
            )

            let result = await client.checkForUpdate()

            XCTAssertEqual(
                result.outcome.rawValue,
                try string(entry, "expectedOutcome")
            )
            XCTAssertEqual(result.selectedItem?.mandatory, true)
            XCTAssertNotNil(result.selectedItem?.freshInstall)
            XCTAssertNotNil(result.descriptor)
            XCTAssertEqual(
                transport.metadataRequests,
                [indexURL, descriptorURL]
            )
            XCTAssertEqual(transport.artifactRequestCount, 0)
            XCTAssertEqual(entry["expectedArtifactDownload"] as? Bool, false)
        }
    }

    func testDescriptorValidationFixturesMatchDart() throws {
        let fixture = try fixtureObject("descriptor-validation-cases.json")
        for entry in try dictionaries(fixture["cases"]) {
            let name = try string(entry, "name")
            var error: Error?
            do {
                _ = try ReleaseDescriptor(
                    jsonData: JSONSerialization.data(
                        withJSONObject: try required(entry, "descriptor")
                    )
                )
            } catch let caught {
                error = caught
            }
            XCTAssertEqual(
                error == nil,
                entry["expectedValid"] as? Bool,
                name
            )
        }
    }

    func testAdversarialNormalizationFixturesMatchDart() throws {
        let fixture = try fixtureObject("selection-cases.json")
        for entry in try dictionaries(fixture["indexValidationCases"]) {
            let name = try string(entry, "name")
            var index: ReleaseIndex?
            var error: Error?
            do {
                index = try ReleaseIndex(
                    jsonData: JSONSerialization.data(
                        withJSONObject: try required(entry, "index")
                    )
                )
            } catch let caught {
                error = caught
            }
            XCTAssertEqual(error == nil, entry["expectedValid"] as? Bool, name)
            XCTAssertEqual(
                index?.items.first?.channel,
                entry["expectedChannel"] as? String,
                name
            )
        }
        for entry in try dictionaries(fixture["parityCases"]) {
            switch try string(entry, "name") {
            case "rollout identity trims surrounding whitespace":
                let rollout = try ReleaseRollout(json: [
                    "percentage": 60,
                    "salt": "native-contract-rollout",
                ])
                XCTAssertEqual(
                    rollout.includes(
                        channel: "stable",
                        identity: try string(entry, "identity")
                    ),
                    rollout.includes(
                        channel: "stable",
                        identity: try string(entry, "expectedNormalizedIdentity")
                    )
                )
            case "whitespace-only rollout identity is absent":
                let rollout = try ReleaseRollout(json: [
                    "percentage": 50,
                    "salt": "native-contract-rollout",
                ])
                XCTAssertFalse(
                    rollout.includes(
                        channel: "stable",
                        identity: try string(entry, "identity")
                    )
                )
                XCTAssertTrue(entry["expectedSelectedVersion"] is NSNull)
            case "minimum OS keys and values are trimmed":
                var descriptor = try fixtureObject(
                    "release-contract/release-macos-zip.json"
                )
                descriptor["minimumOS"] = try required(entry, "minimumOS")
                let parsed = try ReleaseDescriptor(
                    jsonData: JSONSerialization.data(withJSONObject: descriptor)
                )
                let expected = try dictionary(entry["expectedMinimumOS"])
                    .compactMapValues { $0 as? String }
                XCTAssertEqual(parsed.minimumOS, expected)
            case "hyphen is valid inside prerelease identifier",
                 "first numeric build metadata component is the build number":
                XCTAssertGreaterThan(
                    try DesktopVersion(try string(entry, "candidate")),
                    try DesktopVersion(try string(entry, "current"))
                )
            case "ISO offset and UTC deadline represent the same instant":
                XCTAssertEqual(
                    RuntimeISO8601.date(try string(entry, "left")),
                    RuntimeISO8601.date(try string(entry, "right"))
                )
            case "same-second fractional deadline remains warning":
                let policy = try ReleaseSupportPolicy(json: [
                    "minimumSupportedVersion": "9.0.0",
                    "enforcedAfter": try string(entry, "deadline"),
                ])
                let now = try XCTUnwrap(
                    RuntimeISO8601.date(try string(entry, "now"))
                )
                XCTAssertFalse(
                    policy.isEnforced(
                        currentVersion: try DesktopVersion("2.7.0"),
                        now: now
                    )
                )
            default:
                XCTFail("Unknown parity fixture")
            }
        }
    }

    func testCanonicalSignaturesAndIdentityBindingMatchDart() throws {
        let signatureFixture = try fixtureObject(
            "canonical-signature-cases.json"
        )
        for entry in try dictionaries(signatureFixture["cases"]) {
            let descriptor = try ReleaseDescriptor(
                jsonData: try JSONSerialization.data(
                    withJSONObject: try required(entry, "descriptor")
                )
            )
            XCTAssertEqual(
                try descriptor.canonicalSignatureBytes().base64EncodedString(),
                try string(entry, "canonicalUtf8Base64")
            )
            let key = try XCTUnwrap(
                Data(base64Encoded: try string(entry, "publicKeyBase64"))
            )
            XCTAssertEqual(
                try ArtifactVerifier.verifyDescriptorSignature(
                    descriptor,
                    pinnedPublicKeysById: [try string(entry, "publicKeyId"): key]
                ),
                entry["expectedValid"] as? Bool
            )
        }
        for entry in try dictionaries(signatureFixture["normalizationCases"]) {
            let name = try string(entry, "name")
            let descriptor = try ReleaseDescriptor(
                jsonData: try JSONSerialization.data(
                    withJSONObject: try required(entry, "inputDescriptor")
                )
            )
            XCTAssertEqual(
                try descriptor.canonicalSignatureBytes().base64EncodedString(),
                try string(entry, "canonicalUtf8Base64"),
                name
            )
        }

        let valid = try XCTUnwrap(
            try dictionaries(signatureFixture["cases"]).first
        )
        var malformedJSON = try dictionary(valid["descriptor"])
        var malformedSignature = try dictionary(malformedJSON["signature"])
        malformedSignature["value"] = "not-base64"
        malformedJSON["signature"] = malformedSignature
        let malformed = try ReleaseDescriptor(
            jsonData: try JSONSerialization.data(withJSONObject: malformedJSON)
        )
        let validKey = try XCTUnwrap(
            Data(base64Encoded: try string(valid, "publicKeyBase64"))
        )
        XCTAssertFalse(
            try ArtifactVerifier.verifyDescriptorSignature(
                malformed,
                pinnedPublicKeysById: [
                    try string(valid, "publicKeyId"): validKey
                ]
            )
        )

        var unsignedJSON = try dictionary(valid["descriptor"])
        unsignedJSON.removeValue(forKey: "signature")
        XCTAssertFalse(
            try ArtifactVerifier.verifyDescriptorSignature(
                ReleaseDescriptor(
                    jsonData: try JSONSerialization.data(
                        withJSONObject: unsignedJSON
                    )
                ),
                pinnedPublicKeysById: [
                    try string(valid, "publicKeyId"): validKey
                ]
            )
        )

        let selectionFixture = try fixtureObject("selection-cases.json")
        for entry in try dictionaries(selectionFixture["descriptorBindingCases"]) {
            let item = try ReleaseIndexItem(
                json: try dictionary(entry["indexItem"])
            )
            let descriptor = try ReleaseDescriptor(
                jsonData: try JSONSerialization.data(
                    withJSONObject: try required(entry, "descriptor")
                )
            )
            XCTAssertEqual(
                descriptor.bindingOutcome(
                    indexItem: item,
                    expectedPackageId: try string(entry, "expectedPackageId")
                ),
                RuntimeOutcome(rawValue: try string(entry, "expectedOutcome"))
            )
        }
    }

    func testEveryCapabilityDescriptorParsesCompleteSchema() throws {
        let root = try nativeFixtureRoot()
            .appendingPathComponent("release-contract")
        for name in [
            "release-macos-zip.json",
            "release-macos-dmg.json",
            "release-macos-pkg.json",
            "release-windows-zip.json",
            "release-windows-inno.json",
            "release-linux-zip.json",
        ] {
            let descriptor = try ReleaseDescriptor(
                jsonData: Data(contentsOf: root.appendingPathComponent(name))
            )
            XCTAssertEqual(descriptor.schemaVersion, 3)
            XCTAssertFalse(descriptor.packageId.isEmpty)
            XCTAssertFalse(descriptor.minimumUpdaterVersion.isEmpty)
            XCTAssertNotNil(descriptor.minimumOS[descriptor.platform])
            XCTAssertNotNil(descriptor.install.rawJSON["strategy"])
            XCTAssertTrue(descriptor.artifact.url.isAbsoluteURL)
        }
    }
}

private final class FixtureRuntimeTransport: RuntimeUpdateTransport {
    let metadata: [URL: Data]
    private(set) var metadataRequests: [URL] = []
    private(set) var artifactRequestCount = 0

    init(metadata: [URL: Data]) {
        self.metadata = metadata
    }

    func downloadMetadata(
        from url: URL,
        configuration _: RuntimeConfiguration
    ) async throws -> Data {
        metadataRequests.append(url)
        guard let data = metadata[url] else {
            throw RuntimeError.outcome(
                .downloadFailure,
                message: "Missing fixture metadata."
            )
        }
        return data
    }

    func downloadArtifact(
        _: RuntimeArtifactDownload,
        configuration _: RuntimeConfiguration,
        progress _: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws {
        artifactRequestCount += 1
    }
}

private extension ISO8601DateFormatter {
    static let fixture: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private func fixtureObject(_ name: String) throws -> [String: Any] {
    let file = try nativeFixtureRoot().appendingPathComponent(name)
    return try dictionary(
        JSONSerialization.jsonObject(with: Data(contentsOf: file))
    )
}

private func nativeFixtureRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fileManager = FileManager.default
    while candidate.path != "/" {
        let fixture = candidate
            .appendingPathComponent("fixtures")
            .appendingPathComponent("compat")
            .appendingPathComponent("native-contract")
        if fileManager.fileExists(atPath: fixture.path) {
            return fixture
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func dictionaries(_ value: Any?) throws -> [[String: Any]] {
    guard let values = value as? [Any] else {
        throw RuntimeError.invalidConfiguration("Expected fixture array.")
    }
    return try values.map(dictionary)
}

private func dictionary(_ value: Any?) throws -> [String: Any] {
    guard let result = value as? [String: Any] else {
        throw RuntimeError.invalidConfiguration("Expected fixture object.")
    }
    return result
}

private func required(_ source: [String: Any], _ key: String) throws -> Any {
    guard let value = source[key] else {
        throw RuntimeError.invalidConfiguration("Missing fixture key \(key).")
    }
    return value
}

private func string(_ source: [String: Any], _ key: String) throws -> String {
    guard let value = source[key] as? String else {
        throw RuntimeError.invalidConfiguration("Expected string key \(key).")
    }
    return value
}

private extension URL {
    var isAbsoluteURL: Bool {
        return scheme?.isEmpty == false
    }
}
