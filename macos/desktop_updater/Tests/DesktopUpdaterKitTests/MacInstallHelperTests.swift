import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacInstallHelperTests: XCTestCase {
    func testUnsignedUpdatesRemainExplicitlyOptIn() {
        let helper = MacInstallHelper()
        let protectedScript = helper.makeHelperScript(
            for: request(allowUnsignedUpdates: false)
        )
        let bypassScript = helper.makeHelperScript(
            for: request(allowUnsignedUpdates: true)
        )

        XCTAssertTrue(protectedScript.contains("ALLOW_UNSIGNED_MACOS"))
        XCTAssertTrue(protectedScript.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(protectedScript.contains("spctl --assess --type execute"))
        XCTAssertTrue(protectedScript.contains("xcrun stapler validate"))
        XCTAssertFalse(protectedScript.contains("ALLOW_UNSIGNED_MACOS=\"1\""))
        XCTAssertTrue(
            bypassScript.contains("ALLOW_UNSIGNED_MACOS=\"1\"") ||
                bypassScript.contains("DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS:-1")
        )
    }

    func testAppBundleAndPkgHandoffGatesRemainInGeneratedScript() {
        let script = MacInstallHelper().makeHelperScript(
            for: request(allowUnsignedUpdates: false)
        )

        XCTAssertTrue(script.contains("CFBundleIdentifier mismatch"))
        XCTAssertTrue(script.contains("TeamIdentifier mismatch"))
        XCTAssertTrue(script.contains("pkgInstaller"))
        XCTAssertTrue(script.contains("installerApp"))
        XCTAssertTrue(script.contains("/usr/bin/open \"$PKG\""))
        XCTAssertTrue(script.contains("log_event \"backup start\""))
        XCTAssertTrue(script.contains("log_event \"rollback success\""))
        XCTAssertTrue(script.contains("log_event \"cleanup success\""))
        XCTAssertTrue(script.contains("open -n \"$BUNDLE\""))
    }

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

    func testHelperScriptCollisionFailsWithoutReplacingExistingFile() throws {
        let nonce = UUID()
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "desktop_updater_\(nonce.uuidString).command"
            )
        let sentinel = Data("existing helper".utf8)
        try sentinel.write(to: script, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: script) }

        XCTAssertThrowsError(try MacInstallHelper().writeHelperScript(
            for: request(allowUnsignedUpdates: true),
            nonce: nonce
        ))
        XCTAssertEqual(try Data(contentsOf: script), sentinel)
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

    private func request(allowUnsignedUpdates: Bool) -> MacInstallRequest {
        return MacInstallRequest(
            stagingPath: "/tmp/Example.app",
            allowUnsignedUpdates: allowUnsignedUpdates,
            diagnosticsLogPath: "/tmp/desktop_updater.jsonl",
            currentProcessIdentifier: 42,
            bundlePath: "/Applications/Example.app"
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
