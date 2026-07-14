import Foundation

protocol MacOneShotInstallAuthorizing: AnyObject {
    var helperEndpointIdentitySHA256: String { get }

    func authorize(
        _ request: NativeInstallTransactionRequestV1
    ) throws -> MacFileTransaction
}

struct MacOneShotReservationV1: Equatable {
    let protocolVersion: Int
    let transactionID: String
    let readyToken: String
    let journalSHA256: String
    let helperEndpointIdentitySHA256: String
    let expiresAtUnixMilliseconds: Int64
}

struct MacOneShotTransactionStatusV1: Equatable {
    let protocolVersion: Int
    let transactionID: String
    let state: String
    let resultCode: String
    let journalSHA256: String
    let helperEndpointIdentitySHA256: String
}

enum MacOneShotInstallError: Error, Equatable {
    case invalidState
    case invalidReadyToken
    case invalidEndpointIdentity
    case reservationBindingMismatch
    case expired
}

final class MacOneShotInstallSession {
    private enum State {
        case initial
        case preparing
        case prepared
        case commitAccepted
        case executing
        case cancelling
        case cancelled
        case completed
        case recoveryRequired
    }

    private let authorizer: any MacOneShotInstallAuthorizing
    private let readyTokenGenerator: () throws -> String
    private let nowUnixMilliseconds: () -> Int64
    private let reservationLifetimeMilliseconds: Int64
    private let lock = NSLock()
    private var state = State.initial
    private var transaction: MacFileTransaction?
    private var reservation: MacOneShotReservationV1?

    init(
        authorizer: any MacOneShotInstallAuthorizing,
        readyTokenGenerator: @escaping () throws -> String,
        nowUnixMilliseconds: @escaping () -> Int64,
        reservationLifetimeMilliseconds: Int64
    ) {
        self.authorizer = authorizer
        self.readyTokenGenerator = readyTokenGenerator
        self.nowUnixMilliseconds = nowUnixMilliseconds
        self.reservationLifetimeMilliseconds =
            reservationLifetimeMilliseconds
    }

    func prepare(requestData: Data) throws -> MacOneShotReservationV1 {
        try transition(from: .initial, to: .preparing)
        var authorized: MacFileTransaction?
        do {
            let request = try NativeInstallTransactionRequestV1.parse(
                requestData
            )
            let token = try readyTokenGenerator()
            guard Self.isReadyToken(token) else {
                throw MacOneShotInstallError.invalidReadyToken
            }
            let endpointIdentity = authorizer.helperEndpointIdentitySHA256
            guard Self.isSHA256(endpointIdentity) else {
                throw MacOneShotInstallError.invalidEndpointIdentity
            }
            let now = nowUnixMilliseconds()
            guard reservationLifetimeMilliseconds > 0,
                  now <= Int64.max - reservationLifetimeMilliseconds else {
                throw MacOneShotInstallError.expired
            }

            let transaction = try authorizer.authorize(request)
            authorized = transaction
            guard transaction.paths.transactionID == request.transactionID
            else {
                throw MacOneShotInstallError.reservationBindingMismatch
            }
            let journalSHA256 = try transaction.prepare()
            let prepared = MacOneShotReservationV1(
                protocolVersion: 1,
                transactionID: request.transactionID,
                readyToken: token,
                journalSHA256: journalSHA256,
                helperEndpointIdentitySHA256: endpointIdentity,
                expiresAtUnixMilliseconds:
                    now + reservationLifetimeMilliseconds
            )
            lock.lock()
            self.transaction = transaction
            reservation = prepared
            state = .prepared
            lock.unlock()
            return prepared
        } catch {
            setState(
                authorized == nil ? .cancelled : .recoveryRequired
            )
            throw error
        }
    }

    func acceptCommit(
        transactionID: String,
        readyToken: String,
        journalSHA256: String,
        helperEndpointIdentitySHA256: String
    ) throws -> MacOneShotTransactionStatusV1 {
        let prepared = try claimBoundReservation(
            expectedState: .prepared,
            nextState: .commitAccepted,
            transactionID: transactionID,
            readyToken: readyToken,
            journalSHA256: journalSHA256,
            helperEndpointIdentitySHA256: helperEndpointIdentitySHA256
        )
        if nowUnixMilliseconds() > prepared.expiresAtUnixMilliseconds {
            let reservedTransaction = try requiredTransaction()
            try reservedTransaction.cancelPrepared()
            setState(.cancelled)
            throw MacOneShotInstallError.expired
        }
        return status(
            reservation: prepared,
            state: "commitAccepted",
            resultCode: "accepted"
        )
    }

    func executeAfterCallerExit() throws -> MacOneShotTransactionStatusV1 {
        try transition(from: .commitAccepted, to: .executing)
        let prepared = try requiredReservation()
        do {
            _ = try requiredTransaction().execute()
            setState(.completed)
            return status(
                reservation: prepared,
                state: "completed",
                resultCode: "completed"
            )
        } catch {
            setState(.recoveryRequired)
            throw error
        }
    }

    func cancel(
        transactionID: String,
        readyToken: String,
        journalSHA256: String,
        helperEndpointIdentitySHA256: String
    ) throws -> MacOneShotTransactionStatusV1 {
        let prepared = try claimBoundReservation(
            expectedState: .prepared,
            nextState: .cancelling,
            transactionID: transactionID,
            readyToken: readyToken,
            journalSHA256: journalSHA256,
            helperEndpointIdentitySHA256: helperEndpointIdentitySHA256
        )
        do {
            try requiredTransaction().cancelPrepared()
            setState(.cancelled)
            return status(
                reservation: prepared,
                state: "cancelled",
                resultCode: "completed"
            )
        } catch {
            setState(.recoveryRequired)
            throw error
        }
    }

    private func claimBoundReservation(
        expectedState: State,
        nextState: State,
        transactionID: String,
        readyToken: String,
        journalSHA256: String,
        helperEndpointIdentitySHA256: String
    ) throws -> MacOneShotReservationV1 {
        lock.lock()
        defer { lock.unlock() }
        guard state == expectedState, let value = reservation else {
            throw MacOneShotInstallError.invalidState
        }
        guard value.transactionID == transactionID,
              value.readyToken == readyToken,
              value.journalSHA256 == journalSHA256,
              value.helperEndpointIdentitySHA256
                == helperEndpointIdentitySHA256 else {
            throw MacOneShotInstallError.reservationBindingMismatch
        }
        state = nextState
        return value
    }

    private func requiredReservation() throws -> MacOneShotReservationV1 {
        lock.lock()
        defer { lock.unlock() }
        guard let reservation else {
            throw MacOneShotInstallError.invalidState
        }
        return reservation
    }

    private func requiredTransaction() throws -> MacFileTransaction {
        lock.lock()
        defer { lock.unlock() }
        guard let transaction else {
            throw MacOneShotInstallError.invalidState
        }
        return transaction
    }

    private func requireState(_ expected: State) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == expected else {
            throw MacOneShotInstallError.invalidState
        }
    }

    private func transition(from expected: State, to next: State) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == expected else {
            throw MacOneShotInstallError.invalidState
        }
        state = next
    }

    private func setState(_ value: State) {
        lock.lock()
        state = value
        lock.unlock()
    }

    private func status(
        reservation: MacOneShotReservationV1,
        state: String,
        resultCode: String
    ) -> MacOneShotTransactionStatusV1 {
        MacOneShotTransactionStatusV1(
            protocolVersion: 1,
            transactionID: reservation.transactionID,
            state: state,
            resultCode: resultCode,
            journalSHA256: reservation.journalSHA256,
            helperEndpointIdentitySHA256:
                reservation.helperEndpointIdentitySHA256
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isNumber || ("a" ... "f").contains($0)
        }
    }

    private static func isReadyToken(_ value: String) -> Bool {
        value.count == 43 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}
