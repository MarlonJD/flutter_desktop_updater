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
