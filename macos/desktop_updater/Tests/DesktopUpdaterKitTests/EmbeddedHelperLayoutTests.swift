import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class EmbeddedHelperLayoutTests: XCTestCase {
    func testOneShotHelperUsesOnlyTheFixedNestedLocation() {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        let locator = EmbeddedHelperLocator(applicationBundleURL: bundle)

        XCTAssertEqual(
            locator.oneShotHelperURL.path,
            "/Applications/Example.app/Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        XCTAssertEqual(
            EmbeddedHelperLocator.oneShotRelativePath,
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
    }

    func testPrivilegedPayloadUsesTheFixedLaunchServicesDirectory() throws {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        let locator = EmbeddedHelperLocator(applicationBundleURL: bundle)

        XCTAssertEqual(
            try locator.privilegedHelperURL(
                serviceIdentifier: "com.example.desktop-updater.helper"
            ).path,
            "/Applications/Example.app/Contents/Library/LaunchServices/"
                + "com.example.desktop-updater.helper"
        )
    }

    func testServiceIdentifierCannotInjectAPath() {
        let locator = EmbeddedHelperLocator(
            applicationBundleURL: URL(fileURLWithPath: "/Applications/Example.app")
        )
        for invalid in [
            "",
            ".",
            "../helper",
            "/tmp/helper",
            "com/example/helper",
            "com.example..helper",
        ] {
            XCTAssertThrowsError(
                try locator.privilegedHelperURL(serviceIdentifier: invalid)
            ) { error in
                XCTAssertEqual(
                    error as? EmbeddedHelperLocatorError,
                    .invalidServiceIdentifier
                )
            }
        }
    }
}
