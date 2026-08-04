import CommonCrypto
import Darwin
import Foundation

struct HelperPrepareInstallRequest: Equatable {
    let transactionID: String
    let targetIdentity: String
    let readyToken: String
    let callerProcessIdentifier: Int32
    let expiresAtUnixMilliseconds: Int64
    let authenticatedSessionSHA256: String
}

struct HelperReservation: Equatable {
    let protocolVersion: Int
    let transactionID: String
    let readyToken: String
    let journalSHA256: String
    let expiresAtUnixMilliseconds: Int64
}

protocol InitialJournalPersisting {
    func persistInitialJournal(_ request: HelperPrepareInstallRequest) throws
        -> String
}

protocol CallerExitMonitoring {
    func startMonitoring(
        processIdentifier: Int32,
        transactionID: String
    ) throws
}

final class DurableInitialJournalPersister: InitialJournalPersisting {
    private let journalDirectoryURL: URL

    init(journalDirectoryURL: URL) {
        self.journalDirectoryURL = journalDirectoryURL.standardizedFileURL
    }

    func persistInitialJournal(_ request: HelperPrepareInstallRequest) throws
        -> String
    {
        let journal = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "transactionId": request.transactionID,
                "targetIdentity": request.targetIdentity,
                "ownerGeneration": 1,
                "state": "prepared",
            ],
            options: [.sortedKeys]
        )
        let name = ".desktop-updater-journal-\(request.transactionID).json"
        let url = journalDirectoryURL.appendingPathComponent(
            name,
            isDirectory: false
        )
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw HelperServerError.journalPersistenceFailed
        }
        defer {
            _ = Darwin.close(descriptor)
        }
        try journal.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw HelperServerError.journalPersistenceFailed
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HelperServerError.journalPersistenceFailed
        }

        let directoryDescriptor = journalDirectoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY)
        }
        guard directoryDescriptor >= 0 else {
            throw HelperServerError.journalPersistenceFailed
        }
        defer {
            _ = Darwin.close(directoryDescriptor)
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw HelperServerError.journalPersistenceFailed
        }
        return helperSHA256(journal)
    }
}

final class HelperServer {
    private let store: ReservationStore
    private let journalPersister: any InitialJournalPersisting
    private let callerMonitor: any CallerExitMonitoring

    init(
        store: ReservationStore,
        journalPersister: any InitialJournalPersisting,
        callerMonitor: any CallerExitMonitoring
    ) {
        self.store = store
        self.journalPersister = journalPersister
        self.callerMonitor = callerMonitor
    }

    func prepareInstall(
        _ request: HelperPrepareInstallRequest
    ) throws -> HelperReservation {
        try validate(request)
        try store.acquire(request)
        do {
            let journalSHA256 = try journalPersister.persistInitialJournal(
                request
            )
            guard isSHA256(journalSHA256) else {
                throw HelperServerError.invalidJournalDigest
            }
            try callerMonitor.startMonitoring(
                processIdentifier: request.callerProcessIdentifier,
                transactionID: request.transactionID
            )
            try store.markPrepared(
                transactionID: request.transactionID,
                journalSHA256: journalSHA256
            )
            return HelperReservation(
                protocolVersion: 1,
                transactionID: request.transactionID,
                readyToken: request.readyToken,
                journalSHA256: journalSHA256,
                expiresAtUnixMilliseconds: request.expiresAtUnixMilliseconds
            )
        } catch {
            store.abandon(transactionID: request.transactionID)
            throw error
        }
    }

    func commitAfterExit(
        transactionID: String,
        readyToken: String,
        nowUnixMilliseconds: Int64
    ) throws {
        try store.commit(
            transactionID: transactionID,
            readyToken: readyToken,
            nowUnixMilliseconds: nowUnixMilliseconds
        )
    }

    func cancelReservation(
        transactionID: String,
        readyToken: String
    ) throws {
        try store.cancel(
            transactionID: transactionID,
            readyToken: readyToken
        )
    }

    func callerDidExit(transactionID: String) throws {
        try store.callerDidExit(transactionID: transactionID)
    }

    func status(transactionID: String) -> ReservationStatus? {
        store.record(transactionID: transactionID)?.status
    }

    private func validate(_ request: HelperPrepareInstallRequest) throws {
        guard isTransactionID(request.transactionID),
              !request.targetIdentity.isEmpty,
              request.targetIdentity.count <= 4096,
              !request.targetIdentity.contains("\n"),
              isReadyToken(request.readyToken),
              request.callerProcessIdentifier > 0,
              request.expiresAtUnixMilliseconds > 0,
              isSHA256(request.authenticatedSessionSHA256) else {
            throw HelperServerError.unauthenticatedOrInvalidRequest
        }
    }
}

enum HelperServerError: Error, Equatable {
    case unauthenticatedOrInvalidRequest
    case targetBusy
    case duplicateTransaction
    case invalidJournalDigest
    case journalPersistenceFailed
    case invalidReadyToken
    case unknownTransaction
    case invalidState
    case expired
}

private func helperSHA256(_ data: Data) -> String {
    var context = CC_SHA256_CTX()
    _ = CC_SHA256_Init(&context)
    data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = min(bytes.count - offset, Int(CC_LONG.max))
            _ = CC_SHA256_Update(
                &context,
                baseAddress.advanced(by: offset),
                CC_LONG(count)
            )
            offset += count
        }
    }
    var digest = [UInt8](
        repeating: 0,
        count: Int(CC_SHA256_DIGEST_LENGTH)
    )
    _ = CC_SHA256_Final(&digest, &context)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
        $0.isNumber || ("a" ... "f").contains($0)
    }
}

private func isReadyToken(_ value: String) -> Bool {
    value.count >= 43 && value.count <= 128 && value.allSatisfy {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
    }
}

private func isTransactionID(_ value: String) -> Bool {
    guard value == value.lowercased(),
          let uuid = UUID(uuidString: value) else {
        return false
    }
    return uuid.uuidString.lowercased() == value
}
