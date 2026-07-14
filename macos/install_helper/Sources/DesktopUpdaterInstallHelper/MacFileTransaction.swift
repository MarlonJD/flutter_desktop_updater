import Darwin
import Foundation

@_silgen_name("removefileat")
private func macRemoveFileAt(
    _ fileDescriptor: Int32,
    _ path: UnsafePointer<CChar>,
    _ state: OpaquePointer?,
    _ flags: UInt32
) -> Int32

private let macRemoveFileRecursive: UInt32 = 1 << 0

struct MacVerifiedPayloadIdentity: Codable, Equatable {
    let packageIdentifier: String
    let designatedRequirement: String
    let bundleSHA256: String
    let provenanceSHA256: String
    let executableSHA256: String
}

protocol MacInstallPayloadVerifying {
    func verifyPayload(at bundleURL: URL) throws -> MacVerifiedPayloadIdentity
}

struct MacTransactionPaths: Equatable {
    let targetName: String
    let transactionID: String
    let preparedName: String
    let backupName: String
    let journalName: String
    let lockName: String

    init(targetName: String, transactionID: String) throws {
        guard !targetName.isEmpty,
              targetName != ".",
              targetName != "..",
              !targetName.contains("/"),
              !targetName.contains("\0"),
              transactionID == transactionID.lowercased(),
              let uuid = UUID(uuidString: transactionID),
              uuid.uuidString.lowercased() == transactionID else {
            throw MacFileTransactionError.invalidPathOrTransaction
        }
        self.targetName = targetName
        self.transactionID = transactionID
        let prefix = ".\(targetName).desktop-updater-\(transactionID)"
        preparedName = prefix + ".prepared"
        backupName = prefix + ".backup"
        journalName = prefix + ".journal.json"
        lockName = prefix + ".lock"
    }
}

enum MacTransactionFaultPoint: String, CaseIterable {
    case beforePreparedJournalFlush
    case afterPreparedJournalFlush
    case beforeStageRename
    case afterStageRenameBeforeDirectorySync
    case afterStageRename
    case beforeBackupRename
    case afterBackupRenameBeforeDirectorySync
    case afterBackupRename
    case beforeBackupCreatedJournalFlush
    case afterBackupCreatedJournalFlush
    case beforeActivationRename
    case afterActivationRenameBeforeDirectorySync
    case afterActivationRename
    case beforeTargetActivatedJournalFlush
    case afterTargetActivatedJournalFlush
    case beforeCompletedJournalFlush
    case afterCompletedJournalFlush

    static let crashInjectionPoints: [MacTransactionFaultPoint] = [
        .beforePreparedJournalFlush,
        .afterPreparedJournalFlush,
        .beforeStageRename,
        .afterStageRename,
        .beforeBackupRename,
        .afterBackupRename,
        .beforeBackupCreatedJournalFlush,
        .afterBackupCreatedJournalFlush,
        .beforeActivationRename,
        .afterActivationRename,
        .beforeTargetActivatedJournalFlush,
        .afterTargetActivatedJournalFlush,
        .beforeCompletedJournalFlush,
        .afterCompletedJournalFlush,
    ]
}

protocol MacTransactionFaultInjecting: AnyObject {
    func hit(_ point: MacTransactionFaultPoint) throws
}

final class NoMacTransactionFaultInjector: MacTransactionFaultInjecting {
    func hit(_: MacTransactionFaultPoint) throws {}
}

enum MacFileTransactionResult: Equatable {
    case completed
}

enum MacFileTransactionError: Error, Equatable {
    case invalidPathOrTransaction
    case targetParentChanged
    case stageIdentityChanged
    case stagePayloadChanged
    case targetIdentityChanged
    case crossVolumeStage
    case derivedArtifactAlreadyExists
    case filesystemOperationFailed
    case injectedFailure(MacTransactionFaultPoint)
}

final class MacFileTransaction {
    let paths: MacTransactionPaths
    private let directory: MacTransactionDirectory
    private let stageURL: URL
    private let stageName: String
    private let ownerProcessIdentifier: Int32
    private let expectedPayloadIdentity: MacVerifiedPayloadIdentity
    private let verifier: any MacInstallPayloadVerifying
    private let faultInjector: any MacTransactionFaultInjecting
    private let store: DurableTransactionJournalStore
    private let retainedStage: MacRetainedFileObject
    private let initialStageIdentity: MacFileIdentity
    private let targetIdentity: MacFileIdentity

    init(
        targetURL: URL,
        stageURL: URL,
        transactionID: String,
        ownerProcessIdentifier: Int32,
        expectedPayloadIdentity: MacVerifiedPayloadIdentity,
        verifier: any MacInstallPayloadVerifying,
        faultInjector: any MacTransactionFaultInjecting =
            NoMacTransactionFaultInjector()
    ) throws {
        let target = targetURL.standardizedFileURL
        let stage = stageURL.standardizedFileURL
        let targetParent = target.deletingLastPathComponent()
        let stageParent = stage.deletingLastPathComponent()
        guard targetParent.resolvingSymlinksInPath()
            == stageParent.resolvingSymlinksInPath(),
            stage.lastPathComponent != target.lastPathComponent else {
            throw MacFileTransactionError.invalidPathOrTransaction
        }
        paths = try MacTransactionPaths(
            targetName: target.lastPathComponent,
            transactionID: transactionID
        )
        directory = try MacTransactionDirectory(url: targetParent)
        self.stageURL = stage
        stageName = stage.lastPathComponent
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.expectedPayloadIdentity = expectedPayloadIdentity
        self.verifier = verifier
        self.faultInjector = faultInjector
        store = DurableTransactionJournalStore(
            directory: directory,
            paths: paths,
            faultInjector: faultInjector
        )

        targetIdentity = try directory.identity(
            name: paths.targetName,
            rejectSymbolicLink: true
        )
        retainedStage = try MacRetainedFileObject(
            directory: directory,
            name: stageName
        )
        initialStageIdentity = retainedStage.identity
        try Self.validateSameVolume(
            targetDevice: targetIdentity.device,
            stageDevice: initialStageIdentity.device
        )
        guard try verifier.verifyPayload(at: stage)
            == expectedPayloadIdentity else {
            throw MacFileTransactionError.stagePayloadChanged
        }
        for name in [
            paths.preparedName,
            paths.backupName,
            paths.journalName,
            paths.journalName + ".next",
            paths.lockName,
        ] where directory.exists(name: name) {
            throw MacFileTransactionError.derivedArtifactAlreadyExists
        }
    }

    func execute() throws -> MacFileTransactionResult {
        try directory.validatePathIdentity()
        guard try directory.identity(
            name: stageName,
            rejectSymbolicLink: true
        ) == initialStageIdentity else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        guard try verifier.verifyPayload(at: stageURL)
            == expectedPayloadIdentity else {
            throw MacFileTransactionError.stagePayloadChanged
        }

        var journal = MacTransactionJournal(
            transactionID: paths.transactionID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            targetName: paths.targetName,
            originalStageName: stageName,
            preparedName: paths.preparedName,
            backupName: paths.backupName,
            parentIdentity: directory.identity,
            targetIdentity: targetIdentity,
            stageIdentity: initialStageIdentity,
            expectedPayloadIdentity: expectedPayloadIdentity,
            state: .prepared
        )
        try store.persist(journal)
        guard try directory.identity(
            name: stageName,
            rejectSymbolicLink: true
        ) == initialStageIdentity,
            try verifier.verifyPayload(at: stageURL)
                == expectedPayloadIdentity else {
            throw MacFileTransactionError.stagePayloadChanged
        }
        try durableRename(
            from: stageName,
            to: paths.preparedName,
            before: .beforeStageRename,
            beforeSync: .afterStageRenameBeforeDirectorySync,
            after: .afterStageRename
        )

        try directory.validatePathIdentity()
        guard try directory.identity(
            name: paths.targetName,
            rejectSymbolicLink: true
        ) == targetIdentity else {
            throw MacFileTransactionError.targetIdentityChanged
        }
        try durableRename(
            from: paths.targetName,
            to: paths.backupName,
            before: .beforeBackupRename,
            beforeSync: .afterBackupRenameBeforeDirectorySync,
            after: .afterBackupRename
        )
        journal.state = .backupCreated
        try store.persist(journal)

        guard try directory.identity(
            name: paths.preparedName,
            rejectSymbolicLink: true
        ) == initialStageIdentity,
            try verifier.verifyPayload(
                at: directory.url.appendingPathComponent(paths.preparedName)
            ) == expectedPayloadIdentity else {
            throw MacFileTransactionError.stagePayloadChanged
        }
        try durableRename(
            from: paths.preparedName,
            to: paths.targetName,
            before: .beforeActivationRename,
            beforeSync: .afterActivationRenameBeforeDirectorySync,
            after: .afterActivationRename
        )
        journal.state = .targetActivated
        try store.persist(journal)

        guard try verifier.verifyPayload(
            at: directory.url.appendingPathComponent(paths.targetName)
        ) == expectedPayloadIdentity else {
            throw MacFileTransactionError.stagePayloadChanged
        }
        journal.state = .completed
        try store.persist(journal)
        try directory.removeTree(
            name: paths.backupName,
            expectedIdentity: targetIdentity
        )
        try store.remove()
        return .completed
    }

    static func validateSameVolume(
        targetDevice: UInt64,
        stageDevice: UInt64
    ) throws {
        guard targetDevice == stageDevice else {
            throw MacFileTransactionError.crossVolumeStage
        }
    }

    private func durableRename(
        from source: String,
        to destination: String,
        before: MacTransactionFaultPoint,
        beforeSync: MacTransactionFaultPoint,
        after: MacTransactionFaultPoint
    ) throws {
        try faultInjector.hit(before)
        try directory.renameExclusively(from: source, to: destination)
        try faultInjector.hit(beforeSync)
        try directory.sync()
        try faultInjector.hit(after)
    }
}

final class MacRetainedFileObject {
    let identity: MacFileIdentity
    private let descriptor: Int32

    init(directory: MacTransactionDirectory, name: String) throws {
        descriptor = name.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            _ = Darwin.close(descriptor)
            throw MacFileTransactionError.stageIdentityChanged
        }
        identity = MacFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode & mode_t(UInt16.max))
        )
        guard !identity.isSymbolicLink else {
            _ = Darwin.close(descriptor)
            throw MacFileTransactionError.stageIdentityChanged
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
    }
}

final class MacTransactionDirectory {
    let url: URL
    let identity: MacFileIdentity
    let fileDescriptor: Int32

    init(url: URL) throws {
        self.url = url.standardizedFileURL
        fileDescriptor = self.url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        do {
            identity = try Self.identity(descriptor: fileDescriptor)
            try validatePathIdentity()
        } catch {
            _ = Darwin.close(fileDescriptor)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
    }

    func validatePathIdentity() throws {
        var value = stat()
        guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0,
              Self.from(value) == identity,
              (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw MacFileTransactionError.targetParentChanged
        }
    }

    func identity(
        name: String,
        rejectSymbolicLink: Bool
    ) throws -> MacFileIdentity {
        var value = stat()
        let status = name.withCString {
            Darwin.fstatat(fileDescriptor, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        let result = Self.from(value)
        if rejectSymbolicLink, result.isSymbolicLink {
            throw MacFileTransactionError.stageIdentityChanged
        }
        return result
    }

    func exists(name: String) -> Bool {
        var value = stat()
        return name.withCString {
            Darwin.fstatat(fileDescriptor, $0, &value, AT_SYMLINK_NOFOLLOW)
        } == 0
    }

    func renameExclusively(from source: String, to destination: String) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.renameatx_np(
                    fileDescriptor,
                    sourcePointer,
                    fileDescriptor,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
    }

    func sync() throws {
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
    }

    func removeTree(
        name: String,
        expectedIdentity: MacFileIdentity
    ) throws {
        try validatePathIdentity()
        guard try identity(name: name, rejectSymbolicLink: true)
            == expectedIdentity else {
            throw MacFileTransactionError.targetIdentityChanged
        }
        do {
            let status = name.withCString {
                macRemoveFileAt(
                    fileDescriptor,
                    $0,
                    nil,
                    macRemoveFileRecursive
                )
            }
            guard status == 0 else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
            try sync()
        } catch let error as MacFileTransactionError {
            throw error
        } catch {
            throw MacFileTransactionError.filesystemOperationFailed
        }
    }

    private static func identity(descriptor: Int32) throws -> MacFileIdentity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        return from(value)
    }

    private static func from(_ value: stat) -> MacFileIdentity {
        MacFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode & mode_t(UInt16.max))
        )
    }
}
