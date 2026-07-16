import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacInstallHelperTests: XCTestCase {
    func testTopLevelStagingSymlinkIsRejectedBeforeScheduling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopUpdaterKitTests-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Target.app")
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try MacInstallHelper().validateStagingPath(link.path)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a symlink"))
        }
    }

    func testIncompleteStagedRequestIsRejectedBeforeScheduling() throws {
        let incomplete = MacInstallRequest(
            stagingPath: "/tmp/Example.app",
            allowUnsignedUpdates: false,
            diagnosticsLogPath: nil
        )

        XCTAssertThrowsError(
            try MacInstallHelper().validateCompleteHandoff(incomplete)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Verified stage provenance is required"
                )
            )
        }
    }

    func testVerifiedStagePopulatesCompleteHelperHandoff() {
        let marker = StageProvenanceMarker(
            schemaVersion: 1,
            nonce: "123e4567-e89b-42d3-a456-426614174000",
            packageId: "com.example.app",
            descriptorSha256: String(repeating: "0", count: 64),
            artifactSha256: String(repeating: "2", count: 64),
            entries: []
        )
        let verifiedStage = MacVerifiedStage(
            stagedPath: URL(fileURLWithPath: "/tmp/Example.app"),
            stageRoot: URL(
                fileURLWithPath:
                    "/tmp/desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000"
            ),
            provenance: StageProvenanceState(
                marker: marker,
                markerSHA256: String(repeating: "1", count: 64)
            ),
            artifactKind: "zip",
            expectedPackageIDs: []
        )
        let request = MacInstallRequest(
            verifiedStage: verifiedStage,
            allowUnsignedUpdates: false,
            diagnosticsLogPath: nil
        )

        XCTAssertEqual(request.stagingPath, verifiedStage.stagedPath.path)
        XCTAssertEqual(request.stageRoot, verifiedStage.stageRoot.path)
        XCTAssertEqual(
            request.expectedProvenanceSHA256,
            verifiedStage.provenance.markerSHA256
        )
        XCTAssertEqual(request.expectedArtifactSHA256, marker.artifactSha256)
        XCTAssertEqual(request.provenanceEntries, marker.entries)
    }

    func testHelperRequestUsesExactCanonicalProtocolV1Shape() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let stageRoot = try StageProvenance.createOwnedStage(parent: parent)
        let stagedApp = stageRoot.appendingPathComponent("Example.app")
        let executable = stagedApp.appendingPathComponent(
            "Contents/MacOS/Example"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: executable)
        let signature = Data(repeating: 7, count: 64).base64EncodedString()
        let manifest: [String: Any] = [
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "version": "2.8.0",
            "buildNumber": 280,
            "artifact": [
                "sha256": String(repeating: "c", count: 64),
                "length": 123,
            ],
            "install": [
                "strategy": "pkgInstaller",
                "macosPkg": [
                    "launchMode": "privilegedInstallerTool",
                    "expectedPackageIds": ["com.example.app.pkg"],
                    "relaunchAfterInstall": false,
                ],
            ],
            "signature": [
                "algorithm": "ed25519",
                "publicKeyId": "stable-2026",
                "value": signature,
            ],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try manifestData.write(
            to: stageRoot.appendingPathComponent(
                ".desktop_updater_release_manifest.json"
            )
        )
        let nonce = String(
            stageRoot.lastPathComponent.dropFirst(
                updaterOwnedStagePrefix.count
            )
        )
        let provenance = try StageProvenance.write(
            stageRoot: stageRoot,
            nonce: nonce,
            packageID: "com.example.app",
            descriptorSHA256: try StageProvenance.canonicalJSONSHA256(
                manifest
            ),
            artifactSHA256: String(repeating: "c", count: 64)
        )
        let request = MacInstallRequest(
            verifiedStage: MacVerifiedStage(
                stagedPath: stagedApp,
                stageRoot: stageRoot,
                provenance: provenance,
                artifactKind: "zip"
            ),
            allowUnsignedUpdates: false,
            diagnosticsLogPath: nil
        )

        let data = try request.helperRequestData(
            transactionID: "00000000-0000-4000-8000-000000000099",
            processIdentifier: 4_243,
            bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
            evidence: MacInstallRequestEvidence(
                policyID: "com.example.desktop-updater.privileged",
                packageID: "com.example.app",
                processStartIdentity: "pid-start-99",
                executableSHA256: String(repeating: "a", count: 64),
                signerIdentity: "identifier com.example.app",
                targetClass: "applicationBundle",
                executableRelativePath: "Contents/MacOS/Example",
                currentVersion: "2.7.0",
                currentBuildNumber: 270,
                currentPackageIdentitySHA256:
                    String(repeating: "b", count: 64),
                targetIdentityProofSHA256:
                    String(repeating: "a", count: 64),
                requestNonce:
                    "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion", "protocolVersion", "transactionId",
                "policyId", "packageId", "strategy", "provider",
                "target", "currentIdentity", "desiredIdentity", "stage",
                "signedDescriptor", "caller", "requestNonce",
                "diagnosticsDestination",
            ]
        )
        XCTAssertNil(object["operation"])
        XCTAssertNil(object["options"])
        let stage = try XCTUnwrap(object["stage"] as? [String: Any])
        XCTAssertEqual(
            Set(stage.keys),
            [
                "pathHint", "ownershipNonce", "provenanceSha256",
                "artifactSha256", "artifactLength",
            ]
        )
        XCTAssertEqual(stage["artifactLength"] as? Int, 123)
        let descriptor = try XCTUnwrap(
            object["signedDescriptor"] as? [String: Any]
        )
        XCTAssertEqual(descriptor["signatureBase64"] as? String, signature)
        XCTAssertEqual(
            descriptor["canonicalSha256"] as? String,
            provenance.marker.descriptorSha256
        )

        let mismatchedPackageIDs = MacInstallRequest(
            stagingPath: stagedApp.path,
            allowUnsignedUpdates: false,
            diagnosticsLogPath: nil,
            stageRoot: stageRoot.path,
            expectedProvenanceSHA256: provenance.markerSHA256,
            artifactKind: "pkgInstaller",
            expectedArtifactSHA256: String(repeating: "c", count: 64),
            expectedPackageIDs: ["com.example.attacker.pkg"],
            provenanceEntries: provenance.marker.entries
        )
        XCTAssertThrowsError(
            try mismatchedPackageIDs.helperRequestData(
                transactionID: "00000000-0000-4000-8000-000000000099",
                processIdentifier: 4_243,
                bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
                evidence: MacInstallRequestEvidence(
                    policyID: "com.example.desktop-updater.privileged",
                    packageID: "com.example.app",
                    processStartIdentity: "pid-start-99",
                    executableSHA256: String(repeating: "a", count: 64),
                    signerIdentity: "identifier com.example.app",
                    targetClass: "applicationBundle",
                    executableRelativePath: "Contents/MacOS/Example",
                    currentVersion: "2.7.0",
                    currentBuildNumber: 270,
                    currentPackageIdentitySHA256:
                        String(repeating: "b", count: 64),
                    targetIdentityProofSHA256:
                        String(repeating: "a", count: 64),
                    requestNonce:
                        "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
                )
            )
        )
    }

    func testDefaultClientFailsClosedWhenPackagedEndpointIsUnavailable() {
        let request = MacInstallRequest(
            stagingPath: nil,
            allowUnsignedUpdates: false,
            diagnosticsLogPath: nil
        )

        XCTAssertThrowsError(
            try MacInstallHelper().scheduleInstallAndRelaunch(request)
        ) { error in
            XCTAssertEqual(
                error as? MacInstallClientError,
                .endpointUnavailable
            )
        }
    }

    func testPrepareInstallUsesCallerProvidedTransactionID() throws {
        let fixture = try CallerTransactionFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = CapturingInstallHelperTransport()
        let helper = MacInstallHelper(
            targetResolver: {
                MacInstallTarget(
                    processIdentifier: 4_243,
                    bundleURL: URL(fileURLWithPath: "/Applications/Example.app")
                )
            },
            evidenceBuilder: FixedInstallRequestEvidenceBuilder(),
            transport: transport
        )
        let transactionID = "00000000-0000-4000-8000-000000000099"

        let reservation = try helper.prepareInstall(
            fixture.request,
            transactionID: transactionID
        )

        XCTAssertEqual(reservation.transactionID, transactionID)
        XCTAssertEqual(transport.preparedTransactionID, transactionID)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(transport.preparedRequest)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["transactionId"] as? String, transactionID)
    }

    func testPrepareInstallRejectsNonCanonicalCallerTransactionID() throws {
        let fixture = try CallerTransactionFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = CapturingInstallHelperTransport()
        let helper = MacInstallHelper(
            targetResolver: {
                MacInstallTarget(
                    processIdentifier: 4_243,
                    bundleURL: URL(fileURLWithPath: "/Applications/Example.app")
                )
            },
            evidenceBuilder: FixedInstallRequestEvidenceBuilder(),
            transport: transport
        )

        XCTAssertThrowsError(
            try helper.prepareInstall(
                fixture.request,
                transactionID: "123e4567-e89b-42d3-a456-426614174099".uppercased()
            )
        ) { error in
            XCTAssertEqual(error as? MacInstallClientError, .invalidTransactionID)
        }
        XCTAssertNil(transport.preparedRequest)
    }

    func testPrepareInstallRejectsCanonicalNonV4CallerTransactionID() throws {
        let fixture = try CallerTransactionFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = CapturingInstallHelperTransport()
        let helper = MacInstallHelper(
            targetResolver: {
                MacInstallTarget(
                    processIdentifier: 4_243,
                    bundleURL: URL(fileURLWithPath: "/Applications/Example.app")
                )
            },
            evidenceBuilder: FixedInstallRequestEvidenceBuilder(),
            transport: transport
        )

        XCTAssertThrowsError(
            try helper.prepareInstall(
                fixture.request,
                transactionID: "00000000-0000-1000-8000-000000000099"
            )
        ) { error in
            XCTAssertEqual(error as? MacInstallClientError, .invalidTransactionID)
        }
        XCTAssertNil(transport.preparedRequest)
    }

    func testPrepareTransportFailureRequiresCallerTransactionRecovery() throws {
        let fixture = try CallerTransactionFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = CapturingInstallHelperTransport()
        transport.prepareError = MacInstallClientError.endpointUnavailable
        let helper = MacInstallHelper(
            targetResolver: {
                MacInstallTarget(
                    processIdentifier: 4_243,
                    bundleURL: URL(fileURLWithPath: "/Applications/Example.app")
                )
            },
            evidenceBuilder: FixedInstallRequestEvidenceBuilder(),
            transport: transport
        )

        XCTAssertThrowsError(
            try helper.prepareInstall(
                fixture.request,
                transactionID: "00000000-0000-4000-8000-000000000099"
            )
        ) { error in
            XCTAssertEqual(
                error as? MacInstallClientError,
                .installRecoveryRequired
            )
        }
    }

    func testCommitTransportFailureRequiresCallerTransactionRecovery() throws {
        let fixture = try CallerTransactionFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = CapturingInstallHelperTransport()
        let helper = MacInstallHelper(
            targetResolver: {
                MacInstallTarget(
                    processIdentifier: 4_243,
                    bundleURL: URL(fileURLWithPath: "/Applications/Example.app")
                )
            },
            evidenceBuilder: FixedInstallRequestEvidenceBuilder(),
            transport: transport
        )
        let reservation = try helper.prepareInstall(
            fixture.request,
            transactionID: "00000000-0000-4000-8000-000000000099"
        )
        transport.commitError = MacInstallClientError.endpointUnavailable

        XCTAssertThrowsError(
            try helper.commitAfterExit(reservation)
        ) { error in
            XCTAssertEqual(
                error as? MacInstallClientError,
                .installRecoveryRequired
            )
        }
    }

    func testCanonicalHelperEventsMatchTheDartFixture() throws {
        let fixture: HelperEventsFixture = try decodeFixture(
            "helper-events.json"
        )

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.events,
            MacHelperEvent.allCases.map(\.rawValue)
        )
    }

    func testCanonicalDiagnosticsFixtureIsConsumable() throws {
        let fixture: DiagnosticsFixture = try decodeFixture(
            "diagnostics-redaction-cases.json"
        )
        let first = try XCTUnwrap(fixture.cases.first)
        let event = MacDiagnosticEvent(
            timestamp: first.timestamp,
            event: first.name
        )

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertFalse(first.expectedLogLine.isEmpty)
        XCTAssertEqual(event.timestamp, first.timestamp)
    }

}

private struct CallerTransactionFixture {
    let root: URL
    let request: MacInstallRequest

    static func create() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let stageRoot = try StageProvenance.createOwnedStage(parent: root)
        let stagedApp = stageRoot.appendingPathComponent("Example.app")
        let executable = stagedApp.appendingPathComponent(
            "Contents/MacOS/Example"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: executable)
        let artifactSHA256 = String(repeating: "c", count: 64)
        let manifest: [String: Any] = [
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "version": "2.8.0",
            "buildNumber": 280,
            "artifact": [
                "sha256": artifactSHA256,
                "length": 123,
            ],
            "signature": [
                "algorithm": "ed25519",
                "publicKeyId": "stable-2026",
                "value": Data(repeating: 7, count: 64).base64EncodedString(),
            ],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try manifestData.write(
            to: stageRoot.appendingPathComponent(
                ".desktop_updater_release_manifest.json"
            )
        )
        let nonce = String(
            stageRoot.lastPathComponent.dropFirst(updaterOwnedStagePrefix.count)
        )
        let provenance = try StageProvenance.write(
            stageRoot: stageRoot,
            nonce: nonce,
            packageID: "com.example.app",
            descriptorSHA256: try StageProvenance.canonicalJSONSHA256(manifest),
            artifactSHA256: artifactSHA256
        )
        return Self(
            root: root,
            request: MacInstallRequest(
                verifiedStage: MacVerifiedStage(
                    stagedPath: stagedApp,
                    stageRoot: stageRoot,
                    provenance: provenance,
                    artifactKind: "zip"
                ),
                allowUnsignedUpdates: false,
                diagnosticsLogPath: nil
            )
        )
    }
}

private struct FixedInstallRequestEvidenceBuilder:
    MacInstallRequestEvidenceBuilding
{
    func build(for _: MacInstallTarget) throws -> MacInstallRequestEvidence {
        MacInstallRequestEvidence(
            policyID: "com.example.desktop-updater.privileged",
            packageID: "com.example.app",
            processStartIdentity: "pid-start-99",
            executableSHA256: String(repeating: "a", count: 64),
            signerIdentity: "identifier com.example.app",
            targetClass: "applicationBundle",
            executableRelativePath: "Contents/MacOS/Example",
            currentVersion: "2.7.0",
            currentBuildNumber: 270,
            currentPackageIdentitySHA256: String(repeating: "b", count: 64),
            targetIdentityProofSHA256: String(repeating: "a", count: 64),
            requestNonce: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
        )
    }
}

private final class CapturingInstallHelperTransport: MacInstallHelperTransport {
    var preparedRequest: Data?
    var preparedTransactionID: String?
    var prepareError: Error?
    var commitError: Error?

    func prepareInstall(
        request: Data,
        transactionID: String
    ) throws -> InstallReservationResponseV1 {
        preparedRequest = request
        preparedTransactionID = transactionID
        if let prepareError {
            throw prepareError
        }
        return InstallReservationResponseV1(
            protocolVersion: 1,
            transactionID: transactionID,
            readyToken: String(repeating: "a", count: 43),
            journalSHA256: String(repeating: "b", count: 64),
            helperEndpointIdentitySHA256: String(repeating: "c", count: 64),
            expiresAtUnixMilliseconds: 1
        )
    }

    func commitAfterExit(
        transactionID: String,
        readyToken _: String
    ) throws -> InstallTransactionStatus {
        if let commitError {
            throw commitError
        }
        return status(transactionID: transactionID)
    }

    func cancelReservation(
        transactionID: String,
        readyToken _: String
    ) throws -> InstallTransactionStatus {
        status(transactionID: transactionID)
    }

    func queryTransaction(
        transactionID: String
    ) throws -> InstallTransactionStatus {
        status(transactionID: transactionID)
    }

    func recoverPendingInstall(
        transactionID: String
    ) throws -> InstallTransactionStatus {
        status(transactionID: transactionID)
    }

    private func status(transactionID: String) -> InstallTransactionStatus {
        InstallTransactionStatus(
            transactionID: transactionID,
            state: .prepared,
            resultCode: .accepted,
            detail: "",
            responseDigestSHA256: String(repeating: "b", count: 64),
            helperEndpointIdentitySHA256: String(repeating: "c", count: 64)
        )
    }
}

private struct HelperEventsFixture: Decodable {
    let schemaVersion: Int
    let events: [String]
}

private struct DiagnosticsFixture: Decodable {
    let schemaVersion: Int
    let cases: [DiagnosticsCase]
}

private struct DiagnosticsCase: Decodable {
    let name: String
    let timestamp: String
    let expectedLogLine: String
}

private func decodeFixture<Value: Decodable>(_ name: String) throws -> Value {
    let root = try repositoryRoot()
    let file = root
        .appendingPathComponent("fixtures")
        .appendingPathComponent("compat")
        .appendingPathComponent("native-contract")
        .appendingPathComponent(name)
    return try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
}

private func repositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fileManager = FileManager.default
    while candidate.path != "/" {
        let fixtureDirectory = candidate
            .appendingPathComponent("fixtures")
            .appendingPathComponent("compat")
            .appendingPathComponent("native-contract")
        if fileManager.fileExists(atPath: fixtureDirectory.path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
