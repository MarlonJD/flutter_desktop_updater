import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacPrivilegedHelperTests: XCTestCase {
    func testWritableAndProtectedModesUseDistinctFixedNestedLocations() throws {
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
            "/Applications/Example.app/Contents/Library/LaunchServices/"
                + "com.example.desktop-updater.helper"
        )
        XCTAssertNotEqual(
            locator.oneShotHelperURL,
            try locator.privilegedHelperURL(
                serviceIdentifier: "com.example.desktop-updater.helper"
            )
        )
    }
}
