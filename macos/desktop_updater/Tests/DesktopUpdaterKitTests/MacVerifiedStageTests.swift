import CryptoKit
import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class MacVerifiedStageTests: XCTestCase {
    func testSignedLoaderBindsKeyPackageArtifactAndStage() throws {
        let fixture = try SignedStageFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let verified = try MacVerifiedStage.loadAndVerify(
            stagedPath: fixture.stagedApp,
            stageRoot: fixture.stageRoot,
            expectedPackageID: fixture.packageID,
            trustedReleasePublicKeys: [fixture.keyID: fixture.publicKey]
        )

        XCTAssertEqual(
            verified.stagedPath.standardizedFileURL,
            fixture.stagedApp.standardizedFileURL
        )
        XCTAssertEqual(verified.stageRoot, fixture.stageRoot)
        XCTAssertEqual(verified.provenance.marker.packageId, fixture.packageID)
        XCTAssertEqual(
            verified.provenance.marker.artifactSha256,
            fixture.artifactSHA256
        )
        XCTAssertEqual(verified.artifactKind, "zip")
    }

    func testSignedLoaderRejectsWrongPackageAndKey() throws {
        let fixture = try SignedStageFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try MacVerifiedStage.loadAndVerify(
                stagedPath: fixture.stagedApp,
                stageRoot: fixture.stageRoot,
                expectedPackageID: "com.example.attacker",
                trustedReleasePublicKeys: [fixture.keyID: fixture.publicKey]
            )
        )
        XCTAssertThrowsError(
            try MacVerifiedStage.loadAndVerify(
                stagedPath: fixture.stagedApp,
                stageRoot: fixture.stageRoot,
                expectedPackageID: fixture.packageID,
                trustedReleasePublicKeys: [
                    fixture.keyID: Curve25519.Signing.PrivateKey()
                        .publicKey.rawRepresentation
                ]
            )
        )
    }

    func testSignedLoaderRejectsArtifactByteMutation() throws {
        let fixture = try SignedStageFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var artifact = try Data(contentsOf: fixture.artifactURL)
        artifact[artifact.startIndex] ^= 0xff
        try artifact.write(to: fixture.artifactURL)

        XCTAssertThrowsError(try fixture.load())
    }

    func testSignedLoaderRejectsSignedArtifactLengthMismatch() throws {
        let fixture = try SignedStageFixture.create(
            descriptorArtifactLengthAdjustment: 1
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try fixture.load())
    }

    func testSignedLoaderRejectsSignedArtifactDigestMismatch() throws {
        let fixture = try SignedStageFixture.create(
            descriptorArtifactSHA256: String(repeating: "c", count: 64)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try fixture.load())
    }

    func testRetainedArtifactNamesMatchRuntimeStagerTopology() {
        XCTAssertEqual(
            macStagedArtifactFileName(for: "zip"),
            ".desktop_updater_artifact.zip"
        )
        XCTAssertEqual(
            macStagedArtifactFileName(for: "dmg"),
            "artifact.dmg"
        )
        XCTAssertEqual(
            macStagedArtifactFileName(for: "pkgInstaller"),
            "installer.pkg"
        )
        XCTAssertNil(macStagedArtifactFileName(for: "unknown"))
    }
}

private struct SignedStageFixture {
    let root: URL
    let stageRoot: URL
    let stagedApp: URL
    let artifactURL: URL
    let packageID: String
    let artifactSHA256: String
    let keyID: String
    let publicKey: Data

    func load() throws -> MacVerifiedStage {
        try MacVerifiedStage.loadAndVerify(
            stagedPath: stagedApp,
            stageRoot: stageRoot,
            expectedPackageID: packageID,
            trustedReleasePublicKeys: [keyID: publicKey]
        )
    }

    static func create(
        descriptorArtifactSHA256: String? = nil,
        descriptorArtifactLengthAdjustment: Int64 = 0
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let stageRoot = try StageProvenance.createOwnedStage(parent: root)
        let stagedApp = stageRoot.appendingPathComponent("Example.app")
        let contents = stagedApp.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Example")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let packageID = "com.example.app"
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": packageID,
                "CFBundleExecutable": "Example",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("new executable".utf8).write(to: executable)

        let artifactURL = stageRoot.appendingPathComponent(
            ".desktop_updater_artifact.zip"
        )
        let artifactData = Data("signed retained zip artifact".utf8)
        try artifactData.write(to: artifactURL)
        let actualArtifactSHA256 = sha256(artifactData)
        let signedArtifactSHA256 = descriptorArtifactSHA256
            ?? actualArtifactSHA256
        let signedArtifactLength = Int64(artifactData.count)
            + descriptorArtifactLengthAdjustment

        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "stable-2026"
        var manifest = descriptorJSON(
            packageID: packageID,
            artifactSHA256: signedArtifactSHA256,
            artifactLength: signedArtifactLength,
            keyID: keyID,
            signature: ""
        )
        let signature = try privateKey.signature(
            for: JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
        manifest["signature"] = [
            "algorithm": "ed25519",
            "publicKeyId": keyID,
            "value": signature.base64EncodedString(),
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try manifestData.write(
            to: stageRoot.appendingPathComponent(
                ".desktop_updater_release_manifest.json"
            )
        )
        let nonce = String(
            stageRoot.lastPathComponent.dropFirst(updaterOwnedStagePrefix.count)
        )
        _ = try StageProvenance.write(
            stageRoot: stageRoot,
            nonce: nonce,
            packageID: packageID,
            descriptorSHA256: try StageProvenance.canonicalJSONSHA256(manifest),
            artifactSHA256: signedArtifactSHA256
        )
        return Self(
            root: root,
            stageRoot: stageRoot,
            stagedApp: stagedApp,
            artifactURL: artifactURL,
            packageID: packageID,
            artifactSHA256: actualArtifactSHA256,
            keyID: keyID,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }

    private static func descriptorJSON(
        packageID: String,
        artifactSHA256: String,
        artifactLength: Int64,
        keyID: String,
        signature: String
    ) -> [String: Any] {
        [
            "schemaVersion": 3,
            "packageId": packageID,
            "appName": "Example",
            "version": "3.0.0",
            "buildNumber": 300,
            "platform": "macos",
            "channel": "stable",
            "artifact": [
                "kind": "zip",
                "url": "https://updates.example.test/Example.zip",
                "sha256": artifactSHA256,
                "length": artifactLength,
            ],
            "install": ["strategy": "wholeBundleReplace"],
            "signature": [
                "algorithm": "ed25519",
                "publicKeyId": keyID,
                "value": signature,
            ],
            "minimumUpdaterVersion": "2.7.0",
            "generatedAt": "2026-08-03T00:00:00.000Z",
        ]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
