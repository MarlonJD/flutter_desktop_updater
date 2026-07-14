import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacCrashRecoveryTests: XCTestCase {
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
                point == .beforePreparedJournalFlush ? "old" : "new",
                "fault \(point)"
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
}
final class MacTransactionFixture {
    let transactionID = "00000000-0000-4000-8000-000000000006"
    let rootURL: URL
    let targetURL: URL
    let stageURL: URL
    let verifier = FixturePayloadVerifier()

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        targetURL = rootURL.appendingPathComponent(
            "Example.app",
            isDirectory: true
        )
        stageURL = rootURL.appendingPathComponent(
            "Stage.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetURL,
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
        ownerProcessIdentifier: Int32 = 999_999,
        faultInjector: any MacTransactionFaultInjecting =
            NoMacTransactionFaultInjector()
    ) throws -> MacFileTransaction {
        try MacFileTransaction(
            targetURL: targetURL,
            stageURL: stageURL,
            transactionID: transactionID,
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
            .filter { $0.contains(".desktop-updater-\(transactionID)") }
            .sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
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
