import Darwin
import Foundation

enum MacTransactionState: String, Codable, CaseIterable {
    case prepared
    case backupCreated
    case targetActivated
    case completed
}

struct MacFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let userIdentifier: UInt32
    let groupIdentifier: UInt32

    var isSymbolicLink: Bool {
        (mode & UInt16(S_IFMT)) == UInt16(S_IFLNK)
    }
}

struct MacTransactionJournal: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let transactionID: String
    let ownerProcessIdentifier: Int32
    let targetName: String
    let originalStageName: String
    let preparedName: String
    let backupName: String
    let parentIdentity: MacFileIdentity
    let targetIdentity: MacFileIdentity
    let stageIdentity: MacFileIdentity
    let expectedPayloadIdentity: MacVerifiedPayloadIdentity
    var state: MacTransactionState

    init(
        transactionID: String,
        ownerProcessIdentifier: Int32,
        targetName: String,
        originalStageName: String,
        preparedName: String,
        backupName: String,
        parentIdentity: MacFileIdentity,
        targetIdentity: MacFileIdentity,
        stageIdentity: MacFileIdentity,
        expectedPayloadIdentity: MacVerifiedPayloadIdentity,
        state: MacTransactionState
    ) {
        schemaVersion = Self.schemaVersion
        self.transactionID = transactionID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.targetName = targetName
        self.originalStageName = originalStageName
        self.preparedName = preparedName
        self.backupName = backupName
        self.parentIdentity = parentIdentity
        self.targetIdentity = targetIdentity
        self.stageIdentity = stageIdentity
        self.expectedPayloadIdentity = expectedPayloadIdentity
        self.state = state
    }

    static func decodeStrict(_ data: Data) throws -> MacTransactionJournal {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any],
              Set(object.keys) == [
                  "schemaVersion",
                  "transactionID",
                  "ownerProcessIdentifier",
                  "targetName",
                  "originalStageName",
                  "preparedName",
                  "backupName",
                  "parentIdentity",
                  "targetIdentity",
                  "stageIdentity",
                  "expectedPayloadIdentity",
                  "state",
              ],
              exactKeys(
                  object["parentIdentity"],
                  expected: [
                      "device", "inode", "mode", "userIdentifier",
                      "groupIdentifier",
                  ]
              ),
              exactKeys(
                  object["targetIdentity"],
                  expected: [
                      "device", "inode", "mode", "userIdentifier",
                      "groupIdentifier",
                  ]
              ),
              exactKeys(
                  object["stageIdentity"],
                  expected: [
                      "device", "inode", "mode", "userIdentifier",
                      "groupIdentifier",
                  ]
              ),
              exactKeys(
                  object["expectedPayloadIdentity"],
                  expected: [
                      "packageIdentifier",
                      "designatedRequirement",
                      "bundleSHA256",
                      "provenanceSHA256",
                      "executableSHA256",
                  ]
              ),
              object["schemaVersion"] as? Int == schemaVersion else {
            throw TransactionJournalError.invalidJournal
        }
        let decoder = JSONDecoder()
        let journal = try decoder.decode(MacTransactionJournal.self, from: data)
        guard journal.schemaVersion == schemaVersion else {
            throw TransactionJournalError.invalidJournal
        }
        return journal
    }

    private static func exactKeys(
        _ value: Any?,
        expected: Set<String>
    ) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return Set(object.keys) == expected
    }
}

enum TransactionJournalError: Error, Equatable {
    case invalidJournal
    case persistenceFailed
}

final class DurableTransactionJournalStore {
    let directory: MacTransactionDirectory
    let paths: MacTransactionPaths
    private let faultInjector: any MacTransactionFaultInjecting

    init(
        directory: MacTransactionDirectory,
        paths: MacTransactionPaths,
        faultInjector: any MacTransactionFaultInjecting =
            NoMacTransactionFaultInjector()
    ) {
        self.directory = directory
        self.paths = paths
        self.faultInjector = faultInjector
    }

    func load() throws -> MacTransactionJournal? {
        let descriptor = paths.journalName.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW
            )
        }
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw TransactionJournalError.invalidJournal
        }
        defer { _ = Darwin.close(descriptor) }
        do {
            return try MacTransactionJournal.decodeStrict(
                readAll(from: descriptor)
            )
        } catch {
            throw TransactionJournalError.invalidJournal
        }
    }

    func persist(_ journal: MacTransactionJournal) throws {
        let points = faultPoints(for: journal.state)
        try faultInjector.hit(points.before)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(journal)
        } catch {
            throw TransactionJournalError.persistenceFailed
        }

        let temporaryName = paths.journalName + ".next"
        _ = temporaryName.withCString {
            Darwin.unlinkat(directory.fileDescriptor, $0, 0)
        }
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directory.fileDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw TransactionJournalError.persistenceFailed
        }
        var descriptorIsOpen = true
        do {
            try writeAll(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw TransactionJournalError.persistenceFailed
            }
            guard Darwin.close(descriptor) == 0 else {
                throw TransactionJournalError.persistenceFailed
            }
            descriptorIsOpen = false
            let renamed = temporaryName.withCString { source in
                paths.journalName.withCString { destination in
                    Darwin.renameat(
                        directory.fileDescriptor,
                        source,
                        directory.fileDescriptor,
                        destination
                    )
                }
            }
            guard renamed == 0 else {
                throw TransactionJournalError.persistenceFailed
            }
            try syncDirectory()
            try faultInjector.hit(points.after)
        } catch {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            throw error
        }
    }

    func remove() throws {
        guard directory.exists(name: paths.journalName) else {
            return
        }
        guard paths.journalName.withCString({
            Darwin.unlinkat(directory.fileDescriptor, $0, 0)
        }) == 0 else {
            throw TransactionJournalError.persistenceFailed
        }
        try syncDirectory()
    }

    func sha256() throws -> String {
        let descriptor = paths.journalName.withCString {
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
        return macPayloadSHA256(try readAll(from: descriptor))
    }

    private func faultPoints(
        for state: MacTransactionState
    ) -> (
        before: MacTransactionFaultPoint,
        after: MacTransactionFaultPoint
    ) {
        switch state {
        case .prepared:
            return (
                .beforePreparedJournalFlush,
                .afterPreparedJournalFlush
            )
        case .backupCreated:
            return (
                .beforeBackupCreatedJournalFlush,
                .afterBackupCreatedJournalFlush
            )
        case .targetActivated:
            return (
                .beforeTargetActivatedJournalFlush,
                .afterTargetActivatedJournalFlush
            )
        case .completed:
            return (
                .beforeCompletedJournalFlush,
                .afterCompletedJournalFlush
            )
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
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
                    throw TransactionJournalError.persistenceFailed
                }
                offset += count
            }
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            guard count > 0 else {
                throw TransactionJournalError.invalidJournal
            }
            result.append(buffer, count: count)
            guard result.count <= 64 * 1024 else {
                throw TransactionJournalError.invalidJournal
            }
        }
    }

    private func syncDirectory() throws {
        do {
            try directory.sync()
        } catch {
            throw TransactionJournalError.persistenceFailed
        }
    }
}
