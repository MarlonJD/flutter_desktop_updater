#if SWIFT_PACKAGE
import Foundation

/// Durable helper-owned lifecycle state for one install transaction.
public enum InstallTransactionState: Int, Sendable {
    case unknown = 0
    case prepared = 1
    case commitAccepted = 2
    case completed = 3
    case cancelled = 4
    case expired = 5
    case rolledBack = 6
    case manualActionRequired = 7
}

/// Stable result category returned by the native install helper.
public enum InstallTransactionResultCode: Int, Sendable {
    case none = 0
    case accepted = 1
    case succeeded = 2
    case rejected = 3
    case endpointUnavailable = 4
    case authenticationFailed = 5
    case invalidResponse = 6
    case recoveryRequired = 7
}

/// A validated snapshot read from the authoritative native helper.
public struct InstallTransactionStatus: Sendable {
    public let transactionID: String
    public let state: InstallTransactionState
    public let resultCode: InstallTransactionResultCode
    public let detail: String
    public let responseDigestSHA256: String
    public let helperEndpointIdentitySHA256: String

    public init(
        transactionID: String,
        state: InstallTransactionState,
        resultCode: InstallTransactionResultCode,
        detail: String,
        responseDigestSHA256: String,
        helperEndpointIdentitySHA256: String
    ) {
        self.transactionID = transactionID
        self.state = state
        self.resultCode = resultCode
        self.detail = detail
        self.responseDigestSHA256 = responseDigestSHA256
        self.helperEndpointIdentitySHA256 = helperEndpointIdentitySHA256
    }
}

/// Caller-owned lease for a durable helper reservation.
///
/// Dropping an uncommitted lease asks the helper to cancel it. The helper
/// remains authoritative if cancellation cannot be delivered.
public final class MacInstallReservation {
    public let transactionID: String
    public let readyToken: String
    public let responseDigestSHA256: String
    public let helperEndpointIdentitySHA256: String
    public let expiresAtUnixMilliseconds: Int64

    private let lock = NSLock()
    private var active = true
    private let abandon: () -> Void

    init(
        response: InstallReservationResponseV1,
        abandon: @escaping () -> Void
    ) {
        transactionID = response.transactionID
        readyToken = response.readyToken
        responseDigestSHA256 = response.journalSHA256
        helperEndpointIdentitySHA256 =
            response.helperEndpointIdentitySHA256
        expiresAtUnixMilliseconds = response.expiresAtUnixMilliseconds
        self.abandon = abandon
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func release() {
        lock.lock()
        active = false
        lock.unlock()
    }

    deinit {
        lock.lock()
        let shouldAbandon = active
        active = false
        lock.unlock()
        if shouldAbandon {
            abandon()
        }
    }
}
#endif
