import Foundation
import Dispatch
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacHelperDiagnosticsTests: XCTestCase {
    func testStructuredEventIsVersionedAndRedacted() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("events.jsonl")
        let recorder = MacHelperDiagnosticsRecorder(logURL: logURL)

        recorder.record(
            .backupSuccess,
            transactionID: "00000000-0000-4000-8000-000000000001",
            state: "backupCreated",
            resultCode: "success",
            detailCode: "password=should-not-appear"
        )
        recorder.record(
            .recoveryRequired,
            transactionID: "not-a-transaction",
            state: "/private/tmp/private-path",
            resultCode: "token=secret",
            detailCode: "none"
        )

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.joined().contains("should-not-appear"))
        XCTAssertFalse(lines.joined().contains("private-path"))
        XCTAssertFalse(lines.joined().contains("secret"))

        let decoder = JSONDecoder()
        let first = try decoder.decode(
            MacHelperDiagnosticEvent.self,
            from: Data(lines[0].utf8)
        )
        XCTAssertEqual(first.schemaVersion, 1)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.event, .backupSuccess)
        XCTAssertEqual(
            first.transactionID,
            "00000000-0000-4000-8000-000000000001"
        )
        XCTAssertEqual(first.state, "backupCreated")
        XCTAssertEqual(first.resultCode, "success")
        XCTAssertEqual(first.detailCode, "unknown")

        let second = try decoder.decode(
            MacHelperDiagnosticEvent.self,
            from: Data(lines[1].utf8)
        )
        XCTAssertNil(second.transactionID)
        XCTAssertEqual(second.state, "unknown")
        XCTAssertEqual(second.resultCode, "unknown")
    }

    func testFileSinkIsBoundedAndSinkFailureIsNonFatal() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("events.jsonl")
        let recorder = MacHelperDiagnosticsRecorder(
            logURL: logURL,
            maximumFileBytes: 4_096
        )

        for _ in 0 ..< 100 {
            recorder.record(
                .cleanupSuccess,
                transactionID:
                    "00000000-0000-4000-8000-000000000001",
                state: "completed",
                resultCode: "success",
                detailCode: "directory"
            )
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: logURL.path
        )
        XCTAssertLessThanOrEqual(
            (attributes[.size] as? NSNumber)?.intValue ?? Int.max,
            4_096
        )

        let failingRecorder = MacHelperDiagnosticsRecorder(
            logURL: URL(fileURLWithPath: "/dev/null/events.jsonl")
        )
        XCTAssertNoThrow(
            failingRecorder.record(
                .cleanupFailure,
                transactionID: nil,
                state: "recoveryRequired",
                resultCode: "failure",
                detailCode: "directory"
            )
        )
    }

    func testRecoveryMarkerClearedIsPartOfTheStableEventSet() {
        XCTAssertTrue(
            MacHelperEvent.allCases.contains(.recoveryMarkerCleared)
        )
        XCTAssertEqual(
            MacHelperEvent.recoveryMarkerCleared.rawValue,
            "recovery marker cleared"
        )
    }

    func testMultipleRecordersShareMonotonicFileSequence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("events.jsonl")

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let recorder = MacHelperDiagnosticsRecorder(
                logURL: logURL,
                maximumFileBytes: 16_384
            )
            recorder.record(
                .cleanupSuccess,
                transactionID:
                    "00000000-0000-4000-8000-000000000001",
                state: "completed",
                resultCode: "success",
                detailCode: "worker\(index)"
            )
        }

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 16)
        let events = try lines.map {
            try JSONDecoder().decode(
                MacHelperDiagnosticEvent.self,
                from: Data($0.utf8)
            )
        }
        XCTAssertEqual(
            events.map(\.sequence).sorted(),
            Array(1 ... 16)
        )
        XCTAssertEqual(
            Set(events.map(\.detailCode)).count,
            16
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "desktop-updater-diagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}

final class RecordingMacHelperDiagnostics: MacHelperDiagnosticsRecording {
    private(set) var configuredDestination:
        NativeInstallDiagnosticsDestinationV1?
    private(set) var events: [MacHelperEvent] = []

    func configure(destination: NativeInstallDiagnosticsDestinationV1?) {
        configuredDestination = destination
    }

    func record(
        _ event: MacHelperEvent,
        transactionID _: String?,
        state _: String,
        resultCode _: String,
        detailCode _: String
    ) {
        events.append(event)
    }
}
