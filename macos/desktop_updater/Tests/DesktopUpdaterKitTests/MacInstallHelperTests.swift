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
