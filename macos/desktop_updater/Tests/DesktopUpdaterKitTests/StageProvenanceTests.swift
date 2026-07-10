import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class StageProvenanceTests: XCTestCase {
    func testOwnedStagePreservesParentAndUsesExclusiveNonceChild() throws {
        let parent = temporaryDirectory("owned-stage")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("sentinel.txt")
        try Data("caller-owned".utf8).write(to: sentinel)
        let nonce = UUID(uuidString: "123E4567-E89B-42D3-A456-426614174000")!

        let stage = try StageProvenance.createOwnedStage(
            parent: parent,
            nonce: nonce
        )

        XCTAssertEqual(
            stage.deletingLastPathComponent().standardizedFileURL.path,
            parent.standardizedFileURL.path
        )
        XCTAssertEqual(
            stage.lastPathComponent,
            "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000"
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("caller-owned".utf8))
        XCTAssertThrowsError(
            try StageProvenance.createOwnedStage(parent: parent, nonce: nonce)
        )
    }

    func testMarkerInventoryRejectsFileAndSymlinkTampering() throws {
        let parent = temporaryDirectory("stage-provenance")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let nonce = UUID(uuidString: "123E4567-E89B-42D3-A456-426614174000")!
        let stage = try StageProvenance.createOwnedStage(
            parent: parent,
            nonce: nonce
        )
        let payload = stage.appendingPathComponent("payload.bin")
        try Data([1, 2, 3]).write(to: payload)
        let link = stage.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "payload.bin"
        )
        let state = try StageProvenance.write(
            stageRoot: stage,
            nonce: nonce.uuidString.lowercased(),
            packageID: "com.example.app",
            descriptorSHA256: String(repeating: "1", count: 64),
            artifactSHA256: String(repeating: "2", count: 64)
        )
        let paths = state.marker.entries.map(\.path)
        XCTAssertEqual(paths, ["current", "payload.bin"])
        XCTAssertNoThrow(
            try StageProvenance.verify(
                stageRoot: stage,
                expectedMarkerSHA256: state.markerSHA256
            )
        )

        try Data([1, 9, 3]).write(to: payload)
        XCTAssertThrowsError(
            try StageProvenance.verify(
                stageRoot: stage,
                expectedMarkerSHA256: state.markerSHA256
            )
        )
        try Data([1, 2, 3]).write(to: payload)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "other.bin"
        )
        XCTAssertThrowsError(
            try StageProvenance.verify(
                stageRoot: stage,
                expectedMarkerSHA256: state.markerSHA256
            )
        )
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)"
        )
    }
}
