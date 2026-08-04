import XCTest
@testable import DesktopUpdaterKit

final class MacInstallCrashRecoveryTests: XCTestCase {
    func testCallerExitBeforeCommitLeavesHelperInCancellationState() throws {
        let reservation = try InstallReservation(
            response: InstallReservationResponseV1(
                protocolVersion: 1,
                transactionID: "00000000-0000-4000-8000-000000000006",
                readyToken: String(repeating: "A", count: 43),
                journalSHA256: String(repeating: "b", count: 64),
                helperEndpointIdentitySHA256: String(repeating: "c", count: 64),
                expiresAtUnixMilliseconds: 100
            )
        )

        try reservation.callerExitedBeforeCommit()

        XCTAssertEqual(reservation.state, .cancelled)
        XCTAssertThrowsError(try reservation.requestCommit(now: 99))
    }
}
