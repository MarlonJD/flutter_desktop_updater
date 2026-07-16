import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class ArtifactStagerTests: XCTestCase {
    func testSafePathFixturesMatchDart() throws {
        let fixture = try stagingFixtureObject("safe-path-cases.json")
        let cases = try XCTUnwrap(fixture["archivePathCases"] as? [[String: Any]])

        for entry in cases {
            let input = try XCTUnwrap(entry["input"] as? String)
            let expectedValid = try XCTUnwrap(entry["expectedValid"] as? Bool)
            do {
                let normalized = try normalizeSafeArchivePath(input)
                XCTAssertTrue(expectedValid, input)
                XCTAssertEqual(
                    normalized,
                    entry["expectedNormalized"] as? String,
                    input
                )
            } catch {
                XCTAssertFalse(expectedValid, input)
            }
        }
    }

    func testZipPreflightEnforcesConfiguredLimitsBeforeExtraction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-stager-\(UUID().uuidString)")
        let payload = root.appendingPathComponent("Payload")
        let archive = root.appendingPathComponent("artifact.zip")
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x41, count: 32).write(
            to: payload.appendingPathComponent("payload.bin")
        )
        try runStagerFixtureCommand(
            "/usr/bin/ditto",
            ["-c", "-k", "--keepParent", payload.path, archive.path]
        )

        let stager = MacArtifactStager()
        XCTAssertNoThrow(
            try stager.preflightZip(archive, limits: RuntimeArchiveLimits())
        )
        XCTAssertThrowsError(
            try stager.preflightZip(
                archive,
                limits: RuntimeArchiveLimits(maximumSingleEntryBytes: 4)
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("unsafeArchive"))
        }
    }

    func testZip64CentralDirectoryUsesChecked64BitSizes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-zip64-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let safe = root.appendingPathComponent("safe.zip")
        let oversized = root.appendingPathComponent("oversized.zip")
        let mismatched = root.appendingPathComponent("mismatched.zip")
        try zip64CentralDirectory(uncompressedSize: 0).write(to: safe)
        try zip64CentralDirectory(uncompressedSize: UInt64.max).write(
            to: oversized
        )
        var mismatchedData = zip64CentralDirectory(uncompressedSize: 0)
        mismatchedData[30] = UInt8(ascii: "x")
        try mismatchedData.write(to: mismatched)

        let stager = MacArtifactStager()
        XCTAssertNoThrow(
            try stager.preflightZip(safe, limits: RuntimeArchiveLimits())
        )
        XCTAssertThrowsError(
            try stager.preflightZip(
                oversized,
                limits: RuntimeArchiveLimits()
            )
        )
        XCTAssertThrowsError(
            try stager.preflightZip(
                mismatched,
                limits: RuntimeArchiveLimits()
            )
        )
    }

    func testPKGFinalizationRemovesExpansionBeforeProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-pkg-finalize-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = try StageProvenance.createOwnedStage(parent: parent)
        let expanded = stage.appendingPathComponent("expanded-pkg")
        try FileManager.default.createDirectory(
            at: expanded,
            withIntermediateDirectories: false
        )
        try Data("verification-only".utf8).write(
            to: expanded.appendingPathComponent("PackageInfo")
        )
        try Data("installer".utf8).write(
            to: stage.appendingPathComponent("installer.pkg")
        )
        try Data("{}".utf8).write(
            to: stage.appendingPathComponent(
                ".desktop_updater_release_manifest.json"
            )
        )
        let descriptor = try ReleaseDescriptor(
            jsonData: JSONSerialization.data(
                withJSONObject: stagingFixtureObject(
                    "release-contract/release-macos-pkg.json"
                )
            )
        )

        let result = try MacArtifactStager().finalizePKGStage(
            stageRoot: stage,
            expanded: expanded,
            descriptor: descriptor
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: expanded.path))
        XCTAssertNoThrow(
            try StageProvenance.verify(
                stageRoot: stage,
                expectedMarkerSHA256: result.provenance.markerSHA256
            )
        )
        XCTAssertFalse(
            result.provenance.marker.entries.contains {
                $0.path == "expanded-pkg" ||
                    $0.path.hasPrefix("expanded-pkg/")
            }
        )
    }
}

private func zip64CentralDirectory(uncompressedSize: UInt64) -> Data {
    var local = Data()
    local.appendUInt32(0x0403_4b50)
    local.appendUInt16(45)
    local.appendUInt16(0)
    local.appendUInt16(0)
    local.appendUInt16(0)
    local.appendUInt16(0)
    local.appendUInt32(0)
    local.appendUInt32(0)
    local.appendUInt32(UInt32.max)
    local.appendUInt16(4)
    local.appendUInt16(0)
    local.append(Data("file".utf8))

    var central = Data()
    central.appendUInt32(0x0201_4b50)
    central.appendUInt16(0x032d)
    central.appendUInt16(45)
    central.appendUInt16(0)
    central.appendUInt16(0)
    central.appendUInt16(0)
    central.appendUInt16(0)
    central.appendUInt32(0)
    central.appendUInt32(0)
    central.appendUInt32(UInt32.max)
    central.appendUInt16(4)
    central.appendUInt16(12)
    central.appendUInt16(0)
    central.appendUInt16(0)
    central.appendUInt16(0)
    central.appendUInt32(0o100644 << 16)
    central.appendUInt32(0)
    central.append(Data("file".utf8))
    central.appendUInt16(0x0001)
    central.appendUInt16(8)
    central.appendUInt64(uncompressedSize)

    var archive = local
    let centralOffset = UInt64(archive.count)
    archive.append(central)
    let zip64Offset = UInt64(archive.count)
    archive.appendUInt32(0x0606_4b50)
    archive.appendUInt64(44)
    archive.appendUInt16(45)
    archive.appendUInt16(45)
    archive.appendUInt32(0)
    archive.appendUInt32(0)
    archive.appendUInt64(1)
    archive.appendUInt64(1)
    archive.appendUInt64(UInt64(central.count))
    archive.appendUInt64(centralOffset)
    archive.appendUInt32(0x0706_4b50)
    archive.appendUInt32(0)
    archive.appendUInt64(zip64Offset)
    archive.appendUInt32(1)
    archive.appendUInt32(0x0605_4b50)
    archive.appendUInt16(0)
    archive.appendUInt16(0)
    archive.appendUInt16(UInt16.max)
    archive.appendUInt16(UInt16.max)
    archive.appendUInt32(UInt32.max)
    archive.appendUInt32(UInt32.max)
    archive.appendUInt16(0)
    return archive
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(truncatingIfNeeded: value))
        appendUInt16(UInt16(truncatingIfNeeded: value >> 16))
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(truncatingIfNeeded: value))
        appendUInt32(UInt32(truncatingIfNeeded: value >> 32))
    }
}

private func stagingFixtureObject(_ name: String) throws -> [String: Any] {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate
            .appendingPathComponent("fixtures")
            .appendingPathComponent("compat")
            .appendingPathComponent("native-contract")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            )
            return try XCTUnwrap(value as? [String: Any])
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func runStagerFixtureCommand(
    _ executable: String,
    _ arguments: [String]
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}
