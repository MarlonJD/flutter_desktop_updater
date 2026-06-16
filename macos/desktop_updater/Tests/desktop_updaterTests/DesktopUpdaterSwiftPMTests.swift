import XCTest
@testable import desktop_updater

final class DesktopUpdaterSwiftPMTests: XCTestCase {
    func testPluginTypeIsAvailableFromSwiftPackage() {
        XCTAssertNotNil(DesktopUpdaterPlugin.self)
    }
}
