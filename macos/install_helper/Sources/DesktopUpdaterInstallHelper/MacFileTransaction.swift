import CommonCrypto
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
    let commitAuthorizationName: String
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
        commitAuthorizationName = prefix + ".commit"
        lockName = ".\(targetName).desktop-updater-lock"
    }
}

enum MacTransactionFaultPoint: String, CaseIterable {
    case beforePreparingJournalFlush
    case afterPreparingJournalFlush
    case beforePreparedJournalFlush
    case afterPreparedJournalFlush
    case beforeStageRename
    case afterOwnershipRootLocked
    case beforeOwnershipEntryOpen
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
    private let stageDirectory: MacTransactionDirectory
    private let stageURL: URL
    private let stageName: String
    private let ownerProcessIdentifier: Int32
    private let expectedPayloadIdentity: MacVerifiedPayloadIdentity
    private let verifier: any MacInstallPayloadVerifying
    private let preservedTargetOwnership: MacFileOwnership?
    private let faultInjector: any MacTransactionFaultInjecting
    private let store: DurableTransactionJournalStore
    private let commitAuthorizationStore: MacCommitAuthorizationStore
    private let retainedStage: MacRetainedFileObject
    private let initialStageIdentity: MacFileIdentity
    private let targetIdentity: MacFileIdentity
    private let targetLock: MacTargetLock
    private let lifecycleLock = NSLock()
    private var lifecycle = Lifecycle.reserved
    private var preparedIdentity: MacFileIdentity?

    init(
        targetURL: URL,
        stageURL: URL,
        transactionID: String,
        ownerProcessIdentifier: Int32,
        expectedPayloadIdentity: MacVerifiedPayloadIdentity,
        verifier: any MacInstallPayloadVerifying,
        preserveTargetOwnership: Bool = false,
        faultInjector: any MacTransactionFaultInjecting =
            NoMacTransactionFaultInjector()
    ) throws {
        let target = targetURL.standardizedFileURL
        let stage = stageURL.standardizedFileURL
        let targetParent = target.deletingLastPathComponent()
        let stageParent = stage.deletingLastPathComponent()
        guard stage.lastPathComponent != target.lastPathComponent
            || targetParent.resolvingSymlinksInPath()
                != stageParent.resolvingSymlinksInPath() else {
            throw MacFileTransactionError.invalidPathOrTransaction
        }
        let transactionPaths = try MacTransactionPaths(
            targetName: target.lastPathComponent,
            transactionID: transactionID
        )
        paths = transactionPaths
        let transactionDirectory = try MacTransactionDirectory(
            url: targetParent
        )
        directory = transactionDirectory
        let transactionStageDirectory = try MacTransactionDirectory(
            url: stageParent
        )
        stageDirectory = transactionStageDirectory
        self.stageURL = stage
        stageName = stage.lastPathComponent
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.expectedPayloadIdentity = expectedPayloadIdentity
        self.verifier = verifier
        self.faultInjector = faultInjector
        let journalStore = DurableTransactionJournalStore(
            directory: transactionDirectory,
            paths: transactionPaths,
            faultInjector: faultInjector
        )
        store = journalStore
        commitAuthorizationStore = MacCommitAuthorizationStore(
            directory: transactionDirectory,
            paths: transactionPaths
        )

        let initialTargetIdentity = try transactionDirectory.identity(
            name: transactionPaths.targetName,
            rejectSymbolicLink: true
        )
        targetIdentity = initialTargetIdentity
        preservedTargetOwnership = preserveTargetOwnership
            ? MacFileOwnership(
                userIdentifier: initialTargetIdentity.userIdentifier,
                groupIdentifier: initialTargetIdentity.groupIdentifier
            )
            : nil
        let retainedStageObject = try MacRetainedFileObject(
            directory: transactionStageDirectory,
            name: stage.lastPathComponent
        )
        retainedStage = retainedStageObject
        let stageIdentity = retainedStageObject.identity
        initialStageIdentity = stageIdentity
        try Self.validateSameVolume(
            targetDevice: initialTargetIdentity.device,
            stageDevice: stageIdentity.device
        )
        guard try verifier.verifyPayload(at: stage)
            == expectedPayloadIdentity else {
            throw MacFileTransactionError.stagePayloadChanged
        }
        for name in [
            transactionPaths.preparedName,
            transactionPaths.backupName,
            transactionPaths.journalName,
            transactionPaths.journalName + ".next",
            transactionPaths.commitAuthorizationName,
        ] where transactionDirectory.exists(name: name) {
            throw MacFileTransactionError.derivedArtifactAlreadyExists
        }
        try journalStore.persist(
            MacTransactionJournal(
                transactionID: transactionPaths.transactionID,
                ownerProcessIdentifier: ownerProcessIdentifier,
                targetName: transactionPaths.targetName,
                originalStageName: stage.lastPathComponent,
                preparedName: transactionPaths.preparedName,
                backupName: transactionPaths.backupName,
                parentIdentity: transactionDirectory.identity,
                targetIdentity: initialTargetIdentity,
                stageIdentity: stageIdentity,
                expectedPayloadIdentity: expectedPayloadIdentity,
                state: .preparing
            )
        )
        do {
            targetLock = try MacTargetLock(
                directory: transactionDirectory,
                name: transactionPaths.lockName,
                transactionID: transactionPaths.transactionID
            )
        } catch {
            do {
                try journalStore.remove()
            } catch {
                throw MacFileTransactionError.filesystemOperationFailed
            }
            throw error
        }
    }

    func prepare() throws -> String {
        try transition(from: .reserved, to: .preparing)
        do {
            try validateStageBeforeMutation()
            try copyStageToPreparedSibling()
            let copiedIdentity = try directory.identity(
                name: paths.preparedName,
                rejectSymbolicLink: true
            )
            guard try verifier.verifyPayload(
                at: directory.url.appendingPathComponent(
                    paths.preparedName
                )
            ) == expectedPayloadIdentity else {
                throw MacFileTransactionError.stagePayloadChanged
            }
            preparedIdentity = copiedIdentity
            try store.persist(initialJournal(stageIdentity: copiedIdentity))
            let digest = try store.sha256()
            setLifecycle(.prepared)
            return digest
        } catch {
            if directory.exists(name: paths.journalName) {
                setLifecycle(.recoveryRequired)
            } else {
                try? removePreparedSiblingIfPresent()
                try? targetLock.release()
                setLifecycle(.cancelled)
            }
            throw error
        }
    }

    func cancelPrepared() throws {
        try transition(from: .prepared, to: .preparing)
        do {
            let journal = try loadPreparedJournal()
            try commitAuthorizationStore.removeIfPresent()
            try directory.validatePathIdentity()
            if directory.exists(name: paths.preparedName) {
                try directory.removeTree(
                    name: paths.preparedName,
                    expectedIdentity: journal.stageIdentity
                )
            }
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
        try authorizeCommit()
        try transition(from: .prepared, to: .executing)
        do {
            var journal = try loadPreparedJournal()
            guard try directory.identity(
                name: paths.preparedName,
                rejectSymbolicLink: true
            ) == journal.stageIdentity,
                try verifier.verifyPayload(
                    at: directory.url.appendingPathComponent(
                        paths.preparedName
                    )
                )
                    == expectedPayloadIdentity else {
                throw MacFileTransactionError.stagePayloadChanged
            }

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
            ) == journal.stageIdentity,
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
            try commitAuthorizationStore.removeIfPresent()
            try targetLock.release()
            try? stageDirectory.removeTree(
                name: stageName,
                expectedIdentity: initialStageIdentity
            )
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

    func authorizeCommit() throws {
        guard currentLifecycle() == .prepared else {
            throw MacFileTransactionError.invalidState
        }
        try commitAuthorizationStore.create(
            journalSHA256: store.sha256()
        )
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

    private func initialJournal(
        stageIdentity: MacFileIdentity
    ) -> MacTransactionJournal {
        MacTransactionJournal(
            transactionID: paths.transactionID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            targetName: paths.targetName,
            originalStageName: paths.preparedName,
            preparedName: paths.preparedName,
            backupName: paths.backupName,
            parentIdentity: directory.identity,
            targetIdentity: targetIdentity,
            stageIdentity: stageIdentity,
            expectedPayloadIdentity: expectedPayloadIdentity,
            state: .prepared
        )
    }

    private func loadPreparedJournal() throws -> MacTransactionJournal {
        guard let preparedIdentity,
              let journal = try store.load(),
              journal == initialJournal(stageIdentity: preparedIdentity) else {
            throw MacFileTransactionError.invalidState
        }
        return journal
    }

    private func validateStageBeforeMutation() throws {
        try directory.validatePathIdentity()
        try stageDirectory.validatePathIdentity()
        guard try stageDirectory.identity(
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

    private func copyStageToPreparedSibling() throws {
        try faultInjector.hit(.beforeStageRename)
        try directory.validatePathIdentity()
        try stageDirectory.validatePathIdentity()
        let destination = directory.url.appendingPathComponent(
            paths.preparedName
        )
        let contentFlags = preservedTargetOwnership == nil
            ? COPYFILE_ALL
            : COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA
        let flags = copyfile_flags_t(
            contentFlags | COPYFILE_RECURSIVE | COPYFILE_EXCL
                | COPYFILE_NOFOLLOW
        )
        guard stageURL.path.withCString({ source in
            destination.path.withCString { target in
                copyfile(source, target, nil, flags)
            }
        }) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        if let preservedTargetOwnership {
            try directory.normalizeTreeOwnership(
                name: paths.preparedName,
                ownership: preservedTargetOwnership,
                faultInjector: faultInjector
            )
        }
        try faultInjector.hit(.afterStageRenameBeforeDirectorySync)
        try directory.sync()
        try faultInjector.hit(.afterStageRename)
        try directory.validatePathIdentity()
        try stageDirectory.validatePathIdentity()
    }

    private func removePreparedSiblingIfPresent() throws {
        guard directory.exists(name: paths.preparedName) else { return }
        let identity = try directory.identity(
            name: paths.preparedName,
            rejectSymbolicLink: true
        )
        try directory.removeTree(
            name: paths.preparedName,
            expectedIdentity: identity
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

struct MacFileOwnership: Equatable {
    let userIdentifier: uid_t
    let groupIdentifier: gid_t
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
            mode: UInt16(value.st_mode & mode_t(UInt16.max)),
            userIdentifier: value.st_uid,
            groupIdentifier: value.st_gid
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
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
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
            mode: UInt16(value.st_mode & mode_t(UInt16.max)),
            userIdentifier: value.st_uid,
            groupIdentifier: value.st_gid
        )
        guard !identity.isSymbolicLink else {
            _ = Darwin.close(descriptor)
            throw MacFileTransactionError.stageIdentityChanged
        }
    }

    func copyContents(to destination: Int32, expectedLength: Int64) throws {
        guard expectedLength > 0,
              currentLength() == expectedLength else {
            throw MacVerifiedInstallerProtectedStageError.copyFailed
        }
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < expectedLength {
            let remaining = expectedLength - offset
            let count = Darwin.pread(
                descriptor,
                &buffer,
                min(buffer.count, Int(remaining)),
                offset
            )
            guard count > 0 else {
                throw MacVerifiedInstallerProtectedStageError.copyFailed
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                guard result > 0 else {
                    throw MacVerifiedInstallerProtectedStageError.copyFailed
                }
                written += result
            }
            offset += off_t(count)
        }
        var extra: UInt8 = 0
        guard Darwin.pread(descriptor, &extra, 1, offset) == 0,
              currentLength() == expectedLength else {
            throw MacVerifiedInstallerProtectedStageError.copyFailed
        }
    }

    func readData(
        maximumLength: Int64,
        expectedLength: Int64? = nil
    ) throws -> Data {
        let length = try validatedLength(
            maximumLength: maximumLength,
            expectedLength: expectedLength
        )
        guard length <= Int64(Int.max) else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        var result = Data()
        result.reserveCapacity(Int(length))
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < length {
            let remaining = length - offset
            let count = Darwin.pread(
                descriptor,
                &buffer,
                min(buffer.count, Int(remaining)),
                offset
            )
            guard count > 0 else {
                throw MacFileTransactionError.stageIdentityChanged
            }
            result.append(buffer, count: count)
            offset += off_t(count)
        }
        try validateEnd(offset: offset, expectedLength: length)
        return result
    }

    func sha256(expectedLength: Int64) throws -> String {
        let length = try validatedLength(
            maximumLength: expectedLength,
            expectedLength: expectedLength
        )
        var context = CC_SHA256_CTX()
        _ = CC_SHA256_Init(&context)
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < length {
            let remaining = length - offset
            let count = Darwin.pread(
                descriptor,
                &buffer,
                min(buffer.count, Int(remaining)),
                offset
            )
            guard count > 0 else {
                throw MacFileTransactionError.stageIdentityChanged
            }
            buffer.withUnsafeBytes { bytes in
                _ = CC_SHA256_Update(
                    &context,
                    bytes.baseAddress,
                    CC_LONG(count)
                )
            }
            offset += off_t(count)
        }
        try validateEnd(offset: offset, expectedLength: length)
        var digest = [UInt8](
            repeating: 0,
            count: Int(CC_SHA256_DIGEST_LENGTH)
        )
        _ = CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func length(maximumLength: Int64) throws -> Int64 {
        try validatedLength(
            maximumLength: maximumLength,
            expectedLength: nil
        )
    }

    func rootOwnedBundleFileMode() throws -> UInt16 {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              value.st_dev == dev_t(identity.device),
              value.st_ino == ino_t(identity.inode),
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        let mode = value.st_mode & mode_t(0o7777)
        guard value.st_flags == 0,
              mode & 0o7000 == 0,
              mode & 0o022 == 0,
              mode & 0o004 == 0o004,
              (mode & 0o111 == 0 || mode & 0o101 == 0o101) else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        return UInt16(mode)
    }

    private func validatedLength(
        maximumLength: Int64,
        expectedLength: Int64?
    ) throws -> Int64 {
        var value = stat()
        guard maximumLength >= 0,
              Darwin.fstat(descriptor, &value) == 0,
              value.st_dev == dev_t(identity.device),
              value.st_ino == ino_t(identity.inode),
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_size >= 0,
              value.st_size <= maximumLength,
              expectedLength.map({ value.st_size == $0 }) ?? true else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        return value.st_size
    }

    private func validateEnd(
        offset: off_t,
        expectedLength: Int64
    ) throws {
        var extra: UInt8 = 0
        guard offset == expectedLength,
              Darwin.pread(descriptor, &extra, 1, offset) == 0,
              currentLength() == expectedLength else {
            throw MacFileTransactionError.stageIdentityChanged
        }
    }

    private func currentLength() -> Int64? {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              value.st_size >= 0 else {
            return nil
        }
        return value.st_size
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
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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

    func normalizeTreeOwnership(
        name: String,
        ownership: MacFileOwnership,
        faultInjector: any MacTransactionFaultInjecting =
            NoMacTransactionFaultInjector()
    ) throws {
        try validatePathIdentity()
        let initialIdentity = try identity(
            name: name,
            rejectSymbolicLink: true
        )
        let rootDescriptor = name.withCString {
            Darwin.openat(
                fileDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        defer { _ = Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0,
              Self.from(rootStatus) == initialIdentity else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        try normalizeDirectoryOwnership(
            descriptor: rootDescriptor,
            originalStatus: rootStatus,
            ownership: ownership,
            faultInjector: faultInjector,
            isRoot: true
        )
        guard Self.sameNode(
            initialIdentity,
            try identity(name: name, rejectSymbolicLink: true)
        ) else {
            throw MacFileTransactionError.stageIdentityChanged
        }
        try validatePathIdentity()
    }

    private func normalizeDirectoryOwnership(
        descriptor: Int32,
        originalStatus: stat,
        ownership: MacFileOwnership,
        faultInjector: any MacTransactionFaultInjecting,
        isRoot: Bool
    ) throws {
        let originalMode = originalStatus.st_mode & mode_t(0o7777)
        guard originalStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              Darwin.fchflags(descriptor, 0) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        var unlockedStatus = stat()
        guard Darwin.fstat(descriptor, &unlockedStatus) == 0,
              Self.sameNode(originalStatus, unlockedStatus),
              unlockedStatus.st_flags == 0,
              originalMode & 0o7000 == 0,
              originalMode & 0o022 == 0,
              originalMode & 0o005 == 0o005,
              Darwin.fchown(
                  descriptor,
                  Darwin.geteuid(),
                  Darwin.getegid()
              ) == 0,
              Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        if isRoot {
            try faultInjector.hit(.afterOwnershipRootLocked)
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw MacFileTransactionError.filesystemOperationFailed
        }
        defer { _ = Darwin.closedir(stream) }
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let entryName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if entryName == "." || entryName == ".." { continue }
            var before = stat()
            let status = entryName.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &before,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            let kind = before.st_mode & mode_t(S_IFMT)
            let mode = before.st_mode & mode_t(0o7777)
            guard status == 0,
                  kind == mode_t(S_IFDIR)
                    || kind == mode_t(S_IFREG)
                    || kind == mode_t(S_IFLNK) else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
            try faultInjector.hit(.beforeOwnershipEntryOpen)
            switch kind {
            case mode_t(S_IFDIR):
                let child = entryName.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                defer { _ = Darwin.close(child) }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      Self.sameNode(before, opened) else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                try normalizeDirectoryOwnership(
                    descriptor: child,
                    originalStatus: opened,
                    ownership: ownership,
                    faultInjector: faultInjector,
                    isRoot: false
                )
            case mode_t(S_IFREG):
                let child = entryName.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                defer { _ = Darwin.close(child) }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      Self.sameNode(before, opened),
                      Darwin.fchflags(child, 0) == 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                var unlocked = stat()
                guard Darwin.fstat(child, &unlocked) == 0,
                      Self.sameNode(opened, unlocked),
                      unlocked.st_flags == 0,
                      mode & 0o7000 == 0,
                      mode & 0o022 == 0,
                      mode & 0o004 == 0o004,
                      (mode & 0o111 == 0 || mode & 0o101 == 0o101),
                      Darwin.fchown(
                          child,
                          ownership.userIdentifier,
                          ownership.groupIdentifier
                      ) == 0,
                      Darwin.fchmod(child, mode) == 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                try Self.validateNormalizedNode(
                    descriptor: child,
                    identity: opened,
                    mode: mode,
                    ownership: ownership
                )
            case mode_t(S_IFLNK):
                let child = entryName.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_SYMLINK | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                defer { _ = Darwin.close(child) }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      Self.sameNode(before, opened),
                      Darwin.fchflags(child, 0) == 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                var unlocked = stat()
                guard Darwin.fstat(child, &unlocked) == 0,
                      Self.sameNode(opened, unlocked),
                      unlocked.st_flags == 0,
                      mode & 0o7000 == 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
                guard entryName.withCString({
                    Darwin.fchownat(
                        descriptor,
                        $0,
                        ownership.userIdentifier,
                        ownership.groupIdentifier,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0 else {
                    throw MacFileTransactionError.filesystemOperationFailed
                }
                var after = stat()
                guard entryName.withCString({
                    Darwin.fstatat(
                        descriptor,
                        $0,
                        &after,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0,
                    Self.sameNode(before, after),
                    after.st_uid == ownership.userIdentifier,
                    after.st_gid == ownership.groupIdentifier,
                    after.st_flags == 0 else {
                    throw MacFileTransactionError.stageIdentityChanged
                }
            default:
                throw MacFileTransactionError.filesystemOperationFailed
            }
            errno = 0
        }
        guard errno == 0,
              Darwin.fchown(
                  descriptor,
                  ownership.userIdentifier,
                  ownership.groupIdentifier
              ) == 0,
              Darwin.fchmod(descriptor, originalMode) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        try Self.validateNormalizedNode(
            descriptor: descriptor,
            identity: originalStatus,
            mode: originalMode,
            ownership: ownership
        )
    }

    private static func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & mode_t(S_IFMT) == rhs.st_mode & mode_t(S_IFMT)
    }

    private static func sameNode(
        _ lhs: MacFileIdentity,
        _ rhs: MacFileIdentity
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.mode & UInt16(S_IFMT) == rhs.mode & UInt16(S_IFMT)
    }

    private static func validateNormalizedNode(
        descriptor: Int32,
        identity: stat,
        mode: mode_t,
        ownership: MacFileOwnership
    ) throws {
        var current = stat()
        guard Darwin.fstat(descriptor, &current) == 0,
              sameNode(identity, current),
              current.st_uid == ownership.userIdentifier,
              current.st_gid == ownership.groupIdentifier,
              current.st_mode & mode_t(0o7777) == mode,
              current.st_flags == 0 else {
            throw MacFileTransactionError.stageIdentityChanged
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
            mode: UInt16(value.st_mode & mode_t(UInt16.max)),
            userIdentifier: value.st_uid,
            groupIdentifier: value.st_gid
        )
    }
}
