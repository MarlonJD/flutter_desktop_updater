import DesktopUpdaterKit
import XCTest

final class DesktopUpdaterKitPublicAPITests: XCTestCase {
    func testPublicInstallSurfaceRequiresVerifiedStageAndExplicitTransaction() {
        let diagnosticsEvent = MacDiagnosticEvent(
            timestamp: "2026-07-10T12:00:00Z",
            event: MacHelperEvent.helperScheduled.rawValue
        )
        let helper = MacInstallHelper()
        let loadAndVerify: (
            URL,
            URL,
            String,
            [String: Data]
        ) throws -> MacVerifiedStage = MacVerifiedStage.loadAndVerify
        let makeRequest: (MacVerifiedStage) -> MacInstallRequest =
            MacInstallRequest.init(verifiedStage:)
        let prepareInstall: (MacInstallRequest, String) throws
            -> MacInstallReservation = helper.prepareInstall
        let commitAfterExit: (MacInstallReservation) throws
            -> InstallTransactionStatus = helper.commitAfterExit
        let cancelReservation: (MacInstallReservation) throws
            -> InstallTransactionStatus = helper.cancelReservation
        let queryTransaction: (String) throws
            -> InstallTransactionStatus = helper.queryTransaction
        let recoverPendingInstall: (String) throws
            -> InstallTransactionStatus = helper.recoverPendingInstall
        let status = InstallTransactionStatus(
            transactionID: "00000000-0000-4000-8000-000000000001",
            state: .prepared,
            resultCode: .accepted,
            detail: "prepared",
            responseDigestSHA256: String(repeating: "a", count: 64),
            helperEndpointIdentitySHA256: String(
                repeating: "b",
                count: 64
            )
        )

        XCTAssertEqual(diagnosticsEvent.event, "helper scheduled")
        XCTAssertEqual(status.state, .prepared)
        XCTAssertEqual(status.resultCode, .accepted)
        XCTAssertNotNil(helper)
        XCTAssertNotNil(loadAndVerify)
        XCTAssertNotNil(makeRequest)
        XCTAssertNotNil(prepareInstall)
        XCTAssertNotNil(commitAfterExit)
        XCTAssertNotNil(cancelReservation)
        XCTAssertNotNil(queryTransaction)
        XCTAssertNotNil(recoverPendingInstall)
    }
}
