import Foundation
import XCTest

@testable import DesktopUpdaterInstallHelper

final class BaselineDurableStateFixtureEmitterTests: XCTestCase {
    func testEmitPreparedBaselineAndPredecessorJournals() throws {
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
        let schema1 = LegacyMacVerifiedInstallerJournalV1(schema2)
        try NativeStrictJSON.canonicalize(encoder.encode(schema1)).write(
            to: output.appendingPathComponent(
                "verified-installer-journal-schema1.json"
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
}

// This test-only writer is the exact schema-1 Codable shape from
// 73aa730efbf1384eef9b74d7eb87ee655d81c0b5. It intentionally omits the four
// source-installer-stage fields introduced by schema 2 in 96cc4ecbb009d5be5a50adcbeeedf8fae2dedfa4.
private struct LegacyMacVerifiedInstallerJournalV1: Codable {
    let schemaVersion: Int
    let transactionID: String
    let ownerProcessIdentifier: Int32
    let ownerProcessStartIdentity: String
    let policyID: String
    let policySHA256: String
    let targetName: String
    let parentIdentity: MacFileIdentity
    let targetIdentity: MacFileIdentity
    let installerStageName: String
    let installerStageParentPath: String
    let installerStageParentIdentity: MacFileIdentity
    let installerStageIdentity: MacFileIdentity
    let installerPath: String
    let installerIdentity: MacFileIdentity
    let packageIdentifier: String
    let expectedVersion: String
    let expectedBuildNumber: Int64
    let designatedRequirement: String
    let artifactSHA256: String
    let artifactLength: Int64
    let expectedPackageIdentifiers: [String]
    let expectedReceiptVersions: [String: String]
    let expectedExecutableSHA256: String
    let expectedBundleTreeSHA256: String
    let descriptorSHA256: String
    let provenanceSHA256: String
    let reservationJournalSHA256: String
    let providerTransactionIdentity: String
    let managerProcessIdentifier: Int32
    let managerProcessStartIdentity: String
    let state: MacVerifiedInstallerTransactionState

    init(_ value: MacVerifiedInstallerJournal) {
        schemaVersion = 1
        transactionID = value.transactionID
        ownerProcessIdentifier = value.ownerProcessIdentifier
        ownerProcessStartIdentity = value.ownerProcessStartIdentity
        policyID = value.policyID
        policySHA256 = value.policySHA256
        targetName = value.targetName
        parentIdentity = value.parentIdentity
        targetIdentity = value.targetIdentity
        installerStageName = value.installerStageName
        installerStageParentPath = value.installerStageParentPath
        installerStageParentIdentity = value.installerStageParentIdentity
        installerStageIdentity = value.installerStageIdentity
        installerPath = value.installerPath
        installerIdentity = value.installerIdentity
        packageIdentifier = value.packageIdentifier
        expectedVersion = value.expectedVersion
        expectedBuildNumber = value.expectedBuildNumber
        designatedRequirement = value.designatedRequirement
        artifactSHA256 = value.artifactSHA256
        artifactLength = value.artifactLength
        expectedPackageIdentifiers = value.expectedPackageIdentifiers
        expectedReceiptVersions = value.expectedReceiptVersions
        expectedExecutableSHA256 = value.expectedExecutableSHA256
        expectedBundleTreeSHA256 = value.expectedBundleTreeSHA256
        descriptorSHA256 = value.descriptorSHA256
        provenanceSHA256 = value.provenanceSHA256
        reservationJournalSHA256 = value.reservationJournalSHA256
        providerTransactionIdentity = value.providerTransactionIdentity
        managerProcessIdentifier = value.managerProcessIdentifier
        managerProcessStartIdentity = value.managerProcessStartIdentity
        state = value.state
    }
}
