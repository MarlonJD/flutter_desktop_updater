import Foundation

enum ReservationStatus: Equatable {
    case preparing
    case prepared
    case commitRequested
    case cancelled
    case expired
}

struct ReservationRecord {
    let transactionID: String
    let targetIdentity: String
    let readyToken: String
    let callerProcessIdentifier: Int32
    let expiresAtUnixMilliseconds: Int64
    var journalSHA256: String?
    var status: ReservationStatus
}

final class ReservationStore {
    private let lock = NSLock()
    private var records: [String: ReservationRecord] = [:]
    private var targetOwners: [String: String] = [:]

    func acquire(_ request: HelperPrepareInstallRequest) throws {
        lock.lock()
        defer { lock.unlock() }
        guard records[request.transactionID] == nil else {
            throw HelperServerError.duplicateTransaction
        }
        guard targetOwners[request.targetIdentity] == nil else {
            throw HelperServerError.targetBusy
        }
        targetOwners[request.targetIdentity] = request.transactionID
        records[request.transactionID] = ReservationRecord(
            transactionID: request.transactionID,
            targetIdentity: request.targetIdentity,
            readyToken: request.readyToken,
            callerProcessIdentifier: request.callerProcessIdentifier,
            expiresAtUnixMilliseconds: request.expiresAtUnixMilliseconds,
            journalSHA256: nil,
            status: .preparing
        )
    }

    func markPrepared(transactionID: String, journalSHA256: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[transactionID],
              record.status == .preparing else {
            throw HelperServerError.invalidState
        }
        record.journalSHA256 = journalSHA256
        record.status = .prepared
        records[transactionID] = record
    }

    func abandon(transactionID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records.removeValue(forKey: transactionID) else {
            return
        }
        if targetOwners[record.targetIdentity] == transactionID {
            targetOwners.removeValue(forKey: record.targetIdentity)
        }
    }

    func commit(
        transactionID: String,
        readyToken: String,
        nowUnixMilliseconds: Int64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var record = try authenticatedRecord(
            transactionID: transactionID,
            readyToken: readyToken
        )
        guard record.status == .prepared else {
            throw HelperServerError.invalidState
        }
        if nowUnixMilliseconds > record.expiresAtUnixMilliseconds {
            record.status = .expired
            records[transactionID] = record
            releaseTarget(record)
            throw HelperServerError.expired
        }
        record.status = .commitRequested
        records[transactionID] = record
    }

    func cancel(transactionID: String, readyToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var record = try authenticatedRecord(
            transactionID: transactionID,
            readyToken: readyToken
        )
        guard record.status == .prepared else {
            throw HelperServerError.invalidState
        }
        record.status = .cancelled
        records[transactionID] = record
        releaseTarget(record)
    }

    func callerDidExit(transactionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[transactionID] else {
            throw HelperServerError.unknownTransaction
        }
        guard record.status == .prepared else {
            if record.status == .commitRequested {
                return
            }
            throw HelperServerError.invalidState
        }
        record.status = .cancelled
        records[transactionID] = record
        releaseTarget(record)
    }

    func record(transactionID: String) -> ReservationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[transactionID]
    }

    private func authenticatedRecord(
        transactionID: String,
        readyToken: String
    ) throws -> ReservationRecord {
        guard let record = records[transactionID] else {
            throw HelperServerError.unknownTransaction
        }
        guard record.readyToken == readyToken else {
            throw HelperServerError.invalidReadyToken
        }
        return record
    }

    private func releaseTarget(_ record: ReservationRecord) {
        if targetOwners[record.targetIdentity] == record.transactionID {
            targetOwners.removeValue(forKey: record.targetIdentity)
        }
    }
}
