import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacInstallReservationTests: XCTestCase {
    func testCallerExitBeforeCommitCancelsPreparedReservation() throws {
        let reservation = try makeReservation()
        try reservation.callerExitedBeforeCommit()
        XCTAssertEqual(reservation.state, .cancelled)
    }

    func testCommitTimeoutFailsClosed() throws {
        let reservation = try makeReservation(expiresAt: 100)
        XCTAssertThrowsError(try reservation.requestCommit(now: 101)) { error in
            XCTAssertEqual(error as? InstallReservationError, .expired)
        }
        XCTAssertEqual(reservation.state, .expired)
    }

    func testDuplicateCommitAndCancellationAfterCommitAreRejected() throws {
        let reservation = try makeReservation()
        try reservation.requestCommit(now: 10)
        XCTAssertEqual(reservation.state, .commitRequested)
        XCTAssertThrowsError(try reservation.requestCommit(now: 10))
        XCTAssertThrowsError(try reservation.requestCancellation())
    }

    func testReservationResponseRejectsWrongProtocolAndWeakToken() {
        XCTAssertThrowsError(
            try InstallReservation(
                response: InstallReservationResponseV1(
                    protocolVersion: 0,
                    transactionID: "00000000-0000-4000-8000-000000000001",
                    readyToken: "weak",
                    journalSHA256: String(repeating: "a", count: 64),
                    helperEndpointIdentitySHA256: String(repeating: "b", count: 64),
                    expiresAtUnixMilliseconds: 100
                )
            )
        )
    }
}

private func makeReservation(expiresAt: Int64 = 100) throws
    -> InstallReservation
{
    try InstallReservation(
        response: InstallReservationResponseV1(
            protocolVersion: 1,
            transactionID: "00000000-0000-4000-8000-000000000001",
            readyToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            journalSHA256: String(repeating: "a", count: 64),
            helperEndpointIdentitySHA256: String(repeating: "b", count: 64),
            expiresAtUnixMilliseconds: expiresAt
        )
    )
}
