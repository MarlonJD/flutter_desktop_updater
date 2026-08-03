import Darwin
import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacPersistentRecoveryTests: XCTestCase {
    func testPreparingTransactionIsDiscoverableAndRecoverable() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        let service = MacPersistentRecoveryService(
            policy: persistentRecoveryPolicy(root: fixture.rootURL.path),
            callerAuthenticator: RecordingRecoveryCallerAuthenticator(),
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: fixture.verifier
            )
        )

        let status = try service.query(transactionID: fixture.transactionID)
        XCTAssertEqual(status.state, "preparing")
        XCTAssertEqual(status.resultCode, "recoveryRequired")

        let result = try service.recover(
            transactionID: fixture.transactionID
        )
        XCTAssertEqual(result.resultCode, "rolledBack")
        XCTAssertEqual(result.verifiedOutcome, "oldTarget")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        withExtendedLifetime(transaction) {}
    }

    func testRealProcessDeathBeforePreparedJournalIsRecoverable() throws {
        for point in [
            MacTransactionFaultPoint.afterPreparingJournalFlush,
            .beforeStageRename,
            .beforePreparedJournalFlush,
        ] {
            let fixture = try MacTransactionFixture()
            defer { fixture.remove() }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest", "-XCTest",
                "DesktopUpdaterInstallHelperTests."
                    + "MacCrashProcessWorkerTests/"
                    + "testCrashAtConfiguredPoint",
                Bundle(for: MacCrashProcessWorkerTests.self).bundleURL.path,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["DESKTOP_UPDATER_CRASH_ROOT"] = fixture.rootURL.path
            environment["DESKTOP_UPDATER_CRASH_STAGE"] = fixture.stageURL.path
            environment["DESKTOP_UPDATER_CRASH_TRANSACTION"] =
                fixture.transactionID
            environment["DESKTOP_UPDATER_CRASH_POINT"] = point.rawValue
            process.environment = environment
            process.standardOutput = output
            process.standardError = output

            try process.run()
            process.waitUntilExit()
            let processOutput = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            XCTAssertNotEqual(
                process.terminationStatus,
                0,
                "worker did not die at \(point): \(processOutput)"
            )

            let service = MacPersistentRecoveryService(
                policy: persistentRecoveryPolicy(
                    root: fixture.rootURL.path
                ),
                callerAuthenticator:
                    RecordingRecoveryCallerAuthenticator(),
                verifierFactory: FixtureRecoveryVerifierFactory(
                    verifier: fixture.verifier
                )
            )
            XCTAssertEqual(
                try service.query(transactionID: fixture.transactionID)
                    .state,
                "preparing",
                "fault \(point)"
            )
            let result = try service.recover(
                transactionID: fixture.transactionID
            )
            XCTAssertEqual(result.resultCode, "rolledBack", "fault \(point)")
            XCTAssertEqual(result.verifiedOutcome, "oldTarget", "fault \(point)")
            XCTAssertEqual(
                try fixture.version(at: fixture.targetURL),
                "old",
                "fault \(point)"
            )
            XCTAssertEqual(
                try fixture.transactionArtifacts(),
                [],
                "fault \(point)"
            )
        }
    }

    func testFreshProcessQueriesFrozenDirectoryFixtureBeforeRecovery()
        throws
    {
        guard let inputPath = ProcessInfo.processInfo.environment[
            "DESKTOP_UPDATER_DURABLE_FIXTURE_INPUT"
        ] else {
            throw XCTSkip("fixture input is requested only by the Task 1 harness")
        }
        let input = URL(fileURLWithPath: inputPath, isDirectory: true)
        let fixtureURL = input.appendingPathComponent(
            "directory-journal-schema1.json"
        )
        let before = try Data(contentsOf: fixtureURL)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "DesktopUpdaterInstallHelperTests."
                + "FrozenDirectoryRecoveryWorkerTests/"
                + "testQueryThenRecoverFromFrozenDirectoryFixture",
            Bundle(for: FrozenDirectoryRecoveryWorkerTests.self)
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
        XCTAssertEqual(
            try Data(contentsOf: fixtureURL),
            before,
            "fresh query/recovery worker mutated the committed fixture"
        )
    }

    func testUncommittedPreparationQueriesThenRollsBack() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()
        let caller = RecordingRecoveryCallerAuthenticator()
        let service = MacPersistentRecoveryService(
            policy: persistentRecoveryPolicy(root: fixture.rootURL.path),
            callerAuthenticator: caller,
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: fixture.verifier
            )
        )

        let status = try service.query(transactionID: fixture.transactionID)
        let result = try service.recover(transactionID: fixture.transactionID)

        XCTAssertEqual(status.state, "prepared")
        XCTAssertEqual(status.resultCode, "recoveryRequired")
        XCTAssertEqual(result.resultCode, "rolledBack")
        XCTAssertEqual(result.verifiedOutcome, "oldTarget")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertEqual(caller.authenticationCount, 2)
    }

    func testCommittedPreparationQueriesThenCompletesRecovery() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()
        try transaction.authorizeCommit()
        let service = MacPersistentRecoveryService(
            policy: persistentRecoveryPolicy(root: fixture.rootURL.path),
            callerAuthenticator: RecordingRecoveryCallerAuthenticator(),
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: fixture.verifier
            )
        )

        let status = try service.query(transactionID: fixture.transactionID)
        let result = try service.recover(transactionID: fixture.transactionID)

        XCTAssertEqual(status.state, "prepared")
        XCTAssertEqual(result.resultCode, "completed")
        XCTAssertEqual(result.verifiedOutcome, "newTarget")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testWireRuntimeAcceptsOnlyCanonicalPolicyBoundQuery() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        _ = try fixture.makeTransaction().prepare()
        let policy = persistentRecoveryPolicy(root: fixture.rootURL.path)
        let service = MacPersistentRecoveryService(
            policy: policy,
            callerAuthenticator: RecordingRecoveryCallerAuthenticator(),
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: fixture.verifier
            )
        )
        let request = try JSONSerialization.data(
            withJSONObject: [
                "operation": "queryTransaction",
                "policyId": policy.policyID,
                "protocolVersion": 1,
                "transactionId": fixture.transactionID,
            ],
            options: [.sortedKeys]
        )
        let channel = PersistentRecoveryChannel(request: request)

        try MacPersistentRecoveryWireRuntime(
            service: service,
            channel: channel
        ).run()

        let response = try XCTUnwrap(channel.response)
        XCTAssertEqual(try NativeStrictJSON.canonicalize(response), response)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "protocolVersion", "transactionId", "state",
                "resultCode", "journalSha256",
            ]
        )
        XCTAssertEqual(object["state"] as? String, "prepared")
    }

    func testRecoverySmokeCrashRequestFailsClosedWithoutFixedRootGate()
        throws
    {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        _ = try fixture.makeTransaction().prepare()
        let policy = persistentRecoveryPolicy(root: fixture.rootURL.path)
        let handler = MacPersistentRecoveryRequestHandler(
            service: MacPersistentRecoveryService(
                policy: policy,
                callerAuthenticator:
                    RecordingRecoveryCallerAuthenticator(),
                verifierFactory: FixtureRecoveryVerifierFactory(
                    verifier: fixture.verifier
                )
            )
        )
        let request = try NativeStrictJSON.canonicalize(
            JSONSerialization.data(withJSONObject: [
                "operation": "terminateForRecoverySmoke",
                "policyId": policy.policyID,
                "protocolVersion": 1,
                "transactionId": fixture.transactionID,
            ])
        )

        XCTAssertThrowsError(try handler.response(for: request))
    }
}

final class MacCrashProcessWorkerTests: XCTestCase {
    func testCrashAtConfiguredPoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["DESKTOP_UPDATER_CRASH_ROOT"],
              let stage = environment["DESKTOP_UPDATER_CRASH_STAGE"],
              let transactionID =
                environment["DESKTOP_UPDATER_CRASH_TRANSACTION"],
              let pointValue =
                environment["DESKTOP_UPDATER_CRASH_POINT"],
              let point = MacTransactionFaultPoint(rawValue: pointValue) else {
            return
        }
        let verifier = FixturePayloadVerifier()
        let transaction = try MacFileTransaction(
            targetURL: URL(fileURLWithPath: root)
                .appendingPathComponent("Example.app"),
            stageURL: URL(fileURLWithPath: stage),
            transactionID: transactionID,
            ownerProcessIdentifier: 999_999,
            expectedPayloadIdentity: verifier.identity(forVersion: "new"),
            verifier: verifier,
            faultInjector: KillingMacFaultInjector(point: point)
        )
        _ = try transaction.prepare()
        XCTFail("configured crash point was not reached")
    }
}

final class FrozenDirectoryRecoveryWorkerTests: XCTestCase {
    func testQueryThenRecoverFromFrozenDirectoryFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment[
            "DESKTOP_UPDATER_DURABLE_FIXTURE_INPUT"
        ] else {
            return
        }
        let input = URL(fileURLWithPath: inputPath, isDirectory: true)
        let frozenBytes = try Data(
            contentsOf: input.appendingPathComponent(
                "directory-journal-schema1.json"
            )
        )
        let frozen = try MacTransactionJournal.decodeStrict(frozenBytes)
        let paths = try MacTransactionPaths(
            targetName: frozen.targetName,
            transactionID: frozen.transactionID
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent(
            frozen.targetName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: target.appendingPathComponent("version.txt"),
            options: .atomic
        )

        let journalURL = root.appendingPathComponent(paths.journalName)
        try frozenBytes.write(to: journalURL, options: .atomic)
        let service = MacPersistentRecoveryService(
            policy: persistentRecoveryPolicy(root: root.path),
            callerAuthenticator: RecordingRecoveryCallerAuthenticator(),
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: FixturePayloadVerifier()
            )
        )

        let status = try service.query(transactionID: frozen.transactionID)
        XCTAssertEqual(status.state, "prepared")
        XCTAssertEqual(status.resultCode, "recoveryRequired")
        XCTAssertEqual(status.journalSHA256, macPrivilegeSHA256(frozenBytes))
        XCTAssertEqual(
            try Data(contentsOf: journalURL),
            frozenBytes,
            "query eagerly re-encoded the frozen predecessor journal"
        )

        let directory = try MacTransactionDirectory(url: root)
        let prepared = root.appendingPathComponent(
            paths.preparedName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: prepared,
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(
            to: prepared.appendingPathComponent("version.txt"),
            options: .atomic
        )
        let targetLock = try MacTargetLock(
            directory: directory,
            name: paths.lockName,
            transactionID: frozen.transactionID
        )
        let verifier = FixturePayloadVerifier()
        let recoveryJournal = MacTransactionJournal(
            transactionID: frozen.transactionID,
            ownerProcessIdentifier: 999_999,
            targetName: frozen.targetName,
            originalStageName: frozen.originalStageName,
            preparedName: frozen.preparedName,
            backupName: frozen.backupName,
            parentIdentity: directory.identity,
            targetIdentity: try directory.identity(
                name: paths.targetName,
                rejectSymbolicLink: true
            ),
            stageIdentity: try directory.identity(
                name: paths.preparedName,
                rejectSymbolicLink: true
            ),
            expectedPayloadIdentity: verifier.identity(forVersion: "new"),
            state: .prepared
        )
        try DurableTransactionJournalStore(
            directory: directory,
            paths: paths
        ).persist(recoveryJournal)

        let result = try MacPersistentRecoveryService(
            policy: persistentRecoveryPolicy(root: root.path),
            callerAuthenticator: RecordingRecoveryCallerAuthenticator(),
            verifierFactory: FixtureRecoveryVerifierFactory(verifier: verifier)
        ).recover(transactionID: frozen.transactionID)
        XCTAssertEqual(result.resultCode, "rolledBack")
        XCTAssertEqual(result.verifiedOutcome, "oldTarget")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        withExtendedLifetime(targetLock) {}
    }
}

private final class KillingMacFaultInjector: MacTransactionFaultInjecting {
    private let point: MacTransactionFaultPoint

    init(point: MacTransactionFaultPoint) {
        self.point = point
    }

    func hit(_ candidate: MacTransactionFaultPoint) throws {
        guard candidate == point else { return }
        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
        Darwin._exit(137)
    }
}

private final class PersistentRecoveryChannel: MacOneShotWireChannel {
    let request: Data
    private(set) var response: Data?

    init(request: Data) {
        self.request = request
    }

    func readFrame() throws -> Data {
        request
    }

    func writeFrame(_ data: Data) throws {
        response = data
    }
}

private final class RecordingRecoveryCallerAuthenticator:
    MacRecoveryCallerAuthenticating
{
    private(set) var authenticationCount = 0

    func authenticate(policy _: MacSealedInstallPolicyV1) throws {
        authenticationCount += 1
    }
}

private final class FixtureRecoveryVerifierFactory:
    MacRecoveryPayloadVerifierCreating
{
    let verifier: any MacInstallPayloadVerifying

    init(verifier: any MacInstallPayloadVerifying) {
        self.verifier = verifier
    }

    func makeVerifier(
        expectedIdentity _: MacVerifiedPayloadIdentity
    ) throws -> any MacInstallPayloadVerifying {
        verifier
    }
}

private func persistentRecoveryPolicy(root: String)
    -> MacSealedInstallPolicyV1
{
    MacSealedInstallPolicyV1(
        policyVersion: 1,
        policyID: "com.example.desktop-updater.test",
        applicationPackageID: "com.example.app",
        helperServiceID: "com.example.desktop-updater.helper",
        allowedApplicationSigner: MacSealedPolicySigner(
            kind: "appleDesignatedRequirement",
            value: "identifier com.example.app"
        ),
        allowedHelperSigner: MacSealedPolicySigner(
            kind: "appleDesignatedRequirement",
            value: "identifier com.example.desktop-updater.helper"
        ),
        allowedTargetClasses: ["applicationBundle"],
        allowedInstallRoots: [root],
        releaseRootPublicKeys: [
            MacSealedReleaseRootKey(
                keyID: "stable-2026",
                algorithm: "ed25519",
                publicKey: Data(repeating: 1, count: 32)
            ),
        ],
        allowedStrategies: [
            MacSealedInstallStrategy(
                strategy: "directoryReplace",
                provider: "platformDirectory"
            ),
        ],
        minimumHelperProtocolVersion: 1,
        canonicalSHA256: String(repeating: "e", count: 64)
    )
}
