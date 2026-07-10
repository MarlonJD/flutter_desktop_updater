import Darwin
import Foundation

enum InstallTransactionState: String, Codable, CaseIterable {
    case prepared
    case backupCreated
    case targetActivated
    case completed
}

struct InstallTransactionJournal: Codable, Equatable {
    let schemaVersion: Int
    let ownerPID: Int32
    let ownerProcessStart: String
    let nonce: String
    let packageID: String
    let target: String
    let prepared: String
    let backup: String
    let stageProvenanceSHA256: String
    var state: InstallTransactionState

    init(
        ownerPID: Int32,
        ownerProcessStart: String,
        nonce: String,
        packageID: String,
        target: String,
        prepared: String,
        backup: String,
        stageProvenanceSHA256: String,
        state: InstallTransactionState
    ) {
        schemaVersion = 1
        self.ownerPID = ownerPID
        self.ownerProcessStart = ownerProcessStart
        self.nonce = nonce
        self.packageID = packageID
        self.target = target
        self.prepared = prepared
        self.backup = backup
        self.stageProvenanceSHA256 = stageProvenanceSHA256
        self.state = state
    }

    func ownsPath(_ path: String) -> Bool {
        path == target || path == prepared || path == backup
    }

    func validate(expectedTarget: String, expectedPackageID: String) throws {
        guard schemaVersion == 1,
              target == expectedTarget,
              packageID == expectedPackageID,
              ownerPID > 0,
              !ownerProcessStart.isEmpty,
              stageProvenanceSHA256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil,
              nonce.range(
                  of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                  options: .regularExpression
              ) != nil
        else {
            throw InstallTransactionError.invalidJournal
        }
        let targetURL = URL(fileURLWithPath: target).standardizedFileURL
        let parent = targetURL.deletingLastPathComponent()
        let name = targetURL.lastPathComponent
        guard targetURL.path == target,
              URL(fileURLWithPath: prepared).standardizedFileURL.path == prepared,
              URL(fileURLWithPath: backup).standardizedFileURL.path == backup,
              prepared == parent
                  .appendingPathComponent(".\(name).prepared-\(nonce)").path,
              backup == parent
                  .appendingPathComponent(".\(name).backup-\(nonce)").path
        else {
            throw InstallTransactionError.invalidJournal
        }
    }
}

enum InstallTransactionError: Error {
    case invalidJournal
    case liveOwner
    case lockExists
    case inconsistentPaths
    case durabilityFailure
}

struct InstallTransaction {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func journalURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).desktop_updater_transaction.json"
        )
    }

    func createExclusive(_ journal: InstallTransactionJournal) throws {
        try journal.validate(
            expectedTarget: journal.target,
            expectedPackageID: journal.packageID
        )
        let url = journalURL(for: URL(fileURLWithPath: journal.target))
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw InstallTransactionError.lockExists }
            throw InstallTransactionError.durabilityFailure
        }
        do {
            try write(journal, to: descriptor)
            guard fsync(descriptor) == 0, close(descriptor) == 0 else {
                throw InstallTransactionError.durabilityFailure
            }
            try syncParent(of: url)
        } catch {
            _ = close(descriptor)
            _ = unlink(url.path)
            throw error
        }
    }

    func persist(_ journal: InstallTransactionJournal) throws {
        let url = journalURL(for: URL(fileURLWithPath: journal.target))
        let temporary = url.appendingPathExtension("tmp.\(getpid())")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw InstallTransactionError.durabilityFailure
        }
        do {
            try write(journal, to: descriptor)
            guard fsync(descriptor) == 0, close(descriptor) == 0,
                  rename(temporary.path, url.path) == 0
            else {
                throw InstallTransactionError.durabilityFailure
            }
            try syncParent(of: url)
        } catch {
            _ = close(descriptor)
            _ = unlink(temporary.path)
            throw error
        }
    }

    func removeOwnedPath(
        _ path: String,
        journal: InstallTransactionJournal
    ) throws {
        guard journal.ownsPath(path) else {
            throw InstallTransactionError.invalidJournal
        }
        guard fileManager.fileExists(atPath: path) else { return }
        try fileManager.removeItem(atPath: path)
        try syncParent(of: URL(fileURLWithPath: path))
    }

    private func write(
        _ journal: InstallTransactionJournal,
        to descriptor: Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(journal)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw InstallTransactionError.durabilityFailure
                }
                offset += count
            }
        }
    }

    private func syncParent(of url: URL) throws {
        let descriptor = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw InstallTransactionError.durabilityFailure
        }
        let synced = fsync(descriptor) == 0
        let closed = close(descriptor) == 0
        guard synced, closed else {
            throw InstallTransactionError.durabilityFailure
        }
    }
}
