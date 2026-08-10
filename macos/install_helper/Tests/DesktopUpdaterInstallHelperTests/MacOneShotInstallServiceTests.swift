import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacOneShotInstallServiceTests: XCTestCase {
    func testPrepareAndCommitDoNotMutateUntilCallerExitIsObserved() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        let session = MacOneShotInstallSession(
            authorizer: FixtureOneShotAuthorizer(transaction: transaction),
            readyTokenGenerator: {
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            },
            nowUnixMilliseconds: { 1_000 },
            reservationLifetimeMilliseconds: 60_000
        )

        let reservation = try session.prepare(
            requestData: try canonicalRequestData()
        )

        XCTAssertEqual(reservation.protocolVersion, 1)
        XCTAssertEqual(reservation.transactionID, fixture.transactionID)
        XCTAssertEqual(reservation.journalSHA256.count, 64)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")

        let accepted = try session.acceptCommit(
            transactionID: reservation.transactionID,
            readyToken: reservation.readyToken,
            journalSHA256: reservation.journalSHA256,
            helperEndpointIdentitySHA256:
                reservation.helperEndpointIdentitySHA256
        )

        XCTAssertEqual(accepted.state, "commitAccepted")
        XCTAssertEqual(accepted.resultCode, "accepted")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")

        let completed = try session.executeAfterCallerExit()

        XCTAssertEqual(completed.state, "completed")
        XCTAssertEqual(completed.resultCode, "completed")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testCancelValidatesEveryReservationBindingBeforeCleanup() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        let session = MacOneShotInstallSession(
            authorizer: FixtureOneShotAuthorizer(transaction: transaction),
            readyTokenGenerator: {
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            },
            nowUnixMilliseconds: { 1_000 },
            reservationLifetimeMilliseconds: 60_000
        )
        let reservation = try session.prepare(
            requestData: try canonicalRequestData()
        )

        XCTAssertThrowsError(
            try session.cancel(
                transactionID: reservation.transactionID,
                readyToken: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                journalSHA256: reservation.journalSHA256,
                helperEndpointIdentitySHA256:
                    reservation.helperEndpointIdentitySHA256
            )
        ) { error in
            XCTAssertEqual(
                error as? MacOneShotInstallError,
                .reservationBindingMismatch
            )
        }
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")

        let cancelled = try session.cancel(
            transactionID: reservation.transactionID,
            readyToken: reservation.readyToken,
            journalSHA256: reservation.journalSHA256,
            helperEndpointIdentitySHA256:
                reservation.helperEndpointIdentitySHA256
        )

        XCTAssertEqual(cancelled.state, "cancelled")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testExpiredReservationCannotCommitOrMutate() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        var now: Int64 = 1_000
        let session = MacOneShotInstallSession(
            authorizer: FixtureOneShotAuthorizer(
                transaction: try fixture.makeTransaction()
            ),
            readyTokenGenerator: {
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            },
            nowUnixMilliseconds: { now },
            reservationLifetimeMilliseconds: 10
        )
        let reservation = try session.prepare(
            requestData: try canonicalRequestData()
        )
        now = 1_011

        XCTAssertThrowsError(
            try session.acceptCommit(
                transactionID: reservation.transactionID,
                readyToken: reservation.readyToken,
                journalSHA256: reservation.journalSHA256,
                helperEndpointIdentitySHA256:
                    reservation.helperEndpointIdentitySHA256
            )
        ) { error in
            XCTAssertEqual(error as? MacOneShotInstallError, .expired)
        }
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testWireRuntimeWaitsForCallerExitAfterCommitAcceptance() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let session = MacOneShotInstallSession(
            authorizer: FixtureOneShotAuthorizer(
                transaction: try fixture.makeTransaction()
            ),
            readyTokenGenerator: {
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            },
            nowUnixMilliseconds: { 1_000 },
            reservationLifetimeMilliseconds: 60_000
        )
        let channel = RecordingOneShotWireChannel(
            requestData: try canonicalRequestData()
        )
        let monitorFactory = RecordingCallerMonitorFactory {
            XCTAssertEqual(channel.outputs.count, 2)
            XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
            XCTAssertEqual(channel.outputs[1], channel.outputs[0])
        }
        let diagnostics = RecordingMacHelperDiagnostics()
        let runtime = MacOneShotServiceRuntime(
            session: session,
            callerMonitorFactory: monitorFactory,
            diagnostics: diagnostics
        )

        try runtime.run(channel: channel)

        XCTAssertEqual(monitorFactory.processIdentifier, 4_243)
        XCTAssertEqual(monitorFactory.processStartIdentity, "pid-start-1")
        XCTAssertTrue(monitorFactory.didWait)
        XCTAssertEqual(diagnostics.configuredDestination?.kind, "platformLog")
        XCTAssertEqual(
            diagnostics.events,
            [.waitingForParentProcess, .parentProcessExited]
        )
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testWireRuntimeReturnsCanonicalRollbackForCancellation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let channel = RecordingOneShotWireChannel(
            requestData: try canonicalRequestData(),
            operation: "cancelReservation"
        )
        let monitorFactory = RecordingCallerMonitorFactory {}
        let runtime = MacOneShotServiceRuntime(
            session: MacOneShotInstallSession(
                authorizer: FixtureOneShotAuthorizer(
                    transaction: try fixture.makeTransaction()
                ),
                readyTokenGenerator: {
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                },
                nowUnixMilliseconds: { 1_000 },
                reservationLifetimeMilliseconds: 60_000
            ),
            callerMonitorFactory: monitorFactory
        )

        try runtime.run(channel: channel)

        let rollback = try XCTUnwrap(
            JSONSerialization.jsonObject(with: channel.outputs[1])
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(rollback.keys),
            [
                "protocolVersion", "transactionId", "resultCode",
                "verifiedOutcome", "journalSha256",
            ]
        )
        XCTAssertEqual(rollback["resultCode"] as? String, "rolledBack")
        XCTAssertEqual(rollback["verifiedOutcome"] as? String, "oldTarget")
        XCTAssertFalse(monitorFactory.didWait)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testWireRuntimeCancelsPreparedTransactionForInvalidCommand() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let channel = InvalidCommandOneShotWireChannel(
            requestData: try canonicalRequestData()
        )
        let monitorFactory = RecordingCallerMonitorFactory {}
        let runtime = MacOneShotServiceRuntime(
            session: MacOneShotInstallSession(
                authorizer: FixtureOneShotAuthorizer(
                    transaction: try fixture.makeTransaction()
                ),
                readyTokenGenerator: {
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                },
                nowUnixMilliseconds: { 1_000 },
                reservationLifetimeMilliseconds: 60_000
            ),
            callerMonitorFactory: monitorFactory
        )

        XCTAssertThrowsError(try runtime.run(channel: channel)) { error in
            XCTAssertEqual(error as? MacOneShotWireError, .invalidMessage)
        }

        XCTAssertFalse(monitorFactory.didWait)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testWireRuntimeCancelsCommitWhenCallerExitTimesOut() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let channel = RecordingOneShotWireChannel(
            requestData: try canonicalRequestData()
        )
        let monitorFactory = RecordingCallerMonitorFactory {
            throw MacCallerExitMonitorError.timedOut
        }
        let runtime = MacOneShotServiceRuntime(
            session: MacOneShotInstallSession(
                authorizer: FixtureOneShotAuthorizer(
                    transaction: try fixture.makeTransaction()
                ),
                readyTokenGenerator: {
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                },
                nowUnixMilliseconds: { 1_000 },
                reservationLifetimeMilliseconds: 60_000
            ),
            callerMonitorFactory: monitorFactory
        )

        XCTAssertThrowsError(try runtime.run(channel: channel)) { error in
            XCTAssertEqual(error as? MacCallerExitMonitorError, .timedOut)
        }

        XCTAssertTrue(monitorFactory.didWait)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }
}

private final class FixtureOneShotAuthorizer: MacOneShotInstallAuthorizing {
    let helperEndpointIdentitySHA256 = String(repeating: "f", count: 64)
    private let transaction: MacFileTransaction

    init(transaction: MacFileTransaction) {
        self.transaction = transaction
    }

    func authorize(
        _ request: NativeInstallTransactionRequestV1
    ) throws -> any MacPreparedInstallTransaction {
        XCTAssertEqual(request.protocolVersion, 1)
        return transaction
    }
}

private final class RecordingOneShotWireChannel: MacOneShotWireChannel {
    private let requestData: Data
    private let operation: String
    private var readCount = 0
    private(set) var outputs: [Data] = []

    init(
        requestData: Data,
        operation: String = "commitAfterExit"
    ) {
        self.requestData = requestData
        self.operation = operation
    }

    func readFrame() throws -> Data {
        defer { readCount += 1 }
        if readCount == 0 { return requestData }
        let reservation = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(outputs.first))
                as? [String: Any]
        )
        return try JSONSerialization.data(
            withJSONObject: [
                "operation": operation,
                "protocolVersion": 1,
                "transactionId": reservation["transactionId"] as Any,
                "readyToken": reservation["readyToken"] as Any,
                "journalSha256": reservation["journalSha256"] as Any,
                "helperEndpointIdentitySha256":
                    reservation["helperEndpointIdentitySha256"] as Any,
            ],
            options: [.sortedKeys]
        )
    }

    func writeFrame(_ data: Data) throws {
        outputs.append(data)
    }
}

private final class InvalidCommandOneShotWireChannel: MacOneShotWireChannel {
    private let requestData: Data
    private var readCount = 0

    init(requestData: Data) {
        self.requestData = requestData
    }

    func readFrame() throws -> Data {
        defer { readCount += 1 }
        return readCount == 0 ? requestData : Data("{}".utf8)
    }

    func writeFrame(_: Data) throws {}
}

private final class RecordingCallerMonitorFactory:
    MacCallerExitMonitorCreating,
    MacCallerExitMonitoring
{
    private let onWait: () throws -> Void
    private(set) var processIdentifier: Int64?
    private(set) var processStartIdentity: String?
    private(set) var didWait = false

    init(onWait: @escaping () throws -> Void) {
        self.onWait = onWait
    }

    func makeMonitor(
        processIdentifier: Int64,
        processStartIdentity: String
    ) throws -> any MacCallerExitMonitoring {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        return self
    }

    func waitForExit(expiresAtUnixMilliseconds _: Int64) throws {
        didWait = true
        try onWait()
    }
}

private func canonicalRequestData() throws -> Data {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate.appendingPathComponent(
            "fixtures/compat/native-install-helper/v1/valid-requests.json"
        )
        if FileManager.default.fileExists(atPath: file.path) {
            let fixture = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: file))
                    as? [String: Any]
            )
            let cases = try XCTUnwrap(
                fixture["cases"] as? [[String: Any]]
            )
            var request = try XCTUnwrap(
                try XCTUnwrap(cases.first)["request"] as? [String: Any]
            )
            request["transactionId"] =
                "00000000-0000-4000-8000-000000000006"
            return try JSONSerialization.data(
                withJSONObject: request,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
