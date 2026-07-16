import Darwin
import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacVerifiedInstallerTransactionTests: XCTestCase {
    func testPrepareAndCommitAreDurableBeforeInstallerLaunch() throws {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let checker = ProviderRecordingChecker()
        let runner = ProviderRecordingRunner {
            checker.installed = true
        }
        let transaction = try fixture.transaction(
            checker: checker,
            runner: runner
        )

        let preparedDigest = try transaction.prepare()
        XCTAssertEqual(preparedDigest.count, 64)
        XCTAssertEqual(try fixture.journalState(), "prepared")
        XCTAssertEqual(runner.launchCount, 0)

        try transaction.authorizeCommit()
        XCTAssertEqual(try fixture.journalState(), "commitAccepted")
        XCTAssertEqual(runner.launchCount, 0)

        _ = try transaction.execute()
        XCTAssertEqual(runner.launchCount, 1)
        XCTAssertEqual(checker.installedVerificationCount, 1)
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testSpawnBeforeJournalFailureClosesGateAndRollsBackOwnedStage()
        throws
    {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let runner = ProviderRecordingRunner()
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: ProviderRecordingChecker(),
                runner: runner,
                faultInjector: ThrowingProviderFaultInjector(
                    point: .afterManagerWorkerSpawn
                )
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()

        XCTAssertThrowsError(try transaction?.execute())
        XCTAssertEqual(try fixture.journalState(), "commitAccepted")
        XCTAssertEqual(runner.launchCount, 1)
        XCTAssertEqual(runner.worker.releaseCount, 0)
        transaction = nil

        let result = try fixture.recoveryService(
            checker: ProviderRecordingChecker()
        ).recover(transactionID: fixture.transactionID)

        XCTAssertEqual(result.resultCode, "rolledBack")
        XCTAssertEqual(result.verifiedOutcome, "oldTarget")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testPreparingPreparedAndCommitAcceptedFaultsRecoverByRollback()
        throws
    {
        for point in [
            MacVerifiedInstallerFaultPoint.afterPreparingJournalFlush,
            .afterPreparedJournalFlush,
            .afterCommitAcceptedJournalFlush,
        ] {
            let fixture = try ProviderTransactionFixture()
            let checker = ProviderRecordingChecker()
            var transaction: MacVerifiedInstallerTransaction?
            if point == .afterPreparingJournalFlush {
                XCTAssertThrowsError(
                    try fixture.transaction(
                        checker: checker,
                        runner: ProviderRecordingRunner(),
                        faultInjector: ThrowingProviderFaultInjector(
                            point: point
                        )
                    ),
                    point.rawValue
                )
            } else {
                transaction = try fixture.transaction(
                    checker: checker,
                    runner: ProviderRecordingRunner(),
                    faultInjector: ThrowingProviderFaultInjector(
                        point: point
                    )
                )
                if point == .afterPreparedJournalFlush {
                    XCTAssertThrowsError(
                        try transaction?.prepare(),
                        point.rawValue
                    )
                } else {
                    _ = try transaction?.prepare()
                    XCTAssertThrowsError(
                        try transaction?.authorizeCommit(),
                        point.rawValue
                    )
                }
            }
            transaction = nil

            let result = try fixture.recoveryService(
                checker: checker
            ).recover(transactionID: fixture.transactionID)
            XCTAssertEqual(result.resultCode, "rolledBack", point.rawValue)
            XCTAssertEqual(result.verifiedOutcome, "oldTarget", point.rawValue)
            XCTAssertEqual(
                try fixture.transactionArtifacts(),
                [],
                point.rawValue
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.protectedTransactionStageURL.path
                ),
                point.rawValue
            )
            fixture.remove()
        }
    }

    func testVerificationPendingFaultRecoversCompletedWithoutRelaunch()
        throws
    {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let checker = ProviderRecordingChecker()
        let runner = ProviderRecordingRunner { checker.installed = true }
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: checker,
                runner: runner,
                faultInjector: ThrowingProviderFaultInjector(
                    point: .afterVerificationPendingJournalFlush
                )
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()
        XCTAssertThrowsError(try transaction?.execute())
        XCTAssertEqual(try fixture.journalState(), "verificationPending")
        transaction = nil

        let result = try fixture.recoveryService(
            checker: checker
        ).recover(transactionID: fixture.transactionID)

        XCTAssertEqual(result.resultCode, "completed")
        XCTAssertEqual(result.verifiedOutcome, "newTarget")
        XCTAssertEqual(runner.launchCount, 1)
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testEveryCompletedCleanupBoundaryRecoversIdempotently() throws {
        for point in [
            MacVerifiedInstallerFaultPoint.afterOwnedStageRemoval,
            .afterTargetLockRelease,
            .afterCommitAuthorizationRemoval,
            .afterProviderJournalRemoval,
        ] {
            let fixture = try ProviderTransactionFixture()
            let checker = ProviderRecordingChecker()
            var transaction: MacVerifiedInstallerTransaction? = try fixture
                .transaction(
                    checker: checker,
                    runner: ProviderRecordingRunner {
                        checker.installed = true
                    },
                    faultInjector: ThrowingProviderFaultInjector(
                        point: point
                    )
                )
            _ = try transaction?.prepare()
            try transaction?.authorizeCommit()
            XCTAssertThrowsError(
                try transaction?.execute(),
                point.rawValue
            )
            transaction = nil

            let service = fixture.recoveryService(checker: checker)
            let result = try service.recover(
                transactionID: fixture.transactionID
            )
            XCTAssertEqual(result.resultCode, "completed", point.rawValue)
            XCTAssertEqual(
                try fixture.transactionArtifacts(),
                [],
                point.rawValue
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.protectedTransactionStageURL.path
                ),
                point.rawValue
            )
            fixture.remove()
        }
    }

    func testInterruptedManagerLaunchRecoversToManualActionWithoutRelaunch()
        throws
    {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let checker = ProviderRecordingChecker()
        let runner = ProviderRecordingRunner()
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: checker,
                runner: runner,
                faultInjector: ThrowingProviderFaultInjector(
                    point: .afterManagerStartedJournalFlush
                )
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()
        XCTAssertThrowsError(try transaction?.execute())
        XCTAssertEqual(try fixture.journalState(), "managerStarted")
        transaction = nil

        let service = fixture.recoveryService(checker: checker)
        let result = try service.recover(
            transactionID: fixture.transactionID
        )

        XCTAssertEqual(runner.launchCount, 1)
        XCTAssertEqual(runner.worker.releaseCount, 0)
        XCTAssertEqual(result.resultCode, "manualActionRequired")
        XCTAssertEqual(result.verifiedOutcome, "none")
        XCTAssertEqual(
            try service.query(transactionID: fixture.transactionID).state,
            "manualActionRequired"
        )
        XCTAssertEqual(try fixture.transactionArtifacts(), [fixture.journalName])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testInstallerActiveRecoveryWaitsThenResolvesExactManager()
        throws
    {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let manager = Process()
        manager.executableURL = URL(fileURLWithPath: "/bin/sleep")
        manager.arguments = ["30"]
        try manager.run()
        defer {
            if manager.isRunning {
                manager.terminate()
                manager.waitUntilExit()
            }
        }
        let checker = ProviderRecordingChecker()
        let worker = ProviderRecordingWorker(
            processIdentifier: manager.processIdentifier,
            processStartIdentity: try providerProcessStartIdentity(
                manager.processIdentifier
            )
        )
        let runner = ProviderRecordingRunner(worker: worker)
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: checker,
                runner: runner,
                faultInjector: ThrowingProviderFaultInjector(
                    point: .afterManagerStartedJournalFlush
                )
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()
        XCTAssertThrowsError(try transaction?.execute())
        transaction = nil
        checker.installed = true

        let recovery = ProviderRecoveryExecutionResult()
        let recoveryFinished = DispatchSemaphore(value: 0)
        let service = fixture.recoveryService(checker: checker)
        DispatchQueue.global().async {
            do {
                recovery.set(
                    result: try service.recover(
                        transactionID: fixture.transactionID
                    ),
                    error: nil
                )
            } catch {
                recovery.set(result: nil, error: error)
            }
            recoveryFinished.signal()
        }
        XCTAssertEqual(
            recoveryFinished.wait(timeout: .now() + 0.2),
            .timedOut
        )
        XCTAssertEqual(checker.installedVerificationCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
        let liveArtifacts = try fixture.transactionArtifacts()
        XCTAssertTrue(liveArtifacts.contains(fixture.journalName))
        XCTAssertTrue(liveArtifacts.contains { $0.hasSuffix(".commit") })
        XCTAssertTrue(liveArtifacts.contains { $0.hasSuffix("-lock") })

        manager.terminate()
        manager.waitUntilExit()
        XCTAssertEqual(
            recoveryFinished.wait(timeout: .now() + 5),
            .success
        )
        XCTAssertNil(recovery.error)
        XCTAssertEqual(recovery.result?.resultCode, "completed")
        XCTAssertEqual(recovery.result?.verifiedOutcome, "newTarget")
        XCTAssertEqual(checker.installedVerificationCount, 1)
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testInstallerActiveRecoveryTimeoutPreservesOwnedState() throws {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let manager = Process()
        manager.executableURL = URL(fileURLWithPath: "/bin/sleep")
        manager.arguments = ["30"]
        try manager.run()
        defer {
            if manager.isRunning {
                manager.terminate()
                manager.waitUntilExit()
            }
        }
        let checker = ProviderRecordingChecker()
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: checker,
                runner: ProviderRecordingRunner(
                    worker: ProviderRecordingWorker(
                        processIdentifier: manager.processIdentifier,
                        processStartIdentity: try providerProcessStartIdentity(
                            manager.processIdentifier
                        )
                    )
                ),
                faultInjector: ThrowingProviderFaultInjector(
                    point: .afterManagerStartedJournalFlush
                )
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()
        XCTAssertThrowsError(try transaction?.execute())
        transaction = nil

        let result = try fixture.recoveryService(
            checker: checker,
            managerWaitTimeout: 0.05
        ).recover(transactionID: fixture.transactionID)

        XCTAssertEqual(result.resultCode, "recoveryRequired")
        XCTAssertEqual(result.verifiedOutcome, "none")
        XCTAssertEqual(checker.installedVerificationCount, 0)
        let artifacts = try fixture.transactionArtifacts()
        XCTAssertTrue(artifacts.contains(fixture.journalName))
        XCTAssertTrue(artifacts.contains { $0.hasSuffix(".commit") })
        XCTAssertTrue(artifacts.contains { $0.hasSuffix("-lock") })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testMutableSourcePackageIsNeverPassedToPrivilegedInstaller()
        throws
    {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let checker = ProviderRecordingChecker()
        let runner = ProviderRecordingRunner {
            checker.installed = true
        }
        let transaction = try fixture.transaction(
            checker: checker,
            runner: runner
        )
        _ = try transaction.prepare()
        try Data("attacker replacement".utf8).write(
            to: fixture.installerURL
        )
        try transaction.authorizeCommit()

        _ = try transaction.execute()

        XCTAssertNotEqual(runner.url, fixture.installerURL)
        XCTAssertEqual(runner.url, fixture.protectedInstallerURL)
        XCTAssertEqual(
            runner.dataAtSpawn,
            Data("signed pkg".utf8)
        )
    }

    func testGrowingRetainedSourceCannotExpandProtectedCopy() throws {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction(
            checker: ProviderRecordingChecker(),
            runner: ProviderRecordingRunner()
        )
        let handle = try FileHandle(forWritingTo: fixture.installerURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x41, count: 1_048_576))
        try handle.close()

        XCTAssertThrowsError(try transaction.prepare())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testInterruptedCompletedFlushQueriesAndRecoversAsCompleted() throws {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let checker = ProviderRecordingChecker()
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: checker,
                runner: ProviderRecordingRunner {
                    checker.installed = true
                },
                faultInjector: ThrowingProviderFaultInjector(
                    point: .afterCompletedJournalFlush
                )
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()
        XCTAssertThrowsError(try transaction?.execute())
        transaction = nil
        let service = fixture.recoveryService(checker: checker)

        let status = try service.query(transactionID: fixture.transactionID)
        let result = try service.recover(
            transactionID: fixture.transactionID
        )

        XCTAssertEqual(status.state, "completed")
        XCTAssertEqual(status.resultCode, "completed")
        XCTAssertEqual(result.resultCode, "completed")
        XCTAssertEqual(result.verifiedOutcome, "newTarget")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testCommitAcceptedRecoveryRollsBackAndRemovesOwnedStage() throws {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: ProviderRecordingChecker(),
                runner: ProviderRecordingRunner()
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()
        transaction = nil
        let service = fixture.recoveryService(
            checker: ProviderRecordingChecker()
        )

        let status = try service.query(transactionID: fixture.transactionID)

        let result = try service.recover(
            transactionID: fixture.transactionID
        )

        XCTAssertEqual(status.state, "commitAccepted")
        XCTAssertEqual(status.resultCode, "recoveryRequired")
        XCTAssertEqual(result.resultCode, "rolledBack")
        XCTAssertEqual(result.verifiedOutcome, "oldTarget")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testInterruptedRolledBackCleanupResumesWithoutInstallerLaunch()
        throws
    {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let runner = ProviderRecordingRunner()
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: ProviderRecordingChecker(),
                runner: runner,
                faultInjector: ThrowingProviderFaultInjector(
                    point: .afterRolledBackJournalFlush
                )
            )
        _ = try transaction?.prepare()
        try transaction?.authorizeCommit()
        XCTAssertThrowsError(try transaction?.cancelPrepared())
        XCTAssertEqual(try fixture.journalState(), "rolledBack")
        transaction = nil
        let service = fixture.recoveryService(
            checker: ProviderRecordingChecker()
        )

        let status = try service.query(transactionID: fixture.transactionID)

        let result = try service.recover(
            transactionID: fixture.transactionID
        )

        XCTAssertEqual(status.state, "rolledBack")
        XCTAssertEqual(status.resultCode, "rolledBack")
        XCTAssertEqual(result.resultCode, "rolledBack")
        XCTAssertEqual(result.verifiedOutcome, "oldTarget")
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testRealProcessDeathAfterManagerStartRecoversWithoutRelaunch()
        throws
    {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let markerURL = fixture.rootURL.appendingPathComponent(
            "runner-launched"
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "DesktopUpdaterInstallHelperTests."
                + "MacVerifiedInstallerCrashWorkerTests/"
                + "testCrashAfterManagerStartedJournalFlush",
            Bundle(for: MacVerifiedInstallerCrashWorkerTests.self)
                .bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DESKTOP_UPDATER_PROVIDER_TARGET"] =
            fixture.targetURL.path
        environment["DESKTOP_UPDATER_PROVIDER_INSTALLER"] =
            fixture.installerURL.path
        environment["DESKTOP_UPDATER_PROVIDER_TRANSACTION"] =
            fixture.transactionID
        environment["DESKTOP_UPDATER_PROVIDER_RUNNER_MARKER"] = markerURL.path
        environment["DESKTOP_UPDATER_PROVIDER_PROTECTED_STAGE_BASE"] =
            fixture.protectedStageBaseURL.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertNotEqual(process.terminationStatus, 0, text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(try fixture.journalState(), "managerStarted")

        let checker = ProviderRecordingChecker()
        let service = fixture.recoveryService(checker: checker)
        let result = try service.recover(
            transactionID: fixture.transactionID
        )
        XCTAssertEqual(result.resultCode, "manualActionRequired")
        XCTAssertEqual(result.verifiedOutcome, "none")
        XCTAssertEqual(try fixture.transactionArtifacts(), [fixture.journalName])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.protectedTransactionStageURL.path
            )
        )
    }

    func testRecoveryRejectsUnknownNestedProviderJournalAuthority() throws {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        var transaction: MacVerifiedInstallerTransaction? = try fixture
            .transaction(
                checker: ProviderRecordingChecker(),
                runner: ProviderRecordingRunner()
            )
        _ = try transaction?.prepare()
        transaction = nil
        let journalURL = fixture.installRootURL.appendingPathComponent(
            fixture.journalName
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        var parent = try XCTUnwrap(
            object["parentIdentity"] as? [String: Any]
        )
        parent["attackerAuthority"] = true
        object["parentIdentity"] = parent
        try NativeStrictJSON.canonicalize(
            JSONSerialization.data(withJSONObject: object)
        ).write(to: journalURL)
        let service = fixture.recoveryService(
            checker: ProviderRecordingChecker()
        )

        XCTAssertThrowsError(
            try service.query(transactionID: fixture.transactionID)
        ) { error in
            XCTAssertEqual(
                error as? MacPersistentRecoveryError,
                .journalCorrupt
            )
        }
    }

    func testLiveTransactionRejectsPreparedDesiredIdentityTampering() throws {
        let fixture = try ProviderTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction(
            checker: ProviderRecordingChecker(),
            runner: ProviderRecordingRunner()
        )
        _ = try transaction.prepare()
        let journalURL = fixture.installRootURL.appendingPathComponent(
            fixture.journalName
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        object["expectedVersion"] = "1.0.0"
        try NativeStrictJSON.canonicalize(
            JSONSerialization.data(withJSONObject: object)
        ).write(to: journalURL)

        XCTAssertThrowsError(try transaction.authorizeCommit()) { error in
            XCTAssertEqual(
                error as? MacFileTransactionError,
                .invalidState
            )
        }
    }
}

final class MacVerifiedInstallerCrashWorkerTests: XCTestCase {
    func testCrashAfterManagerStartedJournalFlush() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let target = environment["DESKTOP_UPDATER_PROVIDER_TARGET"],
              let installer =
                environment["DESKTOP_UPDATER_PROVIDER_INSTALLER"],
              let transactionID =
                environment["DESKTOP_UPDATER_PROVIDER_TRANSACTION"],
              let marker =
                environment["DESKTOP_UPDATER_PROVIDER_RUNNER_MARKER"],
              let protectedStageBase = environment[
                "DESKTOP_UPDATER_PROVIDER_PROTECTED_STAGE_BASE"
              ] else {
            throw XCTSkip("only executed by the crash-boundary harness")
        }
        let checker = ProviderRecordingChecker()
        let transaction = try MacVerifiedInstallerTransaction(
            transactionID: transactionID,
            ownerProcessIdentifier: Darwin.getpid(),
            ownerProcessStartIdentity: try providerProcessStartIdentity(),
            policyID: "com.example.desktop-updater.test",
            policySHA256: String(repeating: "e", count: 64),
            expectation: MacVerifiedInstallerExpectation(
                installerURL: URL(fileURLWithPath: installer),
                kind: .pkg,
                targetURL: URL(fileURLWithPath: target),
                packageIdentifier: "com.example.app",
                expectedVersion: "2.0.0",
                expectedBuildNumber: 200,
                designatedRequirement: "identifier com.example.app",
                artifactSHA256: providerSHA256(
                    try Data(contentsOf: URL(fileURLWithPath: installer))
                ),
                artifactLength: Int64(
                    try Data(contentsOf: URL(fileURLWithPath: installer)).count
                ),
                expectedPackageIdentifiers: ["com.example.app.pkg"],
                expectedReceiptVersions: [
                    "com.example.app.pkg": "2.0.0",
                ],
                expectedExecutableSHA256: String(repeating: "e", count: 64),
                expectedBundleTreeSHA256: String(repeating: "f", count: 64),
                descriptorSHA256: String(repeating: "d", count: 64),
                provenanceSHA256: String(repeating: "a", count: 64)
            ),
            handoff: MacVerifiedInstallerHandoff(
                verifier: checker,
                runner: ProviderMarkerRunner(markerPath: marker)
            ),
            protectedStageBaseURL: URL(
                fileURLWithPath: protectedStageBase,
                isDirectory: true
            ),
            faultInjector: KillingProviderFaultInjector(
                point: .afterManagerStartedJournalFlush
            )
        )
        _ = try transaction.prepare()
        try transaction.authorizeCommit()
        _ = try transaction.execute()
        XCTFail("configured process crash was not reached")
    }
}

private final class ProviderTransactionFixture {
    let rootURL: URL
    let installRootURL: URL
    let targetURL: URL
    let stageRootURL: URL
    let installerURL: URL
    let protectedStageBaseURL: URL
    let transactionID = "10000000-0000-4000-8000-000000000001"
    let policy: MacSealedInstallPolicyV1

    var journalName: String {
        ".Example.app.desktop-updater-\(transactionID).provider.json"
    }

    var protectedTransactionStageURL: URL {
        protectedStageBaseURL
            .appendingPathComponent(
                MacVerifiedInstallerProtectedStage.policyDirectoryName(
                    policyID: policy.policyID
                ),
                isDirectory: true
            )
            .appendingPathComponent(
                MacVerifiedInstallerProtectedStage.transactionDirectoryName(
                    transactionID: transactionID
                ),
                isDirectory: true
            )
    }

    var protectedInstallerURL: URL {
        protectedTransactionStageURL.appendingPathComponent("installer.pkg")
    }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        installRootURL = rootURL.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        targetURL = installRootURL.appendingPathComponent(
            "Example.app",
            isDirectory: true
        )
        stageRootURL = rootURL.appendingPathComponent(
            "desktop_updater_stage_11111111-1111-4111-8111-111111111111",
            isDirectory: true
        )
        installerURL = stageRootURL.appendingPathComponent("installer.pkg")
        protectedStageBaseURL = rootURL.appendingPathComponent(
            "ProtectedInstallerStages",
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
            at: protectedStageBaseURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("signed pkg".utf8).write(to: installerURL)
        policy = MacSealedInstallPolicyV1(
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
            allowedInstallRoots: [installRootURL.path],
            releaseRootPublicKeys: [
                MacSealedReleaseRootKey(
                    keyID: "stable-2026",
                    algorithm: "ed25519",
                    publicKey: Data(repeating: 1, count: 32)
                ),
            ],
            allowedStrategies: [
                MacSealedInstallStrategy(
                    strategy: "verifiedInstallerHandoff",
                    provider: "macosInstaller"
                ),
            ],
            minimumHelperProtocolVersion: 1,
            canonicalSHA256: String(repeating: "e", count: 64)
        )
    }

    func transaction(
        checker: ProviderRecordingChecker,
        runner: ProviderRecordingRunner,
        faultInjector: any MacVerifiedInstallerFaultInjecting =
            NoMacVerifiedInstallerFaultInjector()
    ) throws -> MacVerifiedInstallerTransaction {
        try MacVerifiedInstallerTransaction(
            transactionID: transactionID,
            ownerProcessIdentifier: 999_999,
            ownerProcessStartIdentity: "macos:1:1",
            policyID: policy.policyID,
            policySHA256: policy.canonicalSHA256,
            expectation: MacVerifiedInstallerExpectation(
                installerURL: installerURL,
                kind: .pkg,
                targetURL: targetURL,
                packageIdentifier: "com.example.app",
                expectedVersion: "2.0.0",
                expectedBuildNumber: 200,
                designatedRequirement: "identifier com.example.app",
                artifactSHA256: providerSHA256(
                    try Data(contentsOf: installerURL)
                ),
                artifactLength: Int64(
                    try Data(contentsOf: installerURL).count
                ),
                expectedPackageIdentifiers: ["com.example.app.pkg"],
                expectedReceiptVersions: [
                    "com.example.app.pkg": "2.0.0",
                ],
                expectedExecutableSHA256: String(repeating: "e", count: 64),
                expectedBundleTreeSHA256: String(repeating: "f", count: 64),
                descriptorSHA256: String(repeating: "d", count: 64),
                provenanceSHA256: String(repeating: "a", count: 64)
            ),
            handoff: MacVerifiedInstallerHandoff(
                verifier: checker,
                runner: runner
            ),
            protectedStageBaseURL: protectedStageBaseURL,
            faultInjector: faultInjector
        )
    }

    func recoveryService(
        checker: ProviderRecordingChecker,
        managerWaitTimeout: TimeInterval = 10
    ) -> MacPersistentRecoveryService {
        MacPersistentRecoveryService(
            policy: policy,
            callerAuthenticator: ProviderRecoveryCallerAuthenticator(),
            verifierFactory: ProviderUnusedPayloadVerifierFactory(),
            installerVerifierFactory:
                ProviderRecoveryCheckerFactory(checker: checker),
            protectedInstallerStageBaseURL: protectedStageBaseURL,
            managerWaitTimeout: managerWaitTimeout,
            managerPollIntervalMicroseconds: 10_000
        )
    }

    func journalState() throws -> String {
        let data = try Data(
            contentsOf: installRootURL.appendingPathComponent(journalName)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(object["state"] as? String)
    }

    func transactionArtifacts() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: installRootURL.path)
            .filter { $0.hasPrefix(".Example.app.desktop-updater") }
            .sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class ProviderRecordingChecker: MacVerifiedInstallerChecking {
    var installed = false
    private(set) var installedVerificationCount = 0

    func verifyInstaller(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> MacVerifiedInstallerSecurityEvidence {
        MacVerifiedInstallerSecurityEvidence(
            receiptVersions: expectation.expectedReceiptVersions,
            executableSHA256: expectation.expectedExecutableSHA256,
            bundleTreeSHA256: expectation.expectedBundleTreeSHA256
        )
    }

    func verifyInstalledPackage(identifier _: String, version _: String) throws {
        installedVerificationCount += 1
        if !installed { throw ProviderTestError.notInstalled }
    }
}

private final class ProviderRecordingRunner: MacFixedInstallerRunning {
    private let onLaunch: () -> Void
    let worker: ProviderRecordingWorker
    private(set) var launchCount = 0
    private(set) var url: URL?
    private(set) var dataAtSpawn: Data?

    init(
        worker: ProviderRecordingWorker? = nil,
        onLaunch: @escaping () -> Void = {}
    ) {
        self.onLaunch = onLaunch
        self.worker = worker ?? ProviderRecordingWorker(onRelease: onLaunch)
    }

    func spawnVerifiedInstaller(
        at url: URL,
        kind _: MacVerifiedInstallerKind
    ) throws -> any MacGatedInstallerWorker {
        launchCount += 1
        self.url = url
        dataAtSpawn = try Data(contentsOf: url)
        return worker
    }
}

private final class ProviderRecordingWorker: MacGatedInstallerWorker {
    let identity: MacInstallerWorkerIdentity
    private let onRelease: () -> Void
    private(set) var releaseCount = 0

    init(
        processIdentifier: Int32 = 999_999,
        processStartIdentity: String = "macos:1:1",
        onRelease: @escaping () -> Void = {}
    ) {
        identity = MacInstallerWorkerIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            providerTransactionIdentity: "provider-transaction-1"
        )
        self.onRelease = onRelease
    }

    func releaseAndWait() throws {
        releaseCount += 1
        onRelease()
    }
}

private enum ProviderTestError: Error {
    case notInstalled
}

private final class ThrowingProviderFaultInjector:
    MacVerifiedInstallerFaultInjecting
{
    let point: MacVerifiedInstallerFaultPoint

    init(point: MacVerifiedInstallerFaultPoint) {
        self.point = point
    }

    func hit(_ candidate: MacVerifiedInstallerFaultPoint) throws {
        if candidate == point { throw ProviderTestError.notInstalled }
    }
}

private final class KillingProviderFaultInjector:
    MacVerifiedInstallerFaultInjecting
{
    let point: MacVerifiedInstallerFaultPoint

    init(point: MacVerifiedInstallerFaultPoint) {
        self.point = point
    }

    func hit(_ candidate: MacVerifiedInstallerFaultPoint) throws {
        guard candidate == point else { return }
        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
        Darwin._exit(137)
    }
}

private final class ProviderMarkerRunner: MacFixedInstallerRunning {
    let markerPath: String

    init(markerPath: String) {
        self.markerPath = markerPath
    }

    func spawnVerifiedInstaller(
        at _: URL,
        kind _: MacVerifiedInstallerKind
    ) throws -> any MacGatedInstallerWorker {
        ProviderRecordingWorker {
            FileManager.default.createFile(
                atPath: self.markerPath,
                contents: Data()
            )
        }
    }
}

private final class ProviderExecutionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func set(_ error: Error?) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private final class ProviderRecoveryExecutionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: MacPersistentRecoveryResultV1?
    private var storedError: Error?

    var result: MacPersistentRecoveryResultV1? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func set(result: MacPersistentRecoveryResultV1?, error: Error?) {
        lock.lock()
        storedResult = result
        storedError = error
        lock.unlock()
    }
}

private final class ProviderRecoveryCallerAuthenticator:
    MacRecoveryCallerAuthenticating
{
    func authenticate(policy _: MacSealedInstallPolicyV1) throws {}
}

private final class ProviderRecoveryCheckerFactory:
    MacVerifiedInstallerCheckingCreating
{
    let checker: ProviderRecordingChecker

    init(checker: ProviderRecordingChecker) {
        self.checker = checker
    }

    func makeVerifier(
        expectation _: MacVerifiedInstallerExpectation
    ) throws -> any MacVerifiedInstallerChecking {
        checker
    }
}

private final class ProviderUnusedPayloadVerifierFactory:
    MacRecoveryPayloadVerifierCreating
{
    func makeVerifier(
        expectedIdentity _: MacVerifiedPayloadIdentity
    ) throws -> any MacInstallPayloadVerifying {
        throw ProviderTestError.notInstalled
    }
}

private func providerSHA256(_ data: Data) -> String {
    macPrivilegeSHA256(data)
}

private func providerProcessStartIdentity(
    _ processIdentifier: Int32 = Darwin.getpid()
) throws -> String {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(
        processIdentifier,
        PROC_PIDTBSDINFO,
        0,
        &info,
        Int32(size)
    ) == size else {
        throw ProviderTestError.notInstalled
    }
    return "macos:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
}
