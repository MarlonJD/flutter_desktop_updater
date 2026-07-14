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
}

private final class FixtureOneShotAuthorizer: MacOneShotInstallAuthorizing {
    let helperEndpointIdentitySHA256 = String(repeating: "f", count: 64)
    private let transaction: MacFileTransaction

    init(transaction: MacFileTransaction) {
        self.transaction = transaction
    }

    func authorize(
        _ request: NativeInstallTransactionRequestV1
    ) throws -> MacFileTransaction {
        XCTAssertEqual(request.protocolVersion, 1)
        return transaction
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
