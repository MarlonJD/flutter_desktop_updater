import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacPrivilegedHelperTests: XCTestCase {
    func testWritableAndProtectedModesUseOneFixedBundledExecutable() throws {
        let locator = EmbeddedHelperLocator(
            applicationBundleURL: URL(
                fileURLWithPath: "/Applications/Example.app"
            )
        )

        XCTAssertEqual(
            locator.oneShotHelperURL.path,
            "/Applications/Example.app/Contents/Helpers/"
                + "DesktopUpdaterInstallHelper"
        )
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
}
