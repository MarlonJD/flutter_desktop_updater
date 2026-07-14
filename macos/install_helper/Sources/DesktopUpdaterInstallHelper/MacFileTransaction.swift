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
        lockName = ".\(targetName).desktop-updater-lock"
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
    case invalidState
    case targetParentChanged
    case stageIdentityChanged
    case stagePayloadChanged
    case targetIdentityChanged
    case crossVolumeStage
    case targetBusy
    case derivedArtifactAlreadyExists
    case filesystemOperationFailed
    case injectedFailure(MacTransactionFaultPoint)
}

final class MacFileTransaction {
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
    private let targetLock: MacTargetLock
    private let lifecycleLock = NSLock()
    private var lifecycle = Lifecycle.reserved

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
        ] where directory.exists(name: name) {
            throw MacFileTransactionError.derivedArtifactAlreadyExists
        }
        targetLock = try MacTargetLock(
            directory: directory,
            name: paths.lockName,
            transactionID: paths.transactionID
        )
    }

    func prepare() throws -> String {
        try transition(from: .reserved, to: .preparing)
        do {
            try validateStageBeforeMutation()
            try store.persist(initialJournal())
            let digest = try store.sha256()
            setLifecycle(.prepared)
            return digest
        } catch {
            if directory.exists(name: paths.journalName) {
                setLifecycle(.recoveryRequired)
            } else {
                try? targetLock.release()
                setLifecycle(.cancelled)
            }
            throw error
        }
    }

    func cancelPrepared() throws {
        try transition(from: .prepared, to: .preparing)
        do {
            _ = try loadPreparedJournal()
            try directory.validatePathIdentity()
            try store.remove()
            try targetLock.release()
            setLifecycle(.cancelled)
        } catch {
            setLifecycle(
                directory.exists(name: paths.journalName)
                    ? .recoveryRequired
                    : .cancelled
            )
            throw error
        }
    }

    func execute() throws -> MacFileTransactionResult {
        if currentLifecycle() == .reserved {
            _ = try prepare()
        }
        try transition(from: .prepared, to: .executing)
        do {
            try validateStageBeforeMutation()
            var journal = try loadPreparedJournal()
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
                    at: directory.url.appendingPathComponent(
                        paths.preparedName
                    )
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
            try targetLock.release()
            setLifecycle(.completed)
            return .completed
        } catch {
            if !directory.exists(name: paths.journalName) {
                try? targetLock.release()
            }
            setLifecycle(.recoveryRequired)
            throw error
        }
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

    private func initialJournal() -> MacTransactionJournal {
        MacTransactionJournal(
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
    }

    private func loadPreparedJournal() throws -> MacTransactionJournal {
        guard let journal = try store.load(),
              journal == initialJournal() else {
            throw MacFileTransactionError.invalidState
        }
        return journal
    }

    private func validateStageBeforeMutation() throws {
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

    private func setLifecycle(_ value: Lifecycle) {
        lifecycleLock.lock()
        lifecycle = value
        lifecycleLock.unlock()
    }

    private func currentLifecycle() -> Lifecycle {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return lifecycle
    }

    deinit {
        if !directory.exists(name: paths.journalName) {
            try? targetLock.release()
        }
    }
}

final class MacTargetLock {
    private let directory: MacTransactionDirectory
    private let name: String
    private let identity: MacFileIdentity
    private var descriptor: Int32
    private var isReleased = false

    init(
        directory: MacTransactionDirectory,
        name: String,
        transactionID: String
    ) throws {
        self.directory = directory
        self.name = name
        descriptor = name.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw MacFileTransactionError.targetBusy
            }
            throw MacFileTransactionError.filesystemOperationFailed
        }
        do {
            identity = try Self.identity(descriptor: descriptor)
            try Self.writeAll(
                Data((transactionID + "\n").utf8),
                to: descriptor
            )
            guard Darwin.fsync(descriptor) == 0 else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
            try directory.sync()
        } catch {
            _ = Darwin.close(descriptor)
            descriptor = -1
            _ = name.withCString {
                Darwin.unlinkat(directory.fileDescriptor, $0, 0)
            }
            try? directory.sync()
            throw error
        }
    }

    func release() throws {
        guard !isReleased else { return }
        try directory.removeFile(name: name, expectedIdentity: identity)
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            isReleased = true
            throw MacFileTransactionError.filesystemOperationFailed
        }
        descriptor = -1
        isReleased = true
    }

    static func owner(
        directory: MacTransactionDirectory,
        name: String
    ) throws -> String? {
        let descriptor = name.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        defer { _ = Darwin.close(descriptor) }
        _ = try identity(descriptor: descriptor)
        let data = try readAll(from: descriptor)
        guard let value = String(data: data, encoding: .utf8),
              value.hasSuffix("\n"),
              !value.dropLast().contains("\n") else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        return String(value.dropLast())
    }

    static func releaseExisting(
        directory: MacTransactionDirectory,
        name: String,
        transactionID: String
    ) throws {
        let descriptor = name.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        defer { _ = Darwin.close(descriptor) }
        let identity = try identity(descriptor: descriptor)
        let data = try readAll(from: descriptor)
        guard data == Data((transactionID + "\n").utf8) else {
            throw MacFileTransactionError.targetBusy
        }
        try directory.removeFile(name: name, expectedIdentity: identity)
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    private static func identity(descriptor: Int32) throws -> MacFileIdentity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        return MacFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode & mode_t(UInt16.max))
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw MacFileTransactionError.filesystemOperationFailed
                }
                offset += count
            }
        }
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 128)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            guard count > 0 else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
            result.append(buffer, count: count)
            guard result.count <= 128 else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
        }
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

    func removeFile(
        name: String,
        expectedIdentity: MacFileIdentity
    ) throws {
        try validatePathIdentity()
        guard try identity(name: name, rejectSymbolicLink: true)
            == expectedIdentity else {
            throw MacFileTransactionError.targetIdentityChanged
        }
        guard name.withCString({
            Darwin.unlinkat(fileDescriptor, $0, 0)
        }) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        try sync()
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
