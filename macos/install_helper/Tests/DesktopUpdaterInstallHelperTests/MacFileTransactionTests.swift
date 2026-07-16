import Darwin
import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacFileTransactionTests: XCTestCase {
    func testSuccessfulSwapUsesDerivedNamesAndRemovesDurableState() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }

        let transaction = try fixture.makeTransaction()
        XCTAssertEqual(
            transaction.paths.preparedName,
            ".Example.app.desktop-updater-\(fixture.transactionID).prepared"
        )
        XCTAssertEqual(
            transaction.paths.backupName,
            ".Example.app.desktop-updater-\(fixture.transactionID).backup"
        )
        XCTAssertEqual(
            transaction.paths.lockName,
            ".Example.app.desktop-updater-lock"
        )

        let result = try transaction.execute()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stageURL.path))
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testExternalSameVolumeStageIsPreparedWithoutMutatingItsSource()
        throws
    {
        let fixture = try MacTransactionFixture(externalStage: true)
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()

        _ = try transaction.prepare()

        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.rootURL.appendingPathComponent(
                    transaction.paths.preparedName
                ).path
            )
        )

        XCTAssertEqual(try transaction.execute(), .completed)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.stageURL.path)
        )
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testSecondTransactionCannotReserveTheSameTargetBeforeMutation()
        throws
    {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }

        let first = try fixture.makeTransaction()
        let lockURL = fixture.rootURL.appendingPathComponent(
            first.paths.lockName
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(
                try fixture.makeTransaction(
                    transactionID:
                        "00000000-0000-4000-8000-000000000007"
                )
            ) { error in
                XCTAssertEqual(
                    error as? MacFileTransactionError,
                    .targetBusy
                )
            }
        }
    }

    func testPreparePersistsJournalWithoutMutatingTargetOrStage() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()

        let journalSHA256 = try transaction.prepare()

        XCTAssertEqual(journalSHA256.count, 64)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertEqual(
            try fixture.transactionArtifacts(),
            [
                ".Example.app.desktop-updater-\(fixture.transactionID)"
                    + ".journal.json",
                ".Example.app.desktop-updater-\(fixture.transactionID)"
                    + ".prepared",
                ".Example.app.desktop-updater-lock",
            ]
        )
        XCTAssertThrowsError(try transaction.prepare()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .invalidState
            )
        }
    }

    func testPreparedTransactionCommitsUsingTheDurableReservation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()

        XCTAssertEqual(try transaction.execute(), .completed)

        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testCancelRemovesOnlyPreparedDurableStateWithoutMutation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()

        try transaction.cancelPrepared()

        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertThrowsError(try transaction.execute()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .invalidState
            )
        }
    }

    func testRejectsSymlinkReplacementBeforeMutation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()

        try FileManager.default.removeItem(at: fixture.stageURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.stageURL,
            withDestinationURL: fixture.targetURL
        )

        XCTAssertThrowsError(try transaction.execute()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .stageIdentityChanged
            )
        }
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testRejectsStageContentMutationBeforeMutation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()

        try fixture.writeVersion("attacker", at: fixture.stageURL)

        XCTAssertThrowsError(try transaction.execute()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .stagePayloadChanged
            )
        }
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testRejectsTargetParentReplacementBeforeMutation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        let displaced = fixture.rootURL.appendingPathExtension("displaced")

        try FileManager.default.moveItem(at: fixture.rootURL, to: displaced)
        try FileManager.default.createDirectory(
            at: fixture.rootURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: displaced) }

        XCTAssertThrowsError(try transaction.execute()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .targetParentChanged
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.targetURL.path)
        )
        XCTAssertEqual(
            try fixture.version(
                at: displaced.appendingPathComponent("Example.app")
            ),
            "old"
        )
    }

    func testRejectsTargetOwnershipChangeBeforeMutation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        let currentGroup = try groupIdentifier(at: fixture.targetURL)
        guard let alternateGroup = supplementaryGroup(
            excluding: currentGroup
        ) else {
            throw XCTSkip("No alternate supplementary group is available.")
        }
        XCTAssertEqual(
            fixture.targetURL.path.withCString {
                Darwin.chown($0, uid_t.max, alternateGroup)
            },
            0
        )

        XCTAssertThrowsError(try transaction.execute()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .targetIdentityChanged
            )
        }
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testPrivilegedCopyPreservesTargetOwnershipRecursively() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let stageGroup = try groupIdentifier(at: fixture.stageURL)
        guard let targetGroup = supplementaryGroup(excluding: stageGroup) else {
            throw XCTSkip("No alternate supplementary group is available.")
        }
        XCTAssertEqual(
            fixture.targetURL.path.withCString {
                Darwin.chown($0, uid_t.max, targetGroup)
            },
            0
        )
        let targetOwner = try userIdentifier(at: fixture.targetURL)
        let transaction = try fixture.makeTransaction(
            preserveTargetOwnership: true
        )

        _ = try transaction.prepare()
        XCTAssertEqual(try transaction.execute(), .completed)

        XCTAssertEqual(try userIdentifier(at: fixture.targetURL), targetOwner)
        XCTAssertEqual(try groupIdentifier(at: fixture.targetURL), targetGroup)
        let installedFile = fixture.targetURL.appendingPathComponent(
            "version.txt"
        )
        XCTAssertEqual(try userIdentifier(at: installedFile), targetOwner)
        XCTAssertEqual(try groupIdentifier(at: installedFile), targetGroup)
    }

    func testOwnershipNormalizationRejectsPreparedRootReplacement() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let paths = try MacTransactionPaths(
            targetName: fixture.targetURL.lastPathComponent,
            transactionID: fixture.transactionID
        )
        let prepared = fixture.rootURL.appendingPathComponent(
            paths.preparedName,
            isDirectory: true
        )
        let displaced = fixture.rootURL.appendingPathComponent(
            "displaced-prepared",
            isDirectory: true
        )
        let injector = CallbackMacFaultInjector(
            point: .afterOwnershipRootLocked
        ) {
            try FileManager.default.moveItem(at: prepared, to: displaced)
            try FileManager.default.createDirectory(
                at: prepared,
                withIntermediateDirectories: false
            )
        }
        let transaction = try fixture.makeTransaction(
            preserveTargetOwnership: true,
            faultInjector: injector
        )

        XCTAssertThrowsError(try transaction.prepare()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .stageIdentityChanged
            )
        }
        XCTAssertEqual(try fixture.version(at: displaced), "new")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testOwnershipNormalizationNeverFollowsRacedEntrySymlink() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let paths = try MacTransactionPaths(
            targetName: fixture.targetURL.lastPathComponent,
            transactionID: fixture.transactionID
        )
        let preparedFile = fixture.rootURL.appendingPathComponent(
            paths.preparedName,
            isDirectory: true
        ).appendingPathComponent("version.txt")
        let victim = fixture.rootURL.appendingPathComponent("victim.txt")
        try Data("victim".utf8).write(to: victim)
        XCTAssertEqual(Darwin.chmod(victim.path, 0o640), 0)
        let before = try fileStatus(victim)
        let injector = CallbackMacFaultInjector(
            point: .beforeOwnershipEntryOpen
        ) {
            try FileManager.default.removeItem(at: preparedFile)
            try FileManager.default.createSymbolicLink(
                at: preparedFile,
                withDestinationURL: victim
            )
        }
        let transaction = try fixture.makeTransaction(
            preserveTargetOwnership: true,
            faultInjector: injector
        )

        XCTAssertThrowsError(try transaction.prepare()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .stageIdentityChanged
            )
        }
        XCTAssertEqual(try fileStatus(victim), before)
        XCTAssertEqual(try String(contentsOf: victim), "victim")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testOwnershipNormalizationRejectsSpecialModeBits() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let unsafeName = "Unsafe.app"
        let unsafeRoot = fixture.rootURL.appendingPathComponent(
            unsafeName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsafeRoot,
            withIntermediateDirectories: false
        )
        let unsafeFile = unsafeRoot.appendingPathComponent("payload")
        try Data("unsafe".utf8).write(to: unsafeFile)
        XCTAssertEqual(Darwin.chmod(unsafeFile.path, 0o4755), 0)
        let targetStatus = try fileStatus(fixture.targetURL)
        let directory = try MacTransactionDirectory(url: fixture.rootURL)

        XCTAssertThrowsError(
            try directory.normalizeTreeOwnership(
                name: unsafeName,
                ownership: MacFileOwnership(
                    userIdentifier: targetStatus.userIdentifier,
                    groupIdentifier: targetStatus.groupIdentifier
                )
            )
        )
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testOwnershipNormalizationRejectsUnsafeOrInaccessibleModes()
        throws
    {
        for (relativePath, mode) in [
            ("version.txt", mode_t(0o666)),
            ("", mode_t(0o777)),
            ("version.txt", mode_t(0o600)),
            ("version.txt", mode_t(0o710)),
            ("", mode_t(0o700)),
        ] {
            let fixture = try MacTransactionFixture()
            defer { fixture.remove() }
            let stagedNode = relativePath.isEmpty
                ? fixture.stageURL
                : fixture.stageURL.appendingPathComponent(relativePath)
            XCTAssertEqual(Darwin.chmod(stagedNode.path, mode), 0)
            let transaction = try fixture.makeTransaction(
                preserveTargetOwnership: true
            )

            XCTAssertThrowsError(try transaction.prepare(), relativePath)
            XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        }
    }

    func testOwnershipNormalizationClearsImmutableFlags() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let stagedFile = fixture.stageURL.appendingPathComponent("version.txt")
        XCTAssertEqual(
            Darwin.chflags(stagedFile.path, UInt32(UF_IMMUTABLE)),
            0
        )
        defer { _ = Darwin.chflags(stagedFile.path, 0) }
        let transaction = try fixture.makeTransaction(
            preserveTargetOwnership: true
        )

        XCTAssertEqual(try transaction.execute(), .completed)

        let installedFile = fixture.targetURL.appendingPathComponent(
            "version.txt"
        )
        XCTAssertEqual(try fileFlags(installedFile), 0)
    }

    func testRecoveryRemovesPreparedTreeAfterImmutableFlagNormalization()
        throws
    {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let stagedFile = fixture.stageURL.appendingPathComponent("version.txt")
        XCTAssertEqual(
            Darwin.chflags(stagedFile.path, UInt32(UF_IMMUTABLE)),
            0
        )
        defer { _ = Darwin.chflags(stagedFile.path, 0) }
        let injector = ThrowingMacFaultInjector(point: .afterStageRename)
        let transaction = try fixture.makeTransaction(
            preserveTargetOwnership: true,
            faultInjector: injector
        )

        XCTAssertThrowsError(try transaction.prepare())
        XCTAssertEqual(
            try fixture.makeRecoveryService().recover(),
            .recovered
        )
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testRejectsCrossVolumeStage() {
        XCTAssertThrowsError(
            try MacFileTransaction.validateSameVolume(
                targetDevice: 10,
                stageDevice: 11
            )
        ) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .crossVolumeStage
            )
        }
    }

    func testDiskFullAndDirectorySyncFailureLeaveRecoverableState() throws {
        for point in [
            MacTransactionFaultPoint.beforePreparedJournalFlush,
            .afterBackupRenameBeforeDirectorySync,
        ] {
            let fixture = try MacTransactionFixture()
            let injector = ThrowingMacFaultInjector(point: point)
            let transaction = try fixture.makeTransaction(
                faultInjector: injector
            )

            XCTAssertThrowsError(try transaction.execute())
            let outcome = try fixture.makeRecoveryService().recover()
            XCTAssertTrue(
                outcome == .recovered || outcome == .nothingToRecover,
                "unexpected recovery outcome \(outcome) at \(point)"
            )
            XCTAssertEqual(
                try fixture.version(at: fixture.targetURL),
                point == .beforePreparedJournalFlush ? "old" : "new"
            )
            fixture.remove()
        }
    }

    func testUnprivilegedSmoke() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }

        _ = try fixture.makeTransaction().execute()

        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testBundleVerifierBindsPackageSignatureProvenanceAndExecutable()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Signed.app")
        let executable = bundle.appendingPathComponent(
            "Contents/MacOS/Signed"
        )
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executable
        )
        let provenance = Data("sealed provenance".utf8)
        try provenance.write(
            to: resources.appendingPathComponent(
                "desktop-updater-stage-provenance.json"
            )
        )
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Signed",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        try info.write(
            to: bundle.appendingPathComponent("Contents/Info.plist")
        )
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = [
            "--force",
            "--sign",
            "-",
            "--identifier",
            "com.example.app",
            bundle.path,
        ]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)

        let verifier = MacBundlePayloadVerifier(
            expectation: MacBundlePayloadExpectation(
                packageIdentifier: "com.example.app",
                designatedRequirement: "identifier com.example.app",
                provenanceSHA256: macPayloadSHA256(provenance),
                executableSHA256: macPayloadSHA256(
                    try Data(contentsOf: executable)
                )
            )
        )
        let identity = try verifier.verifyPayload(at: bundle)
        XCTAssertEqual(identity.packageIdentifier, "com.example.app")

        try Data("replaced".utf8).write(to: executable)
        XCTAssertThrowsError(try verifier.verifyPayload(at: bundle)) {
            error in
            XCTAssertEqual(
                error as? MacPayloadVerificationError,
                .executableMismatch
            )
        }
    }
}

private func groupIdentifier(at url: URL) throws -> gid_t {
    var value = stat()
    guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
        throw MacFileTransactionError.filesystemOperationFailed
    }
    return value.st_gid
}

private func userIdentifier(at url: URL) throws -> uid_t {
    var value = stat()
    guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
        throw MacFileTransactionError.filesystemOperationFailed
    }
    return value.st_uid
}

private func fileFlags(_ url: URL) throws -> UInt32 {
    var value = stat()
    guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
        throw MacFileTransactionError.filesystemOperationFailed
    }
    return value.st_flags
}

private func fileStatus(_ url: URL) throws -> MacFileIdentity {
    var value = stat()
    guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
        throw MacFileTransactionError.filesystemOperationFailed
    }
    return MacFileIdentity(
        device: UInt64(value.st_dev),
        inode: UInt64(value.st_ino),
        mode: UInt16(value.st_mode & mode_t(UInt16.max)),
        userIdentifier: value.st_uid,
        groupIdentifier: value.st_gid
    )
}

private final class CallbackMacFaultInjector: MacTransactionFaultInjecting {
    private let point: MacTransactionFaultPoint
    private let callback: () throws -> Void
    private var didRun = false

    init(
        point: MacTransactionFaultPoint,
        callback: @escaping () throws -> Void
    ) {
        self.point = point
        self.callback = callback
    }

    func hit(_ candidate: MacTransactionFaultPoint) throws {
        guard candidate == point, !didRun else { return }
        didRun = true
        try callback()
    }
}

private func supplementaryGroup(excluding current: gid_t) -> gid_t? {
    let count = Darwin.getgroups(0, nil)
    guard count > 0 else { return nil }
    var groups = [gid_t](repeating: 0, count: Int(count))
    guard Darwin.getgroups(count, &groups) == count else { return nil }
    return groups.first { $0 != current }
}
