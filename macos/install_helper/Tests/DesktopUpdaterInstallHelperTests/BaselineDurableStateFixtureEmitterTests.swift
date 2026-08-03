import Foundation
import XCTest

@testable import DesktopUpdaterInstallHelper

final class BaselineDurableStateFixtureEmitterTests: XCTestCase {
    func testEmitPreparedBaselineJournals() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "DESKTOP_UPDATER_DURABLE_FIXTURE_OUTPUT"
        ] else {
            throw XCTSkip("fixture output is requested only by the Task 1 harness")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(directoryJournal()).write(
            to: output.appendingPathComponent(
                "directory-journal-schema1.json"
            ),
            options: .atomic
        )

        let schema2 = verifiedInstallerJournal()
        try NativeStrictJSON.canonicalize(encoder.encode(schema2)).write(
            to: output.appendingPathComponent(
                "verified-installer-journal-schema2.json"
            ),
            options: .atomic
        )
    }

    private func directoryJournal() -> MacTransactionJournal {
        MacTransactionJournal(
            transactionID: "00000000-0000-4000-8000-000000000041",
            ownerProcessIdentifier: 42,
            targetName: "Example.app",
            originalStageName: "Stage.app",
            preparedName: ".Example.app.desktop-updater-00000000-0000-4000-8000-000000000041.prepared",
            backupName: ".Example.app.desktop-updater-00000000-0000-4000-8000-000000000041.backup",
            parentIdentity: identity(inode: 11),
            targetIdentity: identity(inode: 12),
            stageIdentity: identity(inode: 13),
            expectedPayloadIdentity: MacVerifiedPayloadIdentity(
                packageIdentifier: "com.example.app",
                designatedRequirement: "identifier com.example.app",
                bundleSHA256: String(repeating: "a", count: 64),
                provenanceSHA256: String(repeating: "b", count: 64),
                executableSHA256: String(repeating: "c", count: 64)
            ),
            state: .prepared
        )
    }

    private func verifiedInstallerJournal() -> MacVerifiedInstallerJournal {
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
        return MacVerifiedInstallerJournal(
            transactionID: "00000000-0000-4000-8000-000000000051",
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: "macos:42:43",
            policyID: "com.example.desktop-updater.privileged",
            policySHA256: String(repeating: "f", count: 64),
            targetName: "Example.app",
            parentIdentity: identity(inode: 21),
            targetIdentity: identity(inode: 22),
            sourceInstallerStageName: "Example.pkg",
            sourceInstallerStageParentPath: "/private/var/tmp",
            sourceInstallerStageParentIdentity: identity(inode: 23),
            sourceInstallerStageIdentity: identity(inode: 24),
            installerStageName: "Example.pkg",
            installerStageParentPath: "/Library/Application Support/DesktopUpdater/Installers",
            installerStageParentIdentity: identity(inode: 25),
            installerStageIdentity: identity(inode: 26),
            installerPath: "/Library/Application Support/DesktopUpdater/Installers/Example.pkg",
            installerIdentity: identity(inode: 27),
            expectation: expectation,
            state: .prepared
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

final class BaselineDurableStateFixtureReaderTests: XCTestCase {
    func testPreparedJournalsDecodeAndReencodeByteExactly() throws {
        guard let inputPath = ProcessInfo.processInfo.environment[
            "DESKTOP_UPDATER_DURABLE_FIXTURE_INPUT"
        ] else {
            throw XCTSkip("fixture input is requested only by the Task 1 harness")
        }
        let input = URL(fileURLWithPath: inputPath, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let directoryBytes = try Data(
            contentsOf: input.appendingPathComponent(
                "directory-journal-schema1.json"
            )
        )
        let directory = try MacTransactionJournal.decodeStrict(directoryBytes)
        XCTAssertEqual(try encoder.encode(directory), directoryBytes)

        for name in [
            "verified-installer-journal-schema1.json",
            "verified-installer-journal-schema2.json",
        ] {
            let bytes = try Data(
                contentsOf: input.appendingPathComponent(name)
            )
            let journal = try MacVerifiedInstallerJournal.decodeStrict(bytes)
            XCTAssertEqual(
                try NativeStrictJSON.canonicalize(encoder.encode(journal)),
                bytes
            )
        }
    }

    func testPreparedJournalsReadByFreshProcessWithoutMutation() throws {
        guard let inputPath = ProcessInfo.processInfo.environment[
            "DESKTOP_UPDATER_DURABLE_FIXTURE_INPUT"
        ] else {
            throw XCTSkip("fixture input is requested only by the Task 1 harness")
        }
        let input = URL(fileURLWithPath: inputPath, isDirectory: true)
        let names = [
            "directory-journal-schema1.json",
            "verified-installer-journal-schema1.json",
            "verified-installer-journal-schema2.json",
        ]
        let before = try Dictionary(
            uniqueKeysWithValues: names.map { name in
                (name, try Data(contentsOf: input.appendingPathComponent(name)))
            }
        )

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "DesktopUpdaterInstallHelperTests."
                + "BaselineDurableStateFixtureReaderTests/"
                + "testPreparedJournalsDecodeAndReencodeByteExactly",
            Bundle(for: BaselineDurableStateFixtureReaderTests.self)
                .bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DESKTOP_UPDATER_DURABLE_FIXTURE_INPUT"] = input.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let processOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, processOutput)
        for name in names {
            XCTAssertEqual(
                try Data(contentsOf: input.appendingPathComponent(name)),
                before[name],
                "fresh reader mutated \(name)"
            )
        }
    }
}
