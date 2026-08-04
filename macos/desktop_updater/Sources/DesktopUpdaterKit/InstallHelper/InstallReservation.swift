import Foundation

public struct InstallReservationResponseV1: Equatable {
    public let protocolVersion: Int
    public let transactionID: String
    public let readyToken: String
    public let journalSHA256: String
    public let helperEndpointIdentitySHA256: String
    public let expiresAtUnixMilliseconds: Int64

    public init(
        protocolVersion: Int,
        transactionID: String,
        readyToken: String,
        journalSHA256: String,
        helperEndpointIdentitySHA256: String,
        expiresAtUnixMilliseconds: Int64
    ) {
        self.protocolVersion = protocolVersion
        self.transactionID = transactionID
        self.readyToken = readyToken
        self.journalSHA256 = journalSHA256
        self.helperEndpointIdentitySHA256 = helperEndpointIdentitySHA256
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
    }
}

public final class InstallReservation {
    public enum State: Equatable {
        case prepared
        case commitRequested
        case cancelled
        case expired
    }

    public let response: InstallReservationResponseV1
    private let lock = NSLock()
    private var currentState: State = .prepared

    public init(response: InstallReservationResponseV1) throws {
        guard response.protocolVersion == 1,
              HelperProtocolValidation.isTransactionID(
                  response.transactionID
              ),
              HelperProtocolValidation.isReadyToken(response.readyToken),
              HelperProtocolValidation.isSHA256(response.journalSHA256),
              HelperProtocolValidation.isSHA256(
                  response.helperEndpointIdentitySHA256
              ),
              response.expiresAtUnixMilliseconds > 0 else {
            throw InstallReservationError.invalidResponse
        }
        self.response = response
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    public func requestCommit(now: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard currentState == .prepared else {
            throw InstallReservationError.invalidState
        }
        guard now <= response.expiresAtUnixMilliseconds else {
            currentState = .expired
            throw InstallReservationError.expired
        }
        currentState = .commitRequested
    }

    public func requestCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard currentState == .prepared else {
            throw InstallReservationError.invalidState
        }
        currentState = .cancelled
    }

    public func callerExitedBeforeCommit() throws {
        try requestCancellation()
    }
}

public enum InstallReservationError: Error, Equatable {
    case invalidResponse
    case invalidState
    case expired
}
