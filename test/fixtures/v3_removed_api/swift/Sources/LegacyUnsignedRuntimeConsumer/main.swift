import DesktopUpdaterKit
import Foundation

func legacyConfiguration() throws -> RuntimeConfiguration {
    try RuntimeConfiguration(
        appArchiveUrl: URL(
            string: "https://updates.example.test/app-archive.json"
        )!,
        expectedPackageId: "com.example.app",
        currentVersion: "2.7.0",
        currentBuildNumber: 270,
        currentUpdaterVersion: "2.7.0",
        platform: "macos",
        requireIndexSignature: false,
        requireDescriptorSignature: false,
        pinnedPublicKeysById: [:]
    )
}

func legacyUnsignedStage(
    stager: MacArtifactStager,
    archive: URL,
    stagingRoot: URL,
    descriptor: ReleaseDescriptor
) throws {
    _ = try stager.stageZip(
        archive: archive,
        stagingRoot: stagingRoot,
        descriptor: descriptor,
        expectedPackageId: "com.example.app",
        expectedTeamIdentifier: "",
        allowUnsignedUpdates: true
    )
}

print(try legacyConfiguration().expectedPackageId)
