import Foundation
import XCTest

@testable import DesktopUpdaterInstallHelper

// Copied into the 73aa730 writer worktree only. It deliberately constructs the
// historical MacVerifiedInstallerJournal type from that checkout rather than a
// compatibility replica in the current source tree.
final class PredecessorSchema1FixtureWriterTests: XCTestCase {
    func testEmitPreparedSchema1JournalFromHistoricalWriter() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "DESKTOP_UPDATER_PREDECESSOR_DURABLE_FIXTURE_OUTPUT"
        ] else {
            throw XCTSkip("fixture output is requested only by the Task 1 harness")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )

        let expectation = MacVerifiedInstallerExpectation(
            installerURL: URL(fileURLWithPath: "/private/var/tmp/Example.pkg"),
            kind: .pkg,
            targetURL: URL(fileURLWithPath: "/Applications/Example.app"),
            packageIdentifier: "com.example.app",
            expectedVersion: "2.0.0",
            expectedBuildNumber: 200,
            designatedRequirement: "identifier com.example.app",
            artifactSHA256: String(repeating: "a", count: 64),
            artifactLength: 4096,
            expectedPackageIdentifiers: ["com.example.app.pkg"],
            expectedReceiptVersions: ["com.example.app.pkg": "2.0.0"],
            expectedExecutableSHA256: String(repeating: "b", count: 64),
            expectedBundleTreeSHA256: String(repeating: "c", count: 64),
            descriptorSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "e", count: 64)
        )
        let journal = MacVerifiedInstallerJournal(
            transactionID: "00000000-0000-4000-8000-000000000051",
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: "macos:42:43",
            policyID: "com.example.desktop-updater.privileged",
            policySHA256: String(repeating: "f", count: 64),
            targetName: "Example.app",
            parentIdentity: identity(inode: 21),
            targetIdentity: identity(inode: 22),
            installerStageName: "Example.pkg",
            installerStageParentPath: "/Library/Application Support/DesktopUpdater/Installers",
            installerStageParentIdentity: identity(inode: 25),
            installerStageIdentity: identity(inode: 26),
            installerPath: "/Library/Application Support/DesktopUpdater/Installers/Example.pkg",
            installerIdentity: identity(inode: 27),
            expectation: expectation,
            state: .prepared
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try NativeStrictJSON.canonicalize(encoder.encode(journal))
        try bytes.write(
            to: output.appendingPathComponent(
                "verified-installer-journal-schema1.json"
            ),
            options: .atomic
        )
    }

    private func identity(inode: UInt64) -> MacFileIdentity {
        MacFileIdentity(
            device: 7,
            inode: inode,
            mode: 0o100644,
            userIdentifier: 501,
            groupIdentifier: 20
        )
    }
}
