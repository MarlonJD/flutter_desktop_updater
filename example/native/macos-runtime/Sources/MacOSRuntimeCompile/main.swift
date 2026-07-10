import DesktopUpdaterKit
import Foundation

let configuration = try RuntimeConfiguration(
    appArchiveUrl: URL(
        string: "https://updates.example.test/app-archive.json"
    )!,
    expectedPackageId: "com.example.native-contract",
    currentVersion: "2.7.0",
    currentBuildNumber: 270,
    currentUpdaterVersion: "2.7.0",
    platform: "macos",
    installationIdentity: "external-swiftpm-consumer",
    pinnedPublicKeysById: [
        "native-contract-stable": Data(repeating: 1, count: 32)
    ]
)

guard configuration.maximumMetadataBytes == 4 * 1024 * 1024 else {
    fatalError("Unexpected metadata limit")
}

let outcome = RuntimeOutcome.noUpdate
print("DesktopUpdaterKit runtime API compiled: \(outcome.rawValue)")
