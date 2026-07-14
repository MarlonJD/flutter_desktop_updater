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

    func testPrivilegedDaemonReusesTheFixedBundledProgram() throws {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        let locator = EmbeddedHelperLocator(applicationBundleURL: bundle)

        XCTAssertEqual(
            try locator.privilegedHelperURL(
                serviceIdentifier: "com.example.desktop-updater.helper"
            ).path,
            locator.oneShotHelperURL.path
        )
        XCTAssertEqual(
            try locator.launchDaemonPlistURL(
                serviceIdentifier: "com.example.desktop-updater.helper"
            ).path,
            "/Applications/Example.app/Contents/Library/LaunchDaemons/"
                + "com.example.desktop-updater.helper.plist"
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
            XCTAssertThrowsError(
                try locator.launchDaemonPlistURL(serviceIdentifier: invalid)
            )
        }
    }
}
