import Darwin
import Foundation

final class MacCommitAuthorizationStore {
    private let directory: MacTransactionDirectory
    private let paths: MacTransactionPaths

    init(directory: MacTransactionDirectory, paths: MacTransactionPaths) {
        self.directory = directory
        self.paths = paths
    }

    func create(journalSHA256: String) throws {
        let data = try encoded(journalSHA256: journalSHA256)
        if directory.exists(name: paths.commitAuthorizationName) {
            guard try read() == data else {
                throw MacFileTransactionError.invalidState
            }
            return
        }
        let descriptor = paths.commitAuthorizationName.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        var isOpen = true
        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0,
                  Darwin.close(descriptor) == 0 else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
            isOpen = false
            try directory.sync()
        } catch {
            if isOpen { _ = Darwin.close(descriptor) }
            _ = paths.commitAuthorizationName.withCString {
                Darwin.unlinkat(directory.fileDescriptor, $0, 0)
            }
            try? directory.sync()
            throw error
        }
    }

    func validates(journalSHA256: String) throws -> Bool {
        guard directory.exists(name: paths.commitAuthorizationName) else {
            return false
        }
        return try read() == encoded(journalSHA256: journalSHA256)
    }

    func removeIfPresent() throws {
        guard directory.exists(name: paths.commitAuthorizationName) else {
            return
        }
        let identity = try directory.identity(
            name: paths.commitAuthorizationName,
            rejectSymbolicLink: true
        )
        try directory.removeFile(
            name: paths.commitAuthorizationName,
            expectedIdentity: identity
        )
    }

    func validatedOrphanJournalSHA256() throws -> String {
        let value = try readValidatedOrphan()
        return value.journalSHA256
    }

    func removeValidatedOrphan(expectedJournalSHA256: String) throws {
        let value = try readValidatedOrphan()
        guard value.journalSHA256 == expectedJournalSHA256 else {
            throw MacFileTransactionError.invalidState
        }
        try directory.removeFile(
            name: paths.commitAuthorizationName,
            expectedIdentity: value.identity
        )
    }

    private func encoded(journalSHA256: String) throws -> Data {
        guard journalSHA256.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil else {
            throw MacFileTransactionError.invalidState
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "journalSha256": journalSHA256,
                "transactionId": paths.transactionID,
            ],
            options: [.sortedKeys]
        )
    }

    private func read() throws -> Data {
        try readWithIdentity().data
    }

    private func readValidatedOrphan() throws -> (
        journalSHA256: String,
        identity: MacFileIdentity
    ) {
        let value = try readWithIdentity()
        let permissions = value.identity.mode & 0o7777
        guard value.identity.mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            value.identity.userIdentifier == Darwin.geteuid(),
            permissions == 0o600,
            let object = try JSONSerialization.jsonObject(with: value.data)
                as? [String: Any],
            Set(object.keys) == ["journalSha256", "transactionId"],
            let journalSHA256 = object["journalSha256"] as? String,
            journalSHA256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil,
            object["transactionId"] as? String == paths.transactionID,
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ) == value.data
        else {
            throw MacFileTransactionError.invalidState
        }
        return (journalSHA256, value.identity)
    }

    private func readWithIdentity() throws -> (
        data: Data,
        identity: MacFileIdentity
    ) {
        let descriptor = paths.commitAuthorizationName.withCString {
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
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw MacFileTransactionError.filesystemOperationFailed
        }
        let identity = MacFileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            mode: UInt16(metadata.st_mode & mode_t(UInt16.max)),
            userIdentifier: metadata.st_uid,
            groupIdentifier: metadata.st_gid
        )
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return (result, identity) }
            guard count > 0 else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
            result.append(buffer, count: count)
            guard result.count <= 512 else {
                throw MacFileTransactionError.filesystemOperationFailed
            }
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
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
                    throw MacFileTransactionError.filesystemOperationFailed
                }
                offset += count
            }
        }
    }
}
