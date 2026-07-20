import Darwin
import Foundation
import Security

protocol MacRecoveryCallerAuthenticating: AnyObject {
    func authenticate(policy: MacSealedInstallPolicyV1) throws
}

protocol MacRecoveryPayloadVerifierCreating: AnyObject {
    func makeVerifier(
        expectedIdentity: MacVerifiedPayloadIdentity
    ) throws -> any MacInstallPayloadVerifying
}

struct MacPersistentTransactionStatusV1: Equatable {
    let protocolVersion: Int
    let transactionID: String
    let state: String
    let resultCode: String
    let journalSHA256: String
}

struct MacPersistentRecoveryResultV1: Equatable {
    let protocolVersion: Int
    let transactionID: String
    let resultCode: String
    let verifiedOutcome: String
    let journalSHA256: String
}

enum MacPersistentRecoveryError: Error, Equatable {
    case invalidTransactionID
    case ambiguousTransaction
    case journalCorrupt
    case callerAuthenticationFailed
    case recoverySmokeGateInactive
}

final class MacPersistentRecoveryService {
    private struct LocatedTransaction {
        let targetURL: URL
        let journal: MacTransactionJournal
        let journalSHA256: String
    }

    private struct LocatedInstallerTransaction {
        let targetURL: URL
        let directory: MacTransactionDirectory
        let paths: MacTransactionPaths
        let journal: MacVerifiedInstallerJournal
        let store: DurableMacVerifiedInstallerJournalStore
        let installerStageParentDirectory: MacTransactionDirectory
        let sourceInstallerStageParentDirectory: MacTransactionDirectory?
        let journalSHA256: String
    }

    private let policy: MacSealedInstallPolicyV1
    private let callerAuthenticator: any MacRecoveryCallerAuthenticating
    private let verifierFactory: any MacRecoveryPayloadVerifierCreating
    private let installerVerifierFactory:
        (any MacVerifiedInstallerCheckingCreating)?
    private let protectedInstallerStageBaseURL: URL
    private let managerWaitTimeoutNanoseconds: UInt64
    private let managerPollIntervalMicroseconds: UInt32

    var policyID: String { policy.policyID }

    init(
        policy: MacSealedInstallPolicyV1,
        callerAuthenticator: any MacRecoveryCallerAuthenticating,
        verifierFactory: any MacRecoveryPayloadVerifierCreating,
        installerVerifierFactory:
            (any MacVerifiedInstallerCheckingCreating)? = nil,
        protectedInstallerStageBaseURL: URL =
            MacVerifiedInstallerProtectedStage.defaultBaseURL,
        managerWaitTimeout: TimeInterval = 10,
        managerPollIntervalMicroseconds: UInt32 = 100_000
    ) {
        self.policy = policy
        self.callerAuthenticator = callerAuthenticator
        self.verifierFactory = verifierFactory
        self.installerVerifierFactory = installerVerifierFactory
        self.protectedInstallerStageBaseURL =
            protectedInstallerStageBaseURL.standardizedFileURL
        let boundedTimeout = min(max(managerWaitTimeout, 0), 3_600)
        managerWaitTimeoutNanoseconds = UInt64(
            boundedTimeout * 1_000_000_000
        )
        self.managerPollIntervalMicroseconds = max(
            managerPollIntervalMicroseconds,
            1
        )
    }

    func query(transactionID: String) throws
        -> MacPersistentTransactionStatusV1
    {
        try authenticateAndValidate(transactionID)
        let file = try locate(transactionID: transactionID)
        let installer = try locateInstaller(transactionID: transactionID)
        guard file == nil || installer == nil else {
            throw MacPersistentRecoveryError.ambiguousTransaction
        }
        if let installer {
            return MacPersistentTransactionStatusV1(
                protocolVersion: 1,
                transactionID: transactionID,
                state: installer.journal.state == .preparing
                    ? "prepared" : installer.journal.state.rawValue,
                resultCode: {
                    switch installer.journal.state {
                    case .completed:
                        return "completed"
                    case .rolledBack:
                        return "rolledBack"
                    case .manualActionRequired:
                        return "manualActionRequired"
                    default:
                        return "recoveryRequired"
                    }
                }(),
                journalSHA256: installer.journalSHA256
            )
        }
        guard let located = file else {
            return MacPersistentTransactionStatusV1(
                protocolVersion: 1,
                transactionID: transactionID,
                state: "completed",
                resultCode: "completed",
                journalSHA256: String(repeating: "0", count: 64)
            )
        }
        return MacPersistentTransactionStatusV1(
            protocolVersion: 1,
            transactionID: transactionID,
            state: located.journal.state.rawValue,
            resultCode: located.journal.state == .completed
                ? "completed" : "recoveryRequired",
            journalSHA256: located.journalSHA256
        )
    }

    func authorizeRecoverySmokeCrash(transactionID: String) throws
        -> MacPersistentTransactionStatusV1
    {
        try authenticateAndValidate(transactionID)
        guard persistentRecoverySmokeGateIsActive() else {
            throw MacPersistentRecoveryError.recoverySmokeGateInactive
        }
        let file = try locate(transactionID: transactionID)
        let installer = try locateInstaller(transactionID: transactionID)
        guard file == nil,
              let installer,
              installer.journal.state == .managerStarted,
              try validInstallerCommit(installer),
              persistentOwnerIsLive(
                  processIdentifier:
                      installer.journal.managerProcessIdentifier,
                  startIdentity:
                      installer.journal.managerProcessStartIdentity
              ) else {
            throw MacPersistentRecoveryError.journalCorrupt
        }
        return MacPersistentTransactionStatusV1(
            protocolVersion: 1,
            transactionID: transactionID,
            state: installer.journal.state.rawValue,
            resultCode: "recoveryRequired",
            journalSHA256: installer.journalSHA256
        )
    }

    func recover(transactionID: String) throws
        -> MacPersistentRecoveryResultV1
    {
        try authenticateAndValidate(transactionID)
        let file = try locate(transactionID: transactionID)
        let installer = try locateInstaller(transactionID: transactionID)
        guard file == nil || installer == nil else {
            throw MacPersistentRecoveryError.ambiguousTransaction
        }
        if let installer {
            return try recoverInstaller(installer)
        }
        guard let located = file else {
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: "completed",
                verifiedOutcome: "none",
                journalSHA256: String(repeating: "0", count: 64)
            )
        }
        let verifier = try verifierFactory.makeVerifier(
            expectedIdentity: located.journal.expectedPayloadIdentity
        )
        let outcome = try MacRecoveryService(
            targetURL: located.targetURL,
            transactionID: transactionID,
            expectedPayloadIdentity:
                located.journal.expectedPayloadIdentity,
            verifier: verifier
        ).recover()
        switch outcome {
        case .liveOwner:
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: "recoveryRequired",
                verifiedOutcome: "none",
                journalSHA256: located.journalSHA256
            )
        case .nothingToRecover:
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: "completed",
                verifiedOutcome: "none",
                journalSHA256: located.journalSHA256
            )
        case .recovered:
            let installed = (try? verifier.verifyPayload(
                at: located.targetURL
            )) == located.journal.expectedPayloadIdentity
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: installed ? "completed" : "rolledBack",
                verifiedOutcome: installed ? "newTarget" : "oldTarget",
                journalSHA256: located.journalSHA256
            )
        }
    }

    private func authenticateAndValidate(_ transactionID: String) throws {
        guard transactionID == transactionID.lowercased(),
              let uuid = UUID(uuidString: transactionID),
              uuid.uuidString.lowercased() == transactionID else {
            throw MacPersistentRecoveryError.invalidTransactionID
        }
        do {
            try callerAuthenticator.authenticate(policy: policy)
        } catch {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
    }

    private func locate(transactionID: String) throws
        -> LocatedTransaction?
    {
        let suffix = ".desktop-updater-\(transactionID).journal.json"
        var matches: [LocatedTransaction] = []
        for root in policy.allowedInstallRoots {
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: rootURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                continue
            }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(
                    atPath: rootURL.path
                )
            } catch {
                throw MacPersistentRecoveryError.journalCorrupt
            }
            for name in names where name.hasPrefix(".")
                && name.hasSuffix(suffix) {
                let end = name.index(name.endIndex, offsetBy: -suffix.count)
                let targetName = String(name[name.index(after: name.startIndex)..<end])
                guard persistentSimpleName(targetName) else {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
                let paths: MacTransactionPaths
                let directory: MacTransactionDirectory
                do {
                    paths = try MacTransactionPaths(
                        targetName: targetName,
                        transactionID: transactionID
                    )
                    directory = try MacTransactionDirectory(url: rootURL)
                } catch {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
                let store = DurableTransactionJournalStore(
                    directory: directory,
                    paths: paths
                )
                do {
                    guard let journal = try store.load(),
                          journal.transactionID == transactionID,
                          journal.targetName == targetName else {
                        throw MacPersistentRecoveryError.journalCorrupt
                    }
                    matches.append(
                        LocatedTransaction(
                            targetURL: rootURL.appendingPathComponent(
                                targetName
                            ),
                            journal: journal,
                            journalSHA256: try store.sha256()
                        )
                    )
                } catch let error as MacPersistentRecoveryError {
                    throw error
                } catch {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
            }
        }
        guard matches.count <= 1 else {
            throw MacPersistentRecoveryError.ambiguousTransaction
        }
        return matches.first
    }

    private func locateInstaller(transactionID: String) throws
        -> LocatedInstallerTransaction?
    {
        let suffix = ".desktop-updater-\(transactionID).provider.json"
        var matches: [LocatedInstallerTransaction] = []
        for root in policy.allowedInstallRoots {
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: rootURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                continue
            }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(
                    atPath: rootURL.path
                )
            } catch {
                throw MacPersistentRecoveryError.journalCorrupt
            }
            for name in names where name.hasPrefix(".")
                && name.hasSuffix(suffix) {
                let end = name.index(name.endIndex, offsetBy: -suffix.count)
                let targetName = String(
                    name[name.index(after: name.startIndex) ..< end]
                )
                guard persistentSimpleName(targetName) else {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
                do {
                    let paths = try MacTransactionPaths(
                        targetName: targetName,
                        transactionID: transactionID
                    )
                    guard name == paths.providerJournalName else {
                        throw MacPersistentRecoveryError.journalCorrupt
                    }
                    let directory = try MacTransactionDirectory(url: rootURL)
                    let store = DurableMacVerifiedInstallerJournalStore(
                        directory: directory,
                        paths: paths
                    )
                    guard let journal = try store.load() else {
                        throw MacPersistentRecoveryError.journalCorrupt
                    }
                    let stageParentURL = URL(
                        fileURLWithPath: journal.installerStageParentPath
                    ).standardizedFileURL
                    let stageRootURL = stageParentURL.appendingPathComponent(
                        journal.installerStageName,
                        isDirectory: true
                    )
                    let installerURL = stageRootURL.appendingPathComponent(
                        "installer.pkg"
                    )
                    let installerStageParentDirectory =
                        try MacTransactionDirectory(url: stageParentURL)
                    var sourceInstallerStageParentDirectory:
                        MacTransactionDirectory?
                    if journal.schemaVersion
                        == MacVerifiedInstallerJournal.schemaVersion {
                        guard let sourceName =
                                journal.sourceInstallerStageName,
                              let sourceParentPath =
                                journal.sourceInstallerStageParentPath,
                              let sourceParentIdentity =
                                journal.sourceInstallerStageParentIdentity,
                              let sourceStageIdentity =
                                journal.sourceInstallerStageIdentity,
                              validPersistentSourceStageName(sourceName),
                              sourceStageIdentity.mode & UInt16(S_IFMT)
                                == UInt16(S_IFDIR) else {
                            throw MacPersistentRecoveryError.journalCorrupt
                        }
                        let sourceParentURL = URL(
                            fileURLWithPath: sourceParentPath
                        ).standardizedFileURL
                        let sourceParentDirectory =
                            try MacTransactionDirectory(
                                url: sourceParentURL
                            )
                        guard sourceParentURL.path == sourceParentPath,
                              sourceParentDirectory.identity
                                == sourceParentIdentity else {
                            throw MacPersistentRecoveryError.journalCorrupt
                        }
                        sourceInstallerStageParentDirectory =
                            sourceParentDirectory
                    }
                    let protectedStage = try MacVerifiedInstallerProtectedStage
                        .plan(
                            baseURL: protectedInstallerStageBaseURL,
                            policyID: policy.policyID,
                            transactionID: transactionID,
                            createPolicyDirectory: false
                        )
                    guard
                          journal.transactionID == transactionID,
                          journal.targetName == targetName,
                          journal.parentIdentity == directory.identity,
                          journal.policyID == policy.policyID,
                          journal.policySHA256 == policy.canonicalSHA256,
                          journal.packageIdentifier
                            == policy.applicationPackageID,
                          journal.designatedRequirement
                            == policy.allowedApplicationSigner.value,
                          journal.ownerProcessIdentifier > 0,
                          journal.ownerProcessStartIdentity.range(
                              of: #"^macos:[0-9]+:[0-9]+$"#,
                              options: .regularExpression
                          ) != nil,
                          validPersistentInstallerJournalState(
                              journal
                          ),
                          !journal.expectedVersion.isEmpty,
                          validPersistentSHA256(journal.artifactSHA256),
                          journal.artifactLength > 0,
                          validPersistentSHA256(journal.descriptorSHA256),
                          validPersistentSHA256(journal.provenanceSHA256),
                          journal.expectedBuildNumber >= 0,
                          !journal.expectedPackageIdentifiers.isEmpty,
                          Set(journal.expectedPackageIdentifiers).count
                            == journal.expectedPackageIdentifiers.count,
                          journal.expectedPackageIdentifiers.allSatisfy(
                              persistentPackageIdentifier
                          ),
                          Set(journal.expectedReceiptVersions.keys)
                            == Set(journal.expectedPackageIdentifiers),
                          journal.expectedReceiptVersions.values
                            .allSatisfy({ !$0.isEmpty }),
                          validPersistentSHA256(
                            journal.expectedExecutableSHA256
                          ),
                          validPersistentSHA256(
                            journal.expectedBundleTreeSHA256
                          ),
                          validPersistentInstallerStageName(
                              journal.installerStageName
                          ),
                          journal.installerStageName
                            == protectedStage.stageName,
                          stageParentURL.path
                            == journal.installerStageParentPath,
                          stageParentURL.path
                            == protectedStage.parentDirectory.url.path,
                          installerStageParentDirectory.identity
                            == journal.installerStageParentIdentity,
                          installerStageParentDirectory.identity
                            == protectedStage.parentDirectory.identity,
                          journal.installerPath == installerURL.path else {
                        throw MacPersistentRecoveryError.journalCorrupt
                    }
                    matches.append(
                        LocatedInstallerTransaction(
                            targetURL: rootURL.appendingPathComponent(
                                targetName
                            ),
                            directory: directory,
                            paths: paths,
                            journal: journal,
                            store: store,
                            installerStageParentDirectory:
                                installerStageParentDirectory,
                            sourceInstallerStageParentDirectory:
                                sourceInstallerStageParentDirectory,
                            journalSHA256: try store.sha256()
                        )
                    )
                } catch let error as MacPersistentRecoveryError {
                    throw error
                } catch {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
            }
        }
        guard matches.count <= 1 else {
            throw MacPersistentRecoveryError.ambiguousTransaction
        }
        return matches.first
    }

    private func recoverInstaller(
        _ located: LocatedInstallerTransaction
    ) throws -> MacPersistentRecoveryResultV1 {
        if persistentOwnerIsLive(
            processIdentifier: located.journal.ownerProcessIdentifier,
            startIdentity: located.journal.ownerProcessStartIdentity
        ) {
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: located.journal.transactionID,
                resultCode: "recoveryRequired",
                verifiedOutcome: "none",
                journalSHA256: located.journalSHA256
            )
        }
        switch located.journal.state {
        case .preparing, .prepared, .commitAccepted:
            let targetIsUnchanged = (try? located.directory.identity(
                name: located.paths.targetName,
                rejectSymbolicLink: true
            )) == located.journal.targetIdentity
            guard targetIsUnchanged else {
                return try markInstallerManualAction(located)
            }
            if located.journal.state == .commitAccepted {
                guard try validInstallerCommit(located) else {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
            }
            var journal = located.journal
            journal.state = .rolledBack
            try located.store.persist(journal)
            try cleanupInstallerTransaction(located, removeJournal: true)
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: located.journal.transactionID,
                resultCode: "rolledBack",
                verifiedOutcome: "oldTarget",
                journalSHA256: located.journalSHA256
            )
        case .rolledBack:
            let targetIsUnchanged = (try? located.directory.identity(
                name: located.paths.targetName,
                rejectSymbolicLink: true
            )) == located.journal.targetIdentity
            guard targetIsUnchanged else {
                return try markInstallerManualAction(located)
            }
            try cleanupInstallerTransaction(located, removeJournal: true)
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: located.journal.transactionID,
                resultCode: "rolledBack",
                verifiedOutcome: "oldTarget",
                journalSHA256: located.journalSHA256
            )
        case .managerStarted, .verificationPending, .completed,
             .manualActionRequired:
            if [.managerStarted, .verificationPending]
                .contains(located.journal.state) {
                guard try validInstallerCommit(located) else {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
                if persistentOwnerIsLive(
                    processIdentifier:
                        located.journal.managerProcessIdentifier,
                    startIdentity:
                        located.journal.managerProcessStartIdentity
                ) {
                    guard waitForPersistentOwnerExit(
                        processIdentifier:
                            located.journal.managerProcessIdentifier,
                        startIdentity:
                            located.journal.managerProcessStartIdentity,
                        timeoutNanoseconds: managerWaitTimeoutNanoseconds,
                        pollIntervalMicroseconds:
                            managerPollIntervalMicroseconds
                    ) else {
                        return MacPersistentRecoveryResultV1(
                            protocolVersion: 1,
                            transactionID: located.journal.transactionID,
                            resultCode: "recoveryRequired",
                            verifiedOutcome: "none",
                            journalSHA256: located.journalSHA256
                        )
                    }
                }
            }
            guard let installerVerifierFactory else {
                return try markInstallerManualAction(located)
            }
            let expectation = installerExpectation(located)
            let checker: any MacVerifiedInstallerChecking
            do {
                checker = try installerVerifierFactory.makeVerifier(
                    expectation: expectation
                )
            } catch {
                return try markInstallerManualAction(located)
            }
            let result = MacVerifiedInstallerHandoff(
                verifier: checker,
                runner: MacRecoveryOnlyInstallerRunner()
            ).recover(
                expectation,
                transactionIdentity:
                    located.journal.providerTransactionIdentity
            )
            if result.state == .completed {
                try cleanupInstallerTransaction(
                    located,
                    removeJournal: true
                )
                return MacPersistentRecoveryResultV1(
                    protocolVersion: 1,
                    transactionID: located.journal.transactionID,
                    resultCode: "completed",
                    verifiedOutcome: "newTarget",
                    journalSHA256: located.journalSHA256
                )
            }
            return try markInstallerManualAction(located)
        }
    }

    private func installerExpectation(
        _ located: LocatedInstallerTransaction
    ) -> MacVerifiedInstallerExpectation {
        MacVerifiedInstallerExpectation(
            installerURL: URL(
                fileURLWithPath: located.journal.installerPath
            ),
            kind: .pkg,
            targetURL: located.targetURL,
            packageIdentifier: located.journal.packageIdentifier,
            expectedVersion: located.journal.expectedVersion,
            expectedBuildNumber: located.journal.expectedBuildNumber,
            designatedRequirement:
                located.journal.designatedRequirement,
            artifactSHA256: located.journal.artifactSHA256,
            artifactLength: located.journal.artifactLength,
            expectedPackageIdentifiers:
                located.journal.expectedPackageIdentifiers,
            expectedReceiptVersions:
                located.journal.expectedReceiptVersions,
            expectedExecutableSHA256:
                located.journal.expectedExecutableSHA256,
            expectedBundleTreeSHA256:
                located.journal.expectedBundleTreeSHA256,
            descriptorSHA256: located.journal.descriptorSHA256,
            provenanceSHA256: located.journal.provenanceSHA256
        )
    }

    private func validInstallerCommit(
        _ located: LocatedInstallerTransaction
    ) throws -> Bool {
        guard validPersistentSHA256(
            located.journal.reservationJournalSHA256
        ) else {
            return false
        }
        return try MacCommitAuthorizationStore(
            directory: located.directory,
            paths: located.paths
        ).validates(
            journalSHA256: located.journal.reservationJournalSHA256
        )
    }

    private func markInstallerManualAction(
        _ located: LocatedInstallerTransaction
    ) throws -> MacPersistentRecoveryResultV1 {
        var journal = located.journal
        journal.state = .manualActionRequired
        try located.store.persist(journal)
        try cleanupInstallerTransaction(located, removeJournal: false)
        return MacPersistentRecoveryResultV1(
            protocolVersion: 1,
            transactionID: journal.transactionID,
            resultCode: "manualActionRequired",
            verifiedOutcome: "none",
            journalSHA256: try located.store.sha256()
        )
    }

    private func cleanupInstallerTransaction(
        _ located: LocatedInstallerTransaction,
        removeJournal: Bool
    ) throws {
        if removeJournal {
            try removeInstallerStageIfPresent(located)
            try removeSourceInstallerStageIfPresent(located)
        }
        if let owner = try MacTargetLock.owner(
            directory: located.directory,
            name: located.paths.lockName
        ) {
            guard owner == located.journal.transactionID else {
                throw MacPersistentRecoveryError.journalCorrupt
            }
            try MacTargetLock.releaseExisting(
                directory: located.directory,
                name: located.paths.lockName,
                transactionID: located.journal.transactionID
            )
        }
        try MacCommitAuthorizationStore(
            directory: located.directory,
            paths: located.paths
        ).removeIfPresent()
        if removeJournal { try located.store.remove() }
    }

    private func removeInstallerStageIfPresent(
        _ located: LocatedInstallerTransaction
    ) throws {
        let protectedStage = try MacVerifiedInstallerProtectedStage.plan(
            baseURL: protectedInstallerStageBaseURL,
            policyID: policy.policyID,
            transactionID: located.journal.transactionID,
            createPolicyDirectory: false
        )
        do {
            try protectedStage.removeIfPresent(
                expectedIdentity:
                    located.journal.installerStageIdentity
                        == emptyPersistentProviderFileIdentity
                        ? nil : located.journal.installerStageIdentity
            )
        } catch {
            throw MacPersistentRecoveryError.journalCorrupt
        }
    }

    private func removeSourceInstallerStageIfPresent(
        _ located: LocatedInstallerTransaction
    ) throws {
        guard located.journal.schemaVersion
                == MacVerifiedInstallerJournal.schemaVersion,
              let sourceName = located.journal.sourceInstallerStageName,
              let sourceIdentity =
                located.journal.sourceInstallerStageIdentity,
              let sourceParent =
                located.sourceInstallerStageParentDirectory else {
            return
        }
        guard sourceParent.exists(name: sourceName) else { return }
        do {
            try sourceParent.removeTree(
                name: sourceName,
                expectedIdentity: sourceIdentity
            )
        } catch {
            throw MacPersistentRecoveryError.journalCorrupt
        }
    }
}

enum MacPersistentRecoveryWireError: Error, Equatable {
    case invalidRequest
}

protocol MacPrivilegedRecoveryRequestHandling: AnyObject {
    func response(for request: Data) throws -> Data
}

final class MacPersistentRecoveryRequestHandler:
    MacPrivilegedRecoveryRequestHandling
{
    private let service: MacPersistentRecoveryService

    init(service: MacPersistentRecoveryService) {
        self.service = service
    }

    func response(for data: Data) throws -> Data {
        guard try NativeStrictJSON.canonicalize(data) == data,
              let request = try NativeStrictJSON.decode(data)
                as? [String: Any],
              Set(request.keys) == [
                  "operation", "policyId", "protocolVersion",
                  "transactionId",
              ],
              persistentInteger(request["protocolVersion"]) == 1,
              request["policyId"] as? String == service.policyID,
              let operation = request["operation"] as? String,
              [
                  "queryTransaction", "recoverPendingInstall",
                  "terminateForRecoverySmoke",
              ]
                .contains(operation),
              let transactionID = request["transactionId"] as? String else {
            throw MacPersistentRecoveryWireError.invalidRequest
        }
        if operation != "recoverPendingInstall" {
            let status = operation == "queryTransaction"
                ? try service.query(transactionID: transactionID)
                : try service.authorizeRecoverySmokeCrash(
                    transactionID: transactionID
                )
            return try persistentCanonicalData([
                "protocolVersion": status.protocolVersion,
                "transactionId": status.transactionID,
                "state": status.state,
                "resultCode": status.resultCode,
                "journalSha256": status.journalSHA256,
            ])
        }
        let result = try service.recover(transactionID: transactionID)
        return try persistentCanonicalData([
            "protocolVersion": result.protocolVersion,
            "transactionId": result.transactionID,
            "resultCode": result.resultCode,
            "verifiedOutcome": result.verifiedOutcome,
            "journalSha256": result.journalSHA256,
        ])
    }
}

final class MacPersistentRecoveryWireRuntime: MacOneShotServiceRunning {
    private let requestHandler: MacPersistentRecoveryRequestHandler
    private let channel: any MacOneShotWireChannel

    init(
        service: MacPersistentRecoveryService,
        channel: any MacOneShotWireChannel
    ) {
        requestHandler = MacPersistentRecoveryRequestHandler(
            service: service
        )
        self.channel = channel
    }

    func run() throws {
        let data = try channel.readFrame()
        try channel.writeFrame(try requestHandler.response(for: data))
    }
}

private func persistentCanonicalData(_ value: Any) throws -> Data {
    try NativeStrictJSON.canonicalize(
        JSONSerialization.data(withJSONObject: value)
    )
}

private func persistentInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)) else {
        return nil
    }
    let result = number.int64Value
    return NSNumber(value: result) == number ? result : nil
}

final class SystemMacRecoveryCallerAuthenticator:
    MacRecoveryCallerAuthenticating
{
    private let processIdentifier: () -> Int32

    init(processIdentifier: @escaping () -> Int32 = { Darwin.getppid() }) {
        self.processIdentifier = processIdentifier
    }

    func authenticate(policy: MacSealedInstallPolicyV1) throws {
        guard policy.allowedApplicationSigner.kind
                == "appleDesignatedRequirement" else {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
        let pid = processIdentifier()
        guard pid > 0 else {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
        let attributes = NSDictionary(
            object: NSNumber(value: pid),
            forKey: kSecGuestAttributePid as String as NSString
        )
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess,
            let code,
            SecRequirementCreateWithString(
                policy.allowedApplicationSigner.value as CFString,
                [],
                &requirement
            ) == errSecSuccess,
            let requirement,
            SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
            signingIdentifier(code) == policy.applicationPackageID else {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
    }

    private func signingIdentifier(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode,
            SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any] else {
            return nil
        }
        return values[kSecCodeInfoIdentifier as String] as? String
    }
}

final class SystemMacRecoveryPayloadVerifierFactory:
    MacRecoveryPayloadVerifierCreating
{
    func makeVerifier(
        expectedIdentity: MacVerifiedPayloadIdentity
    ) throws -> any MacInstallPayloadVerifying {
        MacJournalPayloadVerifier(expectedIdentity: expectedIdentity)
    }
}

private final class MacRecoveryOnlyInstallerRunner: MacFixedInstallerRunning {
    func spawnVerifiedInstaller(
        at _: URL,
        kind _: MacVerifiedInstallerKind
    ) throws -> any MacGatedInstallerWorker {
        throw MacPersistentRecoveryError.journalCorrupt
    }
}

private func validPersistentSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
        $0.isNumber || ("a" ... "f").contains($0)
    }
}

private func persistentPackageIdentifier(_ value: String) -> Bool {
    value.range(
        of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9._-]{0,126}[a-zA-Z0-9])?$"#,
        options: .regularExpression
    ) != nil
}

private func validPersistentInstallerStageName(_ value: String) -> Bool {
    value.range(
        of: #"^desktop-updater-stage-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
        options: .regularExpression
    ) != nil
}

private func validPersistentSourceStageName(_ value: String) -> Bool {
    value.range(
        of: #"^desktop_updater_stage_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
        options: .regularExpression
    ) != nil
}

private func validPersistentInstallerJournalState(
    _ journal: MacVerifiedInstallerJournal
) -> Bool {
    let validReservation = validPersistentSHA256(
        journal.reservationJournalSHA256
    )
    let validProviderIdentity = journal.providerTransactionIdentity.range(
        of: #"^[a-zA-Z0-9._:-]{1,256}$"#,
        options: .regularExpression
    ) != nil
    let validManager = journal.managerProcessIdentifier > 0
        && journal.managerProcessStartIdentity.range(
            of: #"^macos:[0-9]+:[0-9]+$"#,
            options: .regularExpression
        ) != nil
    let noManager = journal.managerProcessIdentifier == 0
        && journal.managerProcessStartIdentity.isEmpty
    let hasProtectedInstaller = journal.installerStageIdentity
        != emptyPersistentProviderFileIdentity
        && journal.installerIdentity != emptyPersistentProviderFileIdentity
        && journal.installerStageIdentity.mode
            & UInt16(S_IFMT) == UInt16(S_IFDIR)
        && journal.installerIdentity.mode
            & UInt16(S_IFMT) == UInt16(S_IFREG)
        && journal.installerIdentity.mode & 0o222 == 0
    switch journal.state {
    case .preparing:
        return journal.reservationJournalSHA256.isEmpty
            && journal.providerTransactionIdentity.isEmpty
            && noManager
            && !hasProtectedInstaller
    case .prepared:
        return journal.reservationJournalSHA256.isEmpty
            && journal.providerTransactionIdentity.isEmpty
            && noManager
            && hasProtectedInstaller
    case .commitAccepted:
        return validReservation
            && journal.providerTransactionIdentity.isEmpty
            && noManager
            && hasProtectedInstaller
    case .managerStarted:
        return validReservation && validProviderIdentity
            && validManager && hasProtectedInstaller
    case .verificationPending, .completed:
        return validReservation && validProviderIdentity
            && validManager && hasProtectedInstaller
    case .rolledBack:
        return (journal.reservationJournalSHA256.isEmpty || validReservation)
            && journal.providerTransactionIdentity.isEmpty
            && noManager
    case .manualActionRequired:
        return (journal.reservationJournalSHA256.isEmpty || validReservation)
            && (journal.providerTransactionIdentity.isEmpty
                || validProviderIdentity)
            && (noManager || validManager)
    }
}

private let emptyPersistentProviderFileIdentity = MacFileIdentity(
    device: 0,
    inode: 0,
    mode: 0,
    userIdentifier: 0,
    groupIdentifier: 0
)

private func persistentOwnerIsLive(
    processIdentifier: Int32,
    startIdentity: String
) -> Bool {
    guard processIdentifier > 0 else { return false }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(
        processIdentifier,
        PROC_PIDTBSDINFO,
        0,
        &info,
        Int32(size)
    ) == size else {
        return false
    }
    return startIdentity
        == "macos:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
}

private func persistentRecoverySmokeGateIsActive() -> Bool {
    let readyPath =
        "/private/var/tmp/net.monolib.updater.pkg-recovery.ready"
    let releasePath =
        "/private/var/tmp/net.monolib.updater.pkg-recovery.release"
    var ready = stat()
    guard readyPath.withCString({ Darwin.lstat($0, &ready) }) == 0,
          ready.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          ready.st_uid == 0,
          ready.st_gid == 0,
          ready.st_mode & 0o777 == 0o600 else {
        return false
    }
    var release = stat()
    errno = 0
    return releasePath.withCString({ Darwin.lstat($0, &release) }) == -1
        && errno == ENOENT
}

private func waitForPersistentOwnerExit(
    processIdentifier: Int32,
    startIdentity: String,
    timeoutNanoseconds: UInt64,
    pollIntervalMicroseconds: UInt32
) -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    let deadline = start.addingReportingOverflow(timeoutNanoseconds)
    let deadlineValue = deadline.overflow ? UInt64.max : deadline.partialValue
    while persistentOwnerIsLive(
        processIdentifier: processIdentifier,
        startIdentity: startIdentity
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineValue else { return false }
        let remainingMicroseconds = max(
            (deadlineValue - now) / 1_000,
            1
        )
        Darwin.usleep(
            min(
                pollIntervalMicroseconds,
                UInt32(min(remainingMicroseconds, UInt64(UInt32.max)))
            )
        )
    }
    return true
}

private final class MacJournalPayloadVerifier: MacInstallPayloadVerifying {
    private let expectedIdentity: MacVerifiedPayloadIdentity

    init(expectedIdentity: MacVerifiedPayloadIdentity) {
        self.expectedIdentity = expectedIdentity
    }

    func verifyPayload(at bundleURL: URL) throws -> MacVerifiedPayloadIdentity {
        let canonical = bundleURL.standardizedFileURL
        let info = try PropertyListSerialization.propertyList(
            from: macReadBoundedRegularFile(
                canonical.appendingPathComponent("Contents/Info.plist"),
                maximumLength: 1_048_576
            ),
            options: [],
            format: nil
        )
        guard let dictionary = info as? [String: Any],
              dictionary["CFBundleIdentifier"] as? String
                == expectedIdentity.packageIdentifier,
              let executableName = dictionary["CFBundleExecutable"]
                as? String,
              persistentSimpleName(executableName) else {
            throw MacPayloadVerificationError.invalidBundle
        }
        let executableSHA256 = try macBoundedFileSHA256(
            canonical.appendingPathComponent(
                "Contents/MacOS/\(executableName)"
            ),
            maximumLength: 16 * 1024 * 1024 * 1024
        )
        guard executableSHA256
                == expectedIdentity.executableSHA256,
              try macAuthorizedTreeSHA256(canonical)
                == expectedIdentity.bundleSHA256 else {
            throw MacPayloadVerificationError.executableMismatch
        }
        try macVerifyBundleSignature(
            bundleURL: canonical,
            requirement: expectedIdentity.designatedRequirement
        )
        return expectedIdentity
    }
}

private func persistentSimpleName(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\\")
        && !value.contains("\0")
}
