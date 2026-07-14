import Darwin
import Foundation

protocol ProcessLivenessChecking {
    func isProcessAlive(_ processIdentifier: Int32) -> Bool
}

struct DarwinProcessLivenessChecker: ProcessLivenessChecking {
    func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if Darwin.kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

enum MacRecoveryOutcome: Equatable {
    case recovered
    case nothingToRecover
    case liveOwner
}

enum MacRecoveryError: Error, Equatable {
    case invalidJournal
    case parentIdentityMismatch
    case stageIdentityMismatch
    case backupIdentityMismatch
    case payloadIdentityMismatch
    case inconsistentState
    case filesystemOperationFailed
}

final class MacRecoveryService {
    private let targetURL: URL
    private let paths: MacTransactionPaths?
    private let expectedPayloadIdentity: MacVerifiedPayloadIdentity
    private let verifier: any MacInstallPayloadVerifying
    private let processLivenessChecker: any ProcessLivenessChecking

    init(
        targetURL: URL,
        transactionID: String,
        expectedPayloadIdentity: MacVerifiedPayloadIdentity,
        verifier: any MacInstallPayloadVerifying,
        processLivenessChecker: any ProcessLivenessChecking =
            DarwinProcessLivenessChecker()
    ) {
        self.targetURL = targetURL.standardizedFileURL
        paths = try? MacTransactionPaths(
            targetName: targetURL.lastPathComponent,
            transactionID: transactionID
        )
        self.expectedPayloadIdentity = expectedPayloadIdentity
        self.verifier = verifier
        self.processLivenessChecker = processLivenessChecker
    }

    func recover() throws -> MacRecoveryOutcome {
        guard let paths else {
            throw MacRecoveryError.invalidJournal
        }
        let parentURL = targetURL.deletingLastPathComponent()
        let directory: MacTransactionDirectory
        do {
            directory = try MacTransactionDirectory(url: parentURL)
        } catch {
            throw MacRecoveryError.parentIdentityMismatch
        }
        let store = DurableTransactionJournalStore(
            directory: directory,
            paths: paths
        )
        let commitAuthorizationStore = MacCommitAuthorizationStore(
            directory: directory,
            paths: paths
        )
        let journal: MacTransactionJournal
        do {
            guard let loaded = try store.load() else {
                if try lockOwner(directory, paths: paths)
                    == paths.transactionID {
                    if directory.exists(name: paths.preparedName) {
                        let identity = try recoveryIdentity(
                            directory,
                            name: paths.preparedName
                        )
                        do {
                            try directory.removeTree(
                                name: paths.preparedName,
                                expectedIdentity: identity
                            )
                        } catch {
                            throw MacRecoveryError.filesystemOperationFailed
                        }
                    }
                    try commitAuthorizationStore.removeIfPresent()
                    try releaseLock(directory, paths: paths)
                    return .recovered
                }
                return .nothingToRecover
            }
            journal = loaded
        } catch {
            throw MacRecoveryError.invalidJournal
        }
        try validate(journal, paths: paths)
        guard try lockOwner(directory, paths: paths)
            == paths.transactionID else {
            throw MacRecoveryError.inconsistentState
        }
        if processLivenessChecker.isProcessAlive(
            journal.ownerProcessIdentifier
        ) {
            return .liveOwner
        }

        guard directory.identity == journal.parentIdentity else {
            throw MacRecoveryError.parentIdentityMismatch
        }

        if journal.state == .prepared,
           try !commitAuthorizationStore.validates(
               journalSHA256: store.sha256()
           ) {
            try rollbackUncommittedPreparation(
                journal: journal,
                directory: directory,
                store: store,
                commitAuthorizationStore: commitAuthorizationStore,
                paths: paths
            )
            return .recovered
        }

        var mutableJournal = journal
        if directory.exists(name: paths.backupName) {
            let identity = try recoveryIdentity(
                directory,
                name: paths.backupName
            )
            guard identity == journal.targetIdentity else {
                throw MacRecoveryError.backupIdentityMismatch
            }
        }

        if !directory.exists(name: paths.preparedName),
           directory.exists(name: journal.originalStageName) {
            let stageIdentity = try recoveryIdentity(
                directory,
                name: journal.originalStageName
            )
            guard stageIdentity == journal.stageIdentity else {
                throw MacRecoveryError.stageIdentityMismatch
            }
            try verifyPayload(
                at: parentURL.appendingPathComponent(
                    journal.originalStageName
                )
            )
            try recoveryRename(
                directory,
                from: journal.originalStageName,
                to: paths.preparedName
            )
        }

        if !directory.exists(name: paths.backupName),
           directory.exists(name: paths.preparedName) {
            guard directory.exists(name: paths.targetName),
                  try recoveryIdentity(
                      directory,
                      name: paths.targetName
                  ) == journal.targetIdentity else {
                throw MacRecoveryError.inconsistentState
            }
            try recoveryRename(
                directory,
                from: paths.targetName,
                to: paths.backupName
            )
            mutableJournal.state = .backupCreated
            try recoveryPersist(mutableJournal, store: store)
        }

        if directory.exists(name: paths.backupName),
           directory.exists(name: paths.preparedName),
           !directory.exists(name: paths.targetName) {
            guard try recoveryIdentity(
                directory,
                name: paths.preparedName
            ) == journal.stageIdentity else {
                throw MacRecoveryError.stageIdentityMismatch
            }
            try verifyPayload(
                at: parentURL.appendingPathComponent(paths.preparedName)
            )
            try recoveryRename(
                directory,
                from: paths.preparedName,
                to: paths.targetName
            )
            mutableJournal.state = .targetActivated
            try recoveryPersist(mutableJournal, store: store)
        }

        guard directory.exists(name: paths.targetName),
              !directory.exists(name: paths.preparedName) else {
            throw MacRecoveryError.inconsistentState
        }
        try verifyPayload(
            at: parentURL.appendingPathComponent(paths.targetName)
        )
        if directory.exists(name: paths.backupName) {
            mutableJournal.state = .targetActivated
            try recoveryPersist(mutableJournal, store: store)
            mutableJournal.state = .completed
            try recoveryPersist(mutableJournal, store: store)
            do {
                try directory.removeTree(
                    name: paths.backupName,
                    expectedIdentity: journal.targetIdentity
                )
            } catch {
                throw MacRecoveryError.backupIdentityMismatch
            }
        }
        do {
            try store.remove()
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
        do {
            try commitAuthorizationStore.removeIfPresent()
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
        try releaseLock(directory, paths: paths)
        return .recovered
    }

    private func rollbackUncommittedPreparation(
        journal: MacTransactionJournal,
        directory: MacTransactionDirectory,
        store: DurableTransactionJournalStore,
        commitAuthorizationStore: MacCommitAuthorizationStore,
        paths: MacTransactionPaths
    ) throws {
        guard directory.exists(name: paths.targetName),
              try recoveryIdentity(directory, name: paths.targetName)
                == journal.targetIdentity,
              !directory.exists(name: paths.backupName) else {
            throw MacRecoveryError.inconsistentState
        }
        if directory.exists(name: paths.preparedName) {
            guard try recoveryIdentity(directory, name: paths.preparedName)
                    == journal.stageIdentity else {
                throw MacRecoveryError.stageIdentityMismatch
            }
            do {
                try directory.removeTree(
                    name: paths.preparedName,
                    expectedIdentity: journal.stageIdentity
                )
            } catch {
                throw MacRecoveryError.filesystemOperationFailed
            }
        }
        do {
            try commitAuthorizationStore.removeIfPresent()
            try store.remove()
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
        try releaseLock(directory, paths: paths)
    }

    private func validate(
        _ journal: MacTransactionJournal,
        paths: MacTransactionPaths
    ) throws {
        guard journal.schemaVersion == MacTransactionJournal.schemaVersion,
              journal.transactionID == paths.transactionID,
              journal.targetName == paths.targetName,
              journal.preparedName == paths.preparedName,
              journal.backupName == paths.backupName,
              journal.expectedPayloadIdentity == expectedPayloadIdentity,
              isSimpleName(journal.originalStageName),
              journal.originalStageName != paths.targetName else {
            throw MacRecoveryError.invalidJournal
        }
    }

    private func verifyPayload(at url: URL) throws {
        do {
            guard try verifier.verifyPayload(at: url)
                == expectedPayloadIdentity else {
                throw MacRecoveryError.payloadIdentityMismatch
            }
        } catch let error as MacRecoveryError {
            throw error
        } catch {
            throw MacRecoveryError.payloadIdentityMismatch
        }
    }

    private func recoveryIdentity(
        _ directory: MacTransactionDirectory,
        name: String
    ) throws -> MacFileIdentity {
        do {
            return try directory.identity(
                name: name,
                rejectSymbolicLink: true
            )
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
    }

    private func recoveryRename(
        _ directory: MacTransactionDirectory,
        from source: String,
        to destination: String
    ) throws {
        do {
            try directory.renameExclusively(
                from: source,
                to: destination
            )
            try directory.sync()
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
    }

    private func recoveryPersist(
        _ journal: MacTransactionJournal,
        store: DurableTransactionJournalStore
    ) throws {
        do {
            try store.persist(journal)
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
    }

    private func lockOwner(
        _ directory: MacTransactionDirectory,
        paths: MacTransactionPaths
    ) throws -> String? {
        do {
            return try MacTargetLock.owner(
                directory: directory,
                name: paths.lockName
            )
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
    }

    private func releaseLock(
        _ directory: MacTransactionDirectory,
        paths: MacTransactionPaths
    ) throws {
        do {
            try MacTargetLock.releaseExisting(
                directory: directory,
                name: paths.lockName,
                transactionID: paths.transactionID
            )
        } catch MacFileTransactionError.targetBusy {
            throw MacRecoveryError.inconsistentState
        } catch MacFileTransactionError.targetIdentityChanged {
            throw MacRecoveryError.inconsistentState
        } catch {
            throw MacRecoveryError.filesystemOperationFailed
        }
    }

    private func isSimpleName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }
}
