import Darwin
import Foundation

enum MacVerifiedInstallerFaultPoint: String, CaseIterable {
    case afterPreparingJournalFlush
    case afterPreparedJournalFlush
    case afterCommitAcceptedJournalFlush
    case afterManagerWorkerSpawn
    case afterManagerStartedJournalFlush
    case afterVerificationPendingJournalFlush
    case afterCompletedJournalFlush
    case afterRolledBackJournalFlush
    case afterOwnedStageRemoval
    case afterTargetLockRelease
    case afterCommitAuthorizationRemoval
    case afterProviderJournalRemoval
}

protocol MacVerifiedInstallerFaultInjecting: AnyObject {
    func hit(_ point: MacVerifiedInstallerFaultPoint) throws
}

final class NoMacVerifiedInstallerFaultInjector:
    MacVerifiedInstallerFaultInjecting
{
    func hit(_: MacVerifiedInstallerFaultPoint) throws {}
}

enum MacVerifiedInstallerTransactionState: String, Codable, CaseIterable {
    case preparing
    case prepared
    case commitAccepted
    case managerStarted
    case verificationPending
    case completed
    case rolledBack
    case manualActionRequired
}

struct MacVerifiedInstallerJournal: Codable, Equatable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let transactionID: String
    let ownerProcessIdentifier: Int32
    let ownerProcessStartIdentity: String
    let policyID: String
    let policySHA256: String
    let targetName: String
    let parentIdentity: MacFileIdentity
    let targetIdentity: MacFileIdentity
    let sourceInstallerStageName: String?
    let sourceInstallerStageParentPath: String?
    let sourceInstallerStageParentIdentity: MacFileIdentity?
    let sourceInstallerStageIdentity: MacFileIdentity?
    let installerStageName: String
    let installerStageParentPath: String
    let installerStageParentIdentity: MacFileIdentity
    var installerStageIdentity: MacFileIdentity
    let installerPath: String
    var installerIdentity: MacFileIdentity
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
    var reservationJournalSHA256: String
    var providerTransactionIdentity: String
    var managerProcessIdentifier: Int32
    var managerProcessStartIdentity: String
    var state: MacVerifiedInstallerTransactionState

    init(
        transactionID: String,
        ownerProcessIdentifier: Int32,
        ownerProcessStartIdentity: String,
        policyID: String,
        policySHA256: String,
        targetName: String,
        parentIdentity: MacFileIdentity,
        targetIdentity: MacFileIdentity,
        sourceInstallerStageName: String,
        sourceInstallerStageParentPath: String,
        sourceInstallerStageParentIdentity: MacFileIdentity,
        sourceInstallerStageIdentity: MacFileIdentity,
        installerStageName: String,
        installerStageParentPath: String,
        installerStageParentIdentity: MacFileIdentity,
        installerStageIdentity: MacFileIdentity,
        installerPath: String,
        installerIdentity: MacFileIdentity,
        expectation: MacVerifiedInstallerExpectation,
        state: MacVerifiedInstallerTransactionState
    ) {
        schemaVersion = Self.schemaVersion
        self.transactionID = transactionID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerProcessStartIdentity = ownerProcessStartIdentity
        self.policyID = policyID
        self.policySHA256 = policySHA256
        self.targetName = targetName
        self.parentIdentity = parentIdentity
        self.targetIdentity = targetIdentity
        self.sourceInstallerStageName = sourceInstallerStageName
        self.sourceInstallerStageParentPath = sourceInstallerStageParentPath
        self.sourceInstallerStageParentIdentity =
            sourceInstallerStageParentIdentity
        self.sourceInstallerStageIdentity = sourceInstallerStageIdentity
        self.installerStageName = installerStageName
        self.installerStageParentPath = installerStageParentPath
        self.installerStageParentIdentity = installerStageParentIdentity
        self.installerStageIdentity = installerStageIdentity
        self.installerPath = installerPath
        self.installerIdentity = installerIdentity
        packageIdentifier = expectation.packageIdentifier
        expectedVersion = expectation.expectedVersion
        expectedBuildNumber = expectation.expectedBuildNumber
        designatedRequirement = expectation.designatedRequirement
        artifactSHA256 = expectation.artifactSHA256
        artifactLength = expectation.artifactLength
        expectedPackageIdentifiers = expectation.expectedPackageIdentifiers
        expectedReceiptVersions = expectation.expectedReceiptVersions
        expectedExecutableSHA256 = expectation.expectedExecutableSHA256
        expectedBundleTreeSHA256 = expectation.expectedBundleTreeSHA256
        descriptorSHA256 = expectation.descriptorSHA256
        provenanceSHA256 = expectation.provenanceSHA256
        reservationJournalSHA256 = ""
        providerTransactionIdentity = ""
        managerProcessIdentifier = 0
        managerProcessStartIdentity = ""
        self.state = state
    }

    static func decodeStrict(_ data: Data) throws
        -> MacVerifiedInstallerJournal
    {
        guard try NativeStrictJSON.canonicalize(data) == data,
              let object = try NativeStrictJSON.decode(data)
                as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            throw TransactionJournalError.invalidJournal
        }
        let legacyKeys: Set<String> = [
                  "schemaVersion", "transactionID",
                  "ownerProcessIdentifier", "ownerProcessStartIdentity",
                  "policyID", "policySHA256", "targetName",
                  "parentIdentity", "targetIdentity", "installerStageName",
                  "installerStageParentPath", "installerStageParentIdentity",
                  "installerStageIdentity", "installerPath",
                  "installerIdentity", "packageIdentifier",
                  "expectedVersion", "expectedBuildNumber",
                  "designatedRequirement", "artifactSHA256",
                  "artifactLength",
                  "expectedPackageIdentifiers", "expectedReceiptVersions",
                  "expectedExecutableSHA256", "expectedBundleTreeSHA256",
                  "descriptorSHA256",
                  "provenanceSHA256", "reservationJournalSHA256",
                  "providerTransactionIdentity", "managerProcessIdentifier",
                  "managerProcessStartIdentity", "state",
              ]
        let sourceStageKeys: Set<String> = [
            "sourceInstallerStageName", "sourceInstallerStageParentPath",
            "sourceInstallerStageParentIdentity",
            "sourceInstallerStageIdentity",
        ]
        guard (version == 1 && Set(object.keys) == legacyKeys)
                || (version == schemaVersion
                    && Set(object.keys) == legacyKeys.union(sourceStageKeys)),
              exactIdentityKeys(object["parentIdentity"]),
              exactIdentityKeys(object["targetIdentity"]),
              exactIdentityKeys(object["installerStageParentIdentity"]),
              exactIdentityKeys(object["installerStageIdentity"]),
              exactIdentityKeys(object["installerIdentity"]),
              version == 1 || (
                exactIdentityKeys(object["sourceInstallerStageParentIdentity"])
                    && exactIdentityKeys(
                        object["sourceInstallerStageIdentity"]
                    )
              ) else {
            throw TransactionJournalError.invalidJournal
        }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.schemaVersion == version,
                  version == 1 || (
                    value.sourceInstallerStageName != nil
                        && value.sourceInstallerStageParentPath != nil
                        && value.sourceInstallerStageParentIdentity != nil
                        && value.sourceInstallerStageIdentity != nil
                  ) else {
                throw TransactionJournalError.invalidJournal
            }
            return value
        } catch {
            throw TransactionJournalError.invalidJournal
        }
    }

    private static func exactIdentityKeys(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return Set(object.keys) == [
            "device", "inode", "mode", "userIdentifier",
            "groupIdentifier",
        ]
    }
}

extension MacTransactionPaths {
    var providerJournalName: String {
        ".\(targetName).desktop-updater-\(transactionID).provider.json"
    }
}

final class DurableMacVerifiedInstallerJournalStore {
    let directory: MacTransactionDirectory
    let paths: MacTransactionPaths

    init(directory: MacTransactionDirectory, paths: MacTransactionPaths) {
        self.directory = directory
        self.paths = paths
    }

    func load() throws -> MacVerifiedInstallerJournal? {
        let descriptor = paths.providerJournalName.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw TransactionJournalError.invalidJournal
        }
        defer { _ = Darwin.close(descriptor) }
        return try MacVerifiedInstallerJournal.decodeStrict(
            readAll(descriptor)
        )
    }

    func persist(_ journal: MacVerifiedInstallerJournal) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try NativeStrictJSON.canonicalize(
                encoder.encode(journal)
            )
        } catch {
            throw TransactionJournalError.persistenceFailed
        }
        let temporaryName = paths.providerJournalName + ".next"
        _ = temporaryName.withCString {
            Darwin.unlinkat(directory.fileDescriptor, $0, 0)
        }
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw TransactionJournalError.persistenceFailed
        }
        var open = true
        do {
            try writeAll(data, descriptor)
            guard Darwin.fsync(descriptor) == 0,
                  Darwin.close(descriptor) == 0 else {
                throw TransactionJournalError.persistenceFailed
            }
            open = false
            let result = temporaryName.withCString { source in
                paths.providerJournalName.withCString { destination in
                    Darwin.renameat(
                        directory.fileDescriptor,
                        source,
                        directory.fileDescriptor,
                        destination
                    )
                }
            }
            guard result == 0 else {
                throw TransactionJournalError.persistenceFailed
            }
            try directory.sync()
        } catch {
            if open { _ = Darwin.close(descriptor) }
            throw error
        }
    }

    func sha256() throws -> String {
        let descriptor = paths.providerJournalName.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TransactionJournalError.invalidJournal
        }
        defer { _ = Darwin.close(descriptor) }
        return macPrivilegeSHA256(try readAll(descriptor))
    }

    func remove() throws {
        guard directory.exists(name: paths.providerJournalName) else {
            return
        }
        let identity = try directory.identity(
            name: paths.providerJournalName,
            rejectSymbolicLink: true
        )
        try directory.removeFile(
            name: paths.providerJournalName,
            expectedIdentity: identity
        )
    }

    private func readAll(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            guard count > 0 else {
                throw TransactionJournalError.invalidJournal
            }
            result.append(buffer, count: count)
            guard result.count <= 128 * 1024 else {
                throw TransactionJournalError.invalidJournal
            }
        }
    }

    private func writeAll(_ data: Data, _ descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw TransactionJournalError.persistenceFailed
                }
                offset += count
            }
        }
    }
}

final class MacVerifiedInstallerTransaction:
    MacPreparedInstallTransaction
{
    private enum Lifecycle {
        case reserved
        case preparing
        case prepared
        case executing
        case completed
        case cancelled
        case recoveryRequired
    }

    let paths: MacTransactionPaths
    private let directory: MacTransactionDirectory
    private let sourceInstallerDirectory: MacTransactionDirectory
    private let sourceInstallerStageParentDirectory: MacTransactionDirectory
    private let sourceInstallerStageIdentity: MacFileIdentity
    private let protectedStage: MacVerifiedInstallerProtectedStage
    private var installerDirectory: MacTransactionDirectory?
    private var installerStageIdentity: MacFileIdentity?
    private var expectation: MacVerifiedInstallerExpectation
    private let handoff: MacVerifiedInstallerHandoff
    private let targetIdentity: MacFileIdentity
    private let retainedSourceInstaller: MacRetainedFileObject
    private var retainedInstaller: MacRetainedFileObject?
    private let ownerProcessIdentifier: Int32
    private let ownerProcessStartIdentity: String
    private let policyID: String
    private let policySHA256: String
    private let store: DurableMacVerifiedInstallerJournalStore
    private let commitStore: MacCommitAuthorizationStore
    private let targetLock: MacTargetLock
    private let faultInjector: any MacVerifiedInstallerFaultInjecting
    private let diagnostics: any MacHelperDiagnosticsRecording
    private let lifecycleLock = NSLock()
    private var lifecycle = Lifecycle.reserved

    init(
        transactionID: String,
        ownerProcessIdentifier: Int32,
        ownerProcessStartIdentity: String,
        policyID: String,
        policySHA256: String,
        expectation: MacVerifiedInstallerExpectation,
        handoff: MacVerifiedInstallerHandoff,
        protectedStageBaseURL: URL =
            MacVerifiedInstallerProtectedStage.defaultBaseURL,
        faultInjector: any MacVerifiedInstallerFaultInjecting =
            NoMacVerifiedInstallerFaultInjector(),
        diagnostics: any MacHelperDiagnosticsRecording =
            NoMacHelperDiagnosticsRecorder()
    ) throws {
        let target = expectation.targetURL.standardizedFileURL
        let installer = expectation.installerURL.standardizedFileURL
        let sourceInstallerStage = installer.deletingLastPathComponent()
        guard target.path == expectation.targetURL.path,
              installer.path == expectation.installerURL.path,
              installer.lastPathComponent == "installer.pkg",
              validProviderStageName(
                sourceInstallerStage.lastPathComponent
              ),
              expectation.kind == .pkg,
              expectation.hasSecurityBinding,
              ownerProcessIdentifier > 0,
              ownerProcessStartIdentity.hasPrefix("macos:"),
              validProviderSHA256(policySHA256) else {
            throw MacFileTransactionError.invalidPathOrTransaction
        }
        let transactionPaths = try MacTransactionPaths(
            targetName: target.lastPathComponent,
            transactionID: transactionID
        )
        paths = transactionPaths
        let targetDirectory = try MacTransactionDirectory(
            url: target.deletingLastPathComponent()
        )
        directory = targetDirectory
        let stageDirectory = try MacTransactionDirectory(
            url: sourceInstallerStage
        )
        sourceInstallerDirectory = stageDirectory
        let stageParentDirectory = try MacTransactionDirectory(
            url: sourceInstallerStage.deletingLastPathComponent()
        )
        sourceInstallerStageParentDirectory = stageParentDirectory
        let stageIdentity = try stageParentDirectory.identity(
            name: sourceInstallerStage.lastPathComponent,
            rejectSymbolicLink: true
        )
        guard stageIdentity == stageDirectory.identity else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        sourceInstallerStageIdentity = stageIdentity
        let ownedStage = try MacVerifiedInstallerProtectedStage.plan(
            baseURL: protectedStageBaseURL,
            policyID: policyID,
            transactionID: transactionID
        )
        protectedStage = ownedStage
        installerDirectory = nil
        installerStageIdentity = nil
        self.expectation = expectation.replacingInstallerURL(
            ownedStage.installerURL
        )
        self.handoff = handoff
        self.faultInjector = faultInjector
        self.diagnostics = diagnostics
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerProcessStartIdentity = ownerProcessStartIdentity
        self.policyID = policyID
        self.policySHA256 = policySHA256
        let initialTarget = try targetDirectory.identity(
            name: transactionPaths.targetName,
            rejectSymbolicLink: true
        )
        targetIdentity = initialTarget
        let retained = try MacRetainedFileObject(
            directory: stageDirectory,
            name: installer.lastPathComponent
        )
        guard retained.identity.mode & UInt16(S_IFMT) == UInt16(S_IFREG)
        else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        retainedSourceInstaller = retained
        retainedInstaller = nil
        let journalStore = DurableMacVerifiedInstallerJournalStore(
            directory: targetDirectory,
            paths: transactionPaths
        )
        store = journalStore
        commitStore = MacCommitAuthorizationStore(
            directory: targetDirectory,
            paths: transactionPaths
        )
        for name in [
            transactionPaths.journalName,
            transactionPaths.providerJournalName,
            transactionPaths.providerJournalName + ".next",
            transactionPaths.commitAuthorizationName,
        ] where targetDirectory.exists(name: name) {
            throw MacFileTransactionError.derivedArtifactAlreadyExists
        }
        try journalStore.persist(
            MacVerifiedInstallerJournal(
                transactionID: transactionID,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerProcessStartIdentity: ownerProcessStartIdentity,
                policyID: policyID,
                policySHA256: policySHA256,
                targetName: transactionPaths.targetName,
                parentIdentity: targetDirectory.identity,
                targetIdentity: initialTarget,
                sourceInstallerStageName:
                    sourceInstallerStage.lastPathComponent,
                sourceInstallerStageParentPath:
                    stageParentDirectory.url.path,
                sourceInstallerStageParentIdentity:
                    stageParentDirectory.identity,
                sourceInstallerStageIdentity: stageIdentity,
                installerStageName: ownedStage.stageName,
                installerStageParentPath:
                    ownedStage.parentDirectory.url.path,
                installerStageParentIdentity:
                    ownedStage.parentDirectory.identity,
                installerStageIdentity: emptyProviderFileIdentity,
                installerPath: ownedStage.installerURL.path,
                installerIdentity: emptyProviderFileIdentity,
                expectation: self.expectation,
                state: .preparing
            )
        )
        try faultInjector.hit(.afterPreparingJournalFlush)
        do {
            targetLock = try MacTargetLock(
                directory: targetDirectory,
                name: transactionPaths.lockName,
                transactionID: transactionID
            )
        } catch {
            try? journalStore.remove()
            throw error
        }
    }

    func prepare() throws -> String {
        try transition(from: .reserved, to: .preparing)
        diagnostics.record(
            .stagingPathValidation,
            transactionID: paths.transactionID,
            state: "preparing",
            resultCode: "started",
            detailCode: "pkg"
        )
        do {
            try validateSourceBeforeCopy()
            var journal = try requiredJournal(state: .preparing)
            let copied = try protectedStage.copyInstaller(
                from: retainedSourceInstaller,
                expectedLength: expectation.artifactLength
            )
            let protectedDirectory = try MacTransactionDirectory(
                url: protectedStage.stageURL
            )
            let protectedInstaller = try MacRetainedFileObject(
                directory: protectedDirectory,
                name: "installer.pkg"
            )
            guard copied.stageIdentity == protectedDirectory.identity,
                  copied.installerIdentity == protectedInstaller.identity
            else {
                throw MacFileTransactionError.stageIdentityChanged
            }
            installerDirectory = protectedDirectory
            installerStageIdentity = copied.stageIdentity
            retainedInstaller = protectedInstaller
            try validatePreLaunchEvidence()
            journal.installerStageIdentity = copied.stageIdentity
            journal.installerIdentity = copied.installerIdentity
            journal.state = .prepared
            try store.persist(journal)
            try faultInjector.hit(.afterPreparedJournalFlush)
            let digest = try store.sha256()
            diagnostics.record(
                .stagingPathValidation,
                transactionID: paths.transactionID,
                state: "prepared",
                resultCode: "success",
                detailCode: "pkg"
            )
            setLifecycle(.prepared)
            return digest
        } catch {
            diagnostics.record(
                .stagingPathValidation,
                transactionID: paths.transactionID,
                state: "preparing",
                resultCode: "failure",
                detailCode: "pkg"
            )
            setLifecycle(.recoveryRequired)
            throw error
        }
    }

    func authorizeCommit() throws {
        guard currentLifecycle() == .prepared else {
            throw MacFileTransactionError.invalidState
        }
        var journal = try requiredJournal(state: .prepared)
        let digest = try store.sha256()
        try commitStore.create(journalSHA256: digest)
        journal.reservationJournalSHA256 = digest
        journal.state = .commitAccepted
        try store.persist(journal)
        try faultInjector.hit(.afterCommitAcceptedJournalFlush)
    }

    func execute() throws -> MacFileTransactionResult {
        try transition(from: .prepared, to: .executing)
        var journal = try requiredJournal(state: .commitAccepted)
        guard validProviderSHA256(journal.reservationJournalSHA256),
              try commitStore.validates(
                  journalSHA256: journal.reservationJournalSHA256
              ) else {
            setLifecycle(.recoveryRequired)
            throw MacFileTransactionError.invalidState
        }
        var activeEvent: MacHelperEvent?
        do {
            try validatePreLaunchEvidence()
            activeEvent = .managerStarted
            diagnostics.record(
                .managerStarted,
                transactionID: paths.transactionID,
                state: "commitAccepted",
                resultCode: "started",
                detailCode: "pkg"
            )
            let worker = try handoff.verifyAndSpawn(expectation)
            diagnostics.record(
                .managerStarted,
                transactionID: paths.transactionID,
                state: "managerStarted",
                resultCode: "success",
                detailCode: "pkg"
            )
            activeEvent = .verificationPending
            try faultInjector.hit(.afterManagerWorkerSpawn)
            journal.providerTransactionIdentity =
                worker.identity.providerTransactionIdentity
            journal.managerProcessIdentifier =
                worker.identity.processIdentifier
            journal.managerProcessStartIdentity =
                worker.identity.processStartIdentity
            journal.state = .managerStarted
            try store.persist(journal)
            try faultInjector.hit(.afterManagerStartedJournalFlush)
            try worker.releaseAndWait()
            journal.state = .verificationPending
            try store.persist(journal)
            try faultInjector.hit(.afterVerificationPendingJournalFlush)
            diagnostics.record(
                .verificationPending,
                transactionID: paths.transactionID,
                state: "verificationPending",
                resultCode: "started",
                detailCode: "pkg"
            )

            try handoff.verifyInstalled(expectation)
            diagnostics.record(
                .verificationSuccess,
                transactionID: paths.transactionID,
                state: "verificationPending",
                resultCode: "success",
                detailCode: "pkg"
            )
            journal.state = .completed
            try store.persist(journal)
            try faultInjector.hit(.afterCompletedJournalFlush)
            activeEvent = .cleanupStart
            diagnostics.record(
                .cleanupStart,
                transactionID: paths.transactionID,
                state: "completed",
                resultCode: "started",
                detailCode: "pkg"
            )
            try removeOwnedInstallerStageIfPresent()
            try removeSourceOwnedStageIfPresent()
            try faultInjector.hit(.afterOwnedStageRemoval)
            try targetLock.release()
            try faultInjector.hit(.afterTargetLockRelease)
            try commitStore.removeIfPresent()
            try faultInjector.hit(.afterCommitAuthorizationRemoval)
            try store.remove()
            try faultInjector.hit(.afterProviderJournalRemoval)
            diagnostics.record(
                .recoveryMarkerCleared,
                transactionID: paths.transactionID,
                state: "completed",
                resultCode: "success",
                detailCode: "pkg"
            )
            diagnostics.record(
                .cleanupSuccess,
                transactionID: paths.transactionID,
                state: "completed",
                resultCode: "success",
                detailCode: "pkg"
            )
            activeEvent = nil
            setLifecycle(.completed)
            return .completed
        } catch {
            if activeEvent == .managerStarted {
                diagnostics.record(
                    .managerStarted,
                    transactionID: paths.transactionID,
                    state: "recoveryRequired",
                    resultCode: "failure",
                    detailCode: "pkg"
                )
            } else if activeEvent == .verificationPending {
                diagnostics.record(
                    .verificationFailure,
                    transactionID: paths.transactionID,
                    state: "recoveryRequired",
                    resultCode: "failure",
                    detailCode: "pkg"
                )
            } else if activeEvent == .cleanupStart {
                diagnostics.record(
                    .cleanupFailure,
                    transactionID: paths.transactionID,
                    state: "recoveryRequired",
                    resultCode: "failure",
                    detailCode: "pkg"
                )
            }
            diagnostics.record(
                .recoveryRequired,
                transactionID: paths.transactionID,
                state: "recoveryRequired",
                resultCode: "required",
                detailCode: "pkg"
            )
            setLifecycle(.recoveryRequired)
            throw error
        }
    }

    func cancelPrepared() throws {
        try transition(from: .prepared, to: .preparing)
        do {
            var journal = try RequiredMacProviderJournal.load(store)
            guard [.prepared, .commitAccepted].contains(journal.state),
                  try directory.identity(
                      name: paths.targetName,
                      rejectSymbolicLink: true
                  ) == targetIdentity else {
                throw MacFileTransactionError.invalidState
            }
            journal.state = .rolledBack
            try store.persist(journal)
            try faultInjector.hit(.afterRolledBackJournalFlush)
            try removeOwnedInstallerStageIfPresent()
            try removeSourceOwnedStageIfPresent()
            try faultInjector.hit(.afterOwnedStageRemoval)
            try targetLock.release()
            try faultInjector.hit(.afterTargetLockRelease)
            try commitStore.removeIfPresent()
            try faultInjector.hit(.afterCommitAuthorizationRemoval)
            try store.remove()
            try faultInjector.hit(.afterProviderJournalRemoval)
            diagnostics.record(
                .recoveryMarkerCleared,
                transactionID: paths.transactionID,
                state: "cancelled",
                resultCode: "success",
                detailCode: "pkg"
            )
            setLifecycle(.cancelled)
        } catch {
            setLifecycle(.recoveryRequired)
            throw error
        }
    }

    private func validatePreLaunchEvidence() throws {
        try directory.validatePathIdentity()
        guard let installerDirectory,
              let installerStageIdentity,
              let retainedInstaller else {
            throw MacFileTransactionError.invalidState
        }
        try installerDirectory.validatePathIdentity()
        guard try directory.identity(
            name: paths.targetName,
            rejectSymbolicLink: true
        ) == targetIdentity,
            installerDirectory.identity == installerStageIdentity,
            try installerDirectory.identity(
                name: expectation.installerURL.lastPathComponent,
                rejectSymbolicLink: true
            ) == retainedInstaller.identity else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        _ = try handoff.verifyInstaller(expectation)
    }

    private func validateSourceBeforeCopy() throws {
        try directory.validatePathIdentity()
        try sourceInstallerDirectory.validatePathIdentity()
        try sourceInstallerStageParentDirectory.validatePathIdentity()
        guard try sourceInstallerStageParentDirectory.identity(
            name: sourceInstallerDirectory.url.lastPathComponent,
            rejectSymbolicLink: true
        ) == sourceInstallerStageIdentity,
            try sourceInstallerDirectory.identity(
                name: "installer.pkg",
                rejectSymbolicLink: true
            ) == retainedSourceInstaller.identity else {
            throw MacFileTransactionError.stageIdentityChanged
        }
    }

    private func requiredJournal(
        state: MacVerifiedInstallerTransactionState
    ) throws -> MacVerifiedInstallerJournal {
        guard let journal = try store.load(), journal.state == state,
              journal.transactionID == paths.transactionID,
              journal.targetName == paths.targetName,
              journal.ownerProcessIdentifier == ownerProcessIdentifier,
              journal.ownerProcessStartIdentity == ownerProcessStartIdentity,
              journal.policyID == policyID,
              journal.policySHA256 == policySHA256,
              journal.parentIdentity == directory.identity,
              journal.targetIdentity == targetIdentity,
              journal.sourceInstallerStageName
                == sourceInstallerDirectory.url.lastPathComponent,
              journal.sourceInstallerStageParentPath
                == sourceInstallerStageParentDirectory.url.path,
              journal.sourceInstallerStageParentIdentity
                == sourceInstallerStageParentDirectory.identity,
              journal.sourceInstallerStageIdentity
                == sourceInstallerStageIdentity,
              journal.installerStageName == protectedStage.stageName,
              journal.installerStageParentPath
                == protectedStage.parentDirectory.url.path,
              journal.installerStageParentIdentity
                == protectedStage.parentDirectory.identity,
              journal.installerPath == expectation.installerURL.path,
              journal.packageIdentifier == expectation.packageIdentifier,
              journal.expectedVersion == expectation.expectedVersion,
              journal.expectedBuildNumber == expectation.expectedBuildNumber,
              journal.designatedRequirement
                == expectation.designatedRequirement,
              journal.artifactSHA256 == expectation.artifactSHA256,
              journal.artifactLength == expectation.artifactLength,
              journal.expectedPackageIdentifiers
                == expectation.expectedPackageIdentifiers,
              journal.expectedReceiptVersions
                == expectation.expectedReceiptVersions,
              journal.expectedExecutableSHA256
                == expectation.expectedExecutableSHA256,
              journal.expectedBundleTreeSHA256
                == expectation.expectedBundleTreeSHA256,
              journal.descriptorSHA256 == expectation.descriptorSHA256,
              journal.provenanceSHA256 == expectation.provenanceSHA256 else {
            throw MacFileTransactionError.invalidState
        }
        switch state {
        case .preparing:
            guard journal.installerStageIdentity
                    == emptyProviderFileIdentity,
                  journal.installerIdentity == emptyProviderFileIdentity else {
                throw MacFileTransactionError.invalidState
            }
        default:
            guard let installerStageIdentity,
                  let retainedInstaller,
                  journal.installerStageIdentity == installerStageIdentity,
                  journal.installerIdentity == retainedInstaller.identity else {
                throw MacFileTransactionError.invalidState
            }
        }
        return journal
    }

    private func removeOwnedInstallerStageIfPresent() throws {
        try protectedStage.removeIfPresent(
            expectedIdentity: installerStageIdentity
        )
    }

    private func removeSourceOwnedStageIfPresent() throws {
        try sourceInstallerStageParentDirectory.validatePathIdentity()
        let name = sourceInstallerDirectory.url.lastPathComponent
        guard sourceInstallerStageParentDirectory.exists(name: name) else {
            return
        }
        try sourceInstallerStageParentDirectory.removeTree(
            name: name,
            expectedIdentity: sourceInstallerStageIdentity
        )
    }

    private func transition(
        from expected: Lifecycle,
        to next: Lifecycle
    ) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard lifecycle == expected else {
            throw MacFileTransactionError.invalidState
        }
        lifecycle = next
    }

    private func currentLifecycle() -> Lifecycle {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return lifecycle
    }

    private func setLifecycle(_ value: Lifecycle) {
        lifecycleLock.lock()
        lifecycle = value
        lifecycleLock.unlock()
    }
}

private enum RequiredMacProviderJournal {
    static func load(
        _ store: DurableMacVerifiedInstallerJournalStore
    ) throws -> MacVerifiedInstallerJournal {
        guard let journal = try store.load() else {
            throw MacFileTransactionError.invalidState
        }
        return journal
    }
}

private func validProviderSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
        $0.isNumber || ("a" ... "f").contains($0)
    }
}

private func validProviderStageName(_ value: String) -> Bool {
    value.range(
        of: #"^desktop_updater_stage_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
        options: .regularExpression
    ) != nil
}

private let emptyProviderFileIdentity = MacFileIdentity(
    device: 0,
    inode: 0,
    mode: 0,
    userIdentifier: 0,
    groupIdentifier: 0
)
