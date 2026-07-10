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

        XCTAssertEqual(request.stagingPath, "/tmp/Example.app")
        XCTAssertFalse(request.allowUnsignedUpdates)
        XCTAssertFalse(
            Mirror(reflecting: request).children.contains {
                $0.label == "currentProcessIdentifier" || $0.label == "bundlePath"
            }
        )
        XCTAssertEqual(diagnosticsEvent.event, "helper scheduled")
        XCTAssertNotNil(helper)
    }
}
