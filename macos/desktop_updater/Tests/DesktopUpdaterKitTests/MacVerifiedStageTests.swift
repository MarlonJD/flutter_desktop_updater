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

        XCTAssertEqual(verified.stagedPath, fixture.stagedApp)
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
}

private struct SignedStageFixture {
    let root: URL
    let stageRoot: URL
    let stagedApp: URL
    let packageID: String
    let artifactSHA256: String
    let keyID: String
    let publicKey: Data

    static func create() throws -> Self {
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

        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "stable-2026"
        let artifactSHA256 = String(repeating: "c", count: 64)
        var manifest = descriptorJSON(
            packageID: packageID,
            artifactSHA256: artifactSHA256,
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
            artifactSHA256: artifactSHA256
        )
        return Self(
            root: root,
            stageRoot: stageRoot,
            stagedApp: stagedApp,
            packageID: packageID,
            artifactSHA256: artifactSHA256,
            keyID: keyID,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }

    private static func descriptorJSON(
        packageID: String,
        artifactSHA256: String,
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
                "length": 123,
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
}
