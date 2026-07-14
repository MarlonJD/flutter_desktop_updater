import DesktopUpdaterKit
import XCTest

final class DesktopUpdaterKitPublicAPITests: XCTestCase {
    func testPublicValueTypesHaveExternalInitializers() {
        let request = MacInstallRequest(
            stagingPath: "/tmp/Example.app",
            allowUnsignedUpdates: false,
            diagnosticsLogPath: "/tmp/desktop_updater.jsonl"
        )
        let diagnosticsEvent = MacDiagnosticEvent(
            timestamp: "2026-07-10T12:00:00Z",
            event: MacHelperEvent.helperScheduled.rawValue
        )
        let helper = MacInstallHelper()
        let prepareInstall: (MacInstallRequest) throws
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

        XCTAssertEqual(request.stagingPath, "/tmp/Example.app")
        XCTAssertFalse(request.allowUnsignedUpdates)
        XCTAssertFalse(
            Mirror(reflecting: request).children.contains {
                $0.label == "currentProcessIdentifier" || $0.label == "bundlePath"
            }
        )
        XCTAssertEqual(diagnosticsEvent.event, "helper scheduled")
        XCTAssertEqual(status.state, .prepared)
        XCTAssertEqual(status.resultCode, .accepted)
        XCTAssertNotNil(helper)
        XCTAssertNotNil(prepareInstall)
        XCTAssertNotNil(commitAfterExit)
        XCTAssertNotNil(cancelReservation)
        XCTAssertNotNil(queryTransaction)
        XCTAssertNotNil(recoverPendingInstall)
    }
}
