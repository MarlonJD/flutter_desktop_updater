import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacCrashRecoveryTests: XCTestCase {
    func testPreparedTransactionWithoutCommitAuthorizationRollsBack() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()

        XCTAssertEqual(try fixture.makeRecoveryService().recover(), .recovered)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testDurableCommitAuthorizationAllowsRecoveryToCompleteInstall()
        throws
    {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()
        try transaction.authorizeCommit()

        XCTAssertEqual(try fixture.makeRecoveryService().recover(), .recovered)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testTamperedCommitAuthorizationRollsBackWithoutMutation() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()
        try transaction.authorizeCommit()
        try Data("tampered".utf8).write(
            to: fixture.rootURL.appendingPathComponent(
                transaction.paths.commitAuthorizationName
            )
        )

        XCTAssertEqual(try fixture.makeRecoveryService().recover(), .recovered)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testRecoversBeforeAndAfterEveryJournalFlushAndRename() throws {
        for point in MacTransactionFaultPoint.crashInjectionPoints {
            let fixture = try MacTransactionFixture()
            let transaction = try fixture.makeTransaction(
                faultInjector: ThrowingMacFaultInjector(point: point)
            )

            XCTAssertThrowsError(try transaction.execute(), "fault \(point)")
            let outcome = try fixture.makeRecoveryService().recover()
            XCTAssertTrue(
                outcome == .recovered || outcome == .nothingToRecover,
                "unexpected recovery outcome \(outcome) at \(point)"
            )
            XCTAssertEqual(
                try fixture.version(at: fixture.targetURL),
                [
                    MacTransactionFaultPoint.beforeStageRename,
                    .afterStageRename,
                    .beforePreparedJournalFlush,
                    .afterPreparedJournalFlush,
                ].contains(point) ? "old" : "new",
                "fault \(point)"
            )
            XCTAssertEqual(
                try fixture.transactionArtifacts(),
                [],
                "durable state leaked after recovery at \(point)"
            )
            fixture.remove()
        }
    }

    func testRejectsTornJournal() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let paths = try MacTransactionPaths(
            targetName: fixture.targetURL.lastPathComponent,
            transactionID: fixture.transactionID
        )
        try Data("{\"state\":\"pre".utf8).write(
            to: fixture.rootURL.appendingPathComponent(paths.journalName)
        )

        XCTAssertThrowsError(try fixture.makeRecoveryService().recover()) {
            error in
            XCTAssertEqual(
                error as? MacRecoveryError,
                .invalidJournal
            )
        }
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testRejectsInvalidBackupIdentity() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction(
            faultInjector: ThrowingMacFaultInjector(
                point: .afterBackupRename
            )
        )
        XCTAssertThrowsError(try transaction.execute())

        let backupURL = fixture.rootURL.appendingPathComponent(
            transaction.paths.backupName
        )
        try FileManager.default.removeItem(at: backupURL)
        try FileManager.default.createDirectory(
            at: backupURL,
            withIntermediateDirectories: false
        )
        try fixture.writeVersion("attacker", at: backupURL)

        XCTAssertThrowsError(try fixture.makeRecoveryService().recover()) {
            error in
            XCTAssertEqual(
                error as? MacRecoveryError,
                .backupIdentityMismatch
            )
        }
    }

    func testDoesNotRecoverTransactionOwnedByLiveProcess() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction(
            ownerProcessIdentifier: 42,
            faultInjector: ThrowingMacFaultInjector(
                point: .afterPreparedJournalFlush
            )
        )
        XCTAssertThrowsError(try transaction.execute())

        let recovery = fixture.makeRecoveryService(
            processLivenessChecker: FixedProcessLivenessChecker(isAlive: true)
        )
        XCTAssertEqual(try recovery.recover(), .liveOwner)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
    }

    func testRecoveryIsIdempotent() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction(
            faultInjector: ThrowingMacFaultInjector(
                point: .afterActivationRename
            )
        )
        XCTAssertThrowsError(try transaction.execute())

        let recovery = fixture.makeRecoveryService()
        XCTAssertEqual(try recovery.recover(), .recovered)
        XCTAssertEqual(try recovery.recover(), .nothingToRecover)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
    }

    func testRecoveryRemovesOwnedLockWithoutAJournal() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()

        XCTAssertEqual(
            try fixture.makeRecoveryService().recover(),
            .recovered
        )
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        withExtendedLifetime(transaction) {}
    }

    func testRecoveryDoesNotRemoveAnotherTransactionsLock() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        let otherRecovery = MacRecoveryService(
            targetURL: fixture.targetURL,
            transactionID: "00000000-0000-4000-8000-000000000007",
            expectedPayloadIdentity: fixture.verifier.identity(
                forVersion: "new"
            ),
            verifier: fixture.verifier,
            processLivenessChecker: FixedProcessLivenessChecker(
                isAlive: false
            )
        )

        XCTAssertEqual(try otherRecovery.recover(), .nothingToRecover)
        XCTAssertEqual(
            try fixture.transactionArtifacts(),
            [".Example.app.desktop-updater-lock"]
        )
        withExtendedLifetime(transaction) {}
    }
}
final class MacTransactionFixture {
    let transactionID = "00000000-0000-4000-8000-000000000006"
    let rootURL: URL
    let targetURL: URL
    let stageURL: URL
    private let stageRootURL: URL
    let verifier = FixturePayloadVerifier()

    init(externalStage: Bool = false) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        targetURL = rootURL.appendingPathComponent(
            "Example.app",
            isDirectory: true
        )
        stageRootURL = externalStage
            ? FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            : rootURL
        stageURL = stageRootURL.appendingPathComponent(
            "Stage.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stageRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stageURL,
            withIntermediateDirectories: true
        )
        try writeVersion("old", at: targetURL)
        try writeVersion("new", at: stageURL)
    }

    func makeTransaction(
        transactionID: String? = nil,
        ownerProcessIdentifier: Int32 = 999_999,
        faultInjector: any MacTransactionFaultInjecting =
            NoMacTransactionFaultInjector()
    ) throws -> MacFileTransaction {
        try MacFileTransaction(
            targetURL: targetURL,
            stageURL: stageURL,
            transactionID: transactionID ?? self.transactionID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            expectedPayloadIdentity: verifier.identity(forVersion: "new"),
            verifier: verifier,
            faultInjector: faultInjector
        )
    }

    func makeRecoveryService(
        processLivenessChecker: any ProcessLivenessChecking =
            FixedProcessLivenessChecker(isAlive: false)
    ) -> MacRecoveryService {
        MacRecoveryService(
            targetURL: targetURL,
            transactionID: transactionID,
            expectedPayloadIdentity: verifier.identity(forVersion: "new"),
            verifier: verifier,
            processLivenessChecker: processLivenessChecker
        )
    }

    func writeVersion(_ value: String, at bundleURL: URL) throws {
        try Data(value.utf8).write(
            to: bundleURL.appendingPathComponent("version.txt"),
            options: .atomic
        )
    }

    func version(at bundleURL: URL) throws -> String {
        try String(
            decoding: Data(
                contentsOf: bundleURL.appendingPathComponent("version.txt")
            ),
            as: UTF8.self
        )
    }

    func transactionArtifacts() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            .filter { $0.contains(".desktop-updater") }
            .sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
        if stageRootURL != rootURL {
            try? FileManager.default.removeItem(at: stageRootURL)
        }
    }
}

final class FixturePayloadVerifier: MacInstallPayloadVerifying {
    func verifyPayload(at bundleURL: URL) throws -> MacVerifiedPayloadIdentity {
        let value = try String(
            decoding: Data(
                contentsOf: bundleURL.appendingPathComponent("version.txt")
            ),
            as: UTF8.self
        )
        return identity(forVersion: value)
    }

    func identity(forVersion value: String) -> MacVerifiedPayloadIdentity {
        let scalar = value.utf8.reduce(0) { ($0 + Int($1)) % 16 }
        let digit = String(scalar, radix: 16)
        return MacVerifiedPayloadIdentity(
            packageIdentifier: "com.example.app",
            designatedRequirement: "identifier com.example.app",
            bundleSHA256: String(repeating: digit, count: 64),
            provenanceSHA256: String(repeating: "a", count: 64),
            executableSHA256: String(repeating: "b", count: 64)
        )
    }
}

final class ThrowingMacFaultInjector: MacTransactionFaultInjecting {
    private let point: MacTransactionFaultPoint
    private var didThrow = false

    init(point: MacTransactionFaultPoint) {
        self.point = point
    }

    func hit(_ candidate: MacTransactionFaultPoint) throws {
        if candidate == point, !didThrow {
            didThrow = true
            throw MacFileTransactionError.injectedFailure(candidate)
        }
    }
}

struct FixedProcessLivenessChecker: ProcessLivenessChecking {
    let isAlive: Bool

    func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        isAlive
    }
}
