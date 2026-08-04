import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class StageProvenanceTests: XCTestCase {
    func testCanonicalJSONSHA256MatchesKnownVector() throws {
        XCTAssertEqual(
            try StageProvenance.canonicalJSONSHA256(["value": "abc"]),
            "afef793fc69ce78450c4c66b8d52dd7c7779bfa4871c521469741f22d5dde564"
        )
        XCTAssertEqual(
            try StageProvenance.canonicalJSONSHA256([
                "url": "https://example.com/a/b",
            ]),
            "90fb5387e7b2517918a690fc0e0a236aeb837fea4787ac9e9c82924b8a3706f9"
        )
    }

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

    func testOwnedStageAcceptsExistingDirectoryURLWithoutDirectoryHint() throws {
        let directory = temporaryDirectory("owned-stage-no-directory-hint")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = URL(fileURLWithPath: directory.path, isDirectory: false)
        let nonce = UUID(uuidString: "223E4567-E89B-42D3-A456-426614174000")!

        let stage = try StageProvenance.createOwnedStage(
            parent: parent,
            nonce: nonce
        )

        XCTAssertEqual(
            stage.deletingLastPathComponent().standardizedFileURL.path,
            parent.standardizedFileURL.path
        )
    }

    func testInventoryIncludesVersionedFrameworkContentsAfterSymlink() throws {
        let parent = temporaryDirectory("stage-versioned-framework")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let nonce = UUID(uuidString: "323E4567-E89B-42D3-A456-426614174000")!
        let stage = try StageProvenance.createOwnedStage(
            parent: parent,
            nonce: nonce
        )
        let framework = stage.appendingPathComponent(
            "Example.app/Contents/Frameworks/Example.framework"
        )
        let versions = framework.appendingPathComponent("Versions")
        try FileManager.default.createDirectory(
            at: versions,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: versions.appendingPathComponent("Current").path,
            withDestinationPath: "A"
        )
        let resources = versions.appendingPathComponent("A/Resources")
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try Data("binary".utf8).write(
            to: versions.appendingPathComponent("A/Example")
        )
        try Data("metadata".utf8).write(
            to: resources.appendingPathComponent("Info.plist")
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Example").path,
            withDestinationPath: "Versions/Current/Example"
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Resources").path,
            withDestinationPath: "Versions/Current/Resources"
        )

        let state = try StageProvenance.write(
            stageRoot: stage,
            nonce: nonce.uuidString.lowercased(),
            packageID: "com.example.app",
            descriptorSHA256: String(repeating: "1", count: 64),
            artifactSHA256: String(repeating: "2", count: 64)
        )

        XCTAssertTrue(
            state.marker.entries.contains {
                $0.path.hasSuffix(
                    "Example.framework/Versions/A/Resources/Info.plist"
                )
            }
        )
        XCTAssertNoThrow(
            try StageProvenance.verify(
                stageRoot: stage,
                expectedMarkerSHA256: state.markerSHA256
            )
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
