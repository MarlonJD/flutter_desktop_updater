import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class RuntimeAPITests: XCTestCase {
    func testConfigurationAcceptsSafeDefaults() throws {
        let configuration = try RuntimeConfiguration(
            appArchiveUrl: URL(
                string: "https://updates.example.test/app-archive.json"
            )!,
            expectedPackageId: "com.example.native-contract",
            currentVersion: "2.7.0",
            currentBuildNumber: 270,
            currentUpdaterVersion: "2.7.0",
            platform: "macos",
            pinnedPublicKeysById: [
                "native-contract-stable": Data(repeating: 1, count: 32)
            ]
        )

        XCTAssertEqual(configuration.maximumMetadataBytes, 4 * 1024 * 1024)
        XCTAssertEqual(configuration.maximumArchiveEntries, 100_000)
        XCTAssertEqual(RuntimeOutcome.allCases.count, 15)
    }

    func testConfigurationRejectsNonPositiveLimits() throws {
        XCTAssertThrowsError(
            try RuntimeConfiguration(
                appArchiveUrl: URL(
                    string: "https://updates.example.test/app-archive.json"
                )!,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.7.0",
                currentBuildNumber: nil,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                pinnedPublicKeysById: [
                    "native-contract-stable": Data(repeating: 1, count: 32)
                ],
                maximumMetadataBytes: 0
            )
        )
    }
}
