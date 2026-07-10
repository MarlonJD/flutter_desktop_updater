import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class RuntimeDiagnosticsTests: XCTestCase {
    func testRedactionFixturesMatchDartExactly() throws {
        let fixture: RuntimeDiagnosticsFixture = try decodeRuntimeFixture(
            "diagnostics-redaction-cases.json"
        )

        for entry in fixture.cases {
            let diagnostic = RuntimeDiagnosticEntry(
                timestamp: entry.timestamp,
                stage: try XCTUnwrap(
                    RuntimeDiagnosticStage(rawValue: entry.stage)
                ),
                level: try XCTUnwrap(
                    RuntimeDiagnosticLevel(rawValue: entry.level)
                ),
                message: entry.message,
                errorDescription: entry.error.map { "FormatException: \($0)" }
            )
            XCTAssertEqual(
                diagnostic.redactedLogLine(),
                entry.expectedLogLine,
                entry.name
            )
        }
    }

    func testRecorderKeepsTheNewestEightyEntries() {
        var recorder = RuntimeDiagnosticsRecorder()
        for index in 0 ..< 82 {
            recorder.record(
                RuntimeDiagnosticEntry(
                    timestamp: "2026-07-10T12:00:00.000Z",
                    stage: .download,
                    level: .info,
                    message: "entry \(index)"
                )
            )
        }

        XCTAssertEqual(recorder.entries.count, 80)
        XCTAssertEqual(recorder.entries.first?.message, "entry 2")
        XCTAssertEqual(recorder.entries.last?.message, "entry 81")
        XCTAssertEqual(recorder.omittedEntryCount, 2)
    }

    func testPrivateKeyAndTokenMaterialAreRemovedFromExports() {
        let redacted = redactRuntimeDiagnosticText(
            "privateKeyMaterial=value access_token=secret safe=visible"
        )

        XCTAssertTrue(redacted.contains("privateKeyMaterial=<redacted>"))
        XCTAssertTrue(redacted.contains("access_token=<redacted>"))
        XCTAssertTrue(redacted.contains("safe=visible"))
        XCTAssertFalse(redacted.contains("=value"))
        XCTAssertFalse(redacted.contains("=secret"))
    }

    func testHelperRecoverySummaryDistinguishesSuccessAndRollback() throws {
        let fixture: RuntimeHelperEventsFixture = try decodeRuntimeFixture(
            "helper-events.json"
        )
        XCTAssertEqual(
            fixture.events,
            NativeHelperRecoveryEvent.allCases.map(\.rawValue)
        )

        let success = HelperRecoverySummary(events: [
            "helper scheduled",
            "staging path validation",
            "backup start",
            "backup success",
            "move start",
            "move success",
            "cleanup start",
            "cleanup success",
            "relaunch attempt",
        ])
        XCTAssertTrue(success.installSucceeded)
        XCTAssertTrue(success.cleanupSucceeded)
        XCTAssertFalse(success.rollbackAttempted)

        let failure = HelperRecoverySummary(events: [
            "backup start",
            "backup success",
            "move start",
            "move failure",
            "rollback start",
            "rollback success",
        ])
        XCTAssertFalse(failure.installSucceeded)
        XCTAssertTrue(failure.rollbackAttempted)
        XCTAssertTrue(failure.backupRestored)
    }
}

private struct RuntimeDiagnosticsFixture: Decodable {
    let cases: [RuntimeDiagnosticsCase]
}

private struct RuntimeDiagnosticsCase: Decodable {
    let name: String
    let timestamp: String
    let stage: String
    let level: String
    let message: String
    let error: String?
    let expectedLogLine: String
}

private struct RuntimeHelperEventsFixture: Decodable {
    let events: [String]
}

private func decodeRuntimeFixture<Value: Decodable>(
    _ name: String
) throws -> Value {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate
            .appendingPathComponent("fixtures")
            .appendingPathComponent("compat")
            .appendingPathComponent("native-contract")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode(
                Value.self,
                from: Data(contentsOf: file)
            )
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
