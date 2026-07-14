import Foundation
import XCTest

final class MacInstallStrategyTests: XCTestCase {
    func testPackagedHelperKeepsStrategiesOutsideDesktopUpdaterKit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let strategyURL = root.appendingPathComponent(
            "macos/install_helper/Sources/DesktopUpdaterInstallHelper/InstallStrategy.swift"
        )
        let handoffURL = root.appendingPathComponent(
            "macos/install_helper/Sources/DesktopUpdaterInstallHelper/VerifiedInstallerHandoff.swift"
        )
        let strategy = try String(contentsOf: strategyURL, encoding: .utf8)
        let handoff = try String(contentsOf: handoffURL, encoding: .utf8)

        XCTAssertTrue(strategy.contains("verifiedInstallerHandoff"))
        XCTAssertTrue(strategy.contains("macosInstaller"))
        XCTAssertTrue(strategy.contains("protocolCapabilities"))
        XCTAssertTrue(handoff.contains("/usr/sbin/installer"))
        XCTAssertTrue(handoff.contains("/usr/bin/open"))
        XCTAssertFalse(handoff.contains("callerArguments"))
    }
}
