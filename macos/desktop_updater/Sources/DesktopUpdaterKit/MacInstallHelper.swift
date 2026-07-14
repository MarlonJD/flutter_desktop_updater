import Foundation

struct MacInstallTarget: Sendable {
    let processIdentifier: Int32
    let bundleURL: URL
}

typealias MacInstallTargetResolver = @Sendable () -> MacInstallTarget

#if !SWIFT_PACKAGE
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
        self.helperEndpointIdentitySHA256 =
            helperEndpointIdentitySHA256
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
    }
}

private enum HelperProtocolValidation {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character)
        }
    }

    static func isTransactionID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func isReadyToken(_ value: String) -> Bool {
        value.count >= 43 && value.count <= 128 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}

public enum InstallTransactionState: Int {
    case unknown = 0
    case prepared = 1
    case commitAccepted = 2
    case completed = 3
    case cancelled = 4
    case expired = 5
    case rolledBack = 6
    case manualActionRequired = 7
}

public enum InstallTransactionResultCode: Int {
    case none = 0
    case accepted = 1
    case succeeded = 2
    case rejected = 3
    case endpointUnavailable = 4
    case authenticationFailed = 5
    case invalidResponse = 6
    case recoveryRequired = 7
}

public struct InstallTransactionStatus {
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

public enum MacInstallClientError: Error, Equatable {
    case endpointUnavailable
    case invalidTransactionID
    case invalidReservationResponse
    case inactiveReservation
}

protocol MacInstallHelperTransport: AnyObject {
    func validateEndpoint() throws

    func prepareInstall(
        request: Data,
        transactionID: String
    ) throws -> InstallReservationResponseV1

    func commitAfterExit(
        transactionID: String,
        readyToken: String
    ) throws -> InstallTransactionStatus

    func cancelReservation(
        transactionID: String,
        readyToken: String
    ) throws -> InstallTransactionStatus

    func queryTransaction(
        transactionID: String
    ) throws -> InstallTransactionStatus

    func recoverPendingInstall(
        transactionID: String
    ) throws -> InstallTransactionStatus
}

extension MacInstallHelperTransport {
    func validateEndpoint() throws {}
}

private final class PackagedMacInstallHelperTransport:
    MacInstallHelperTransport
{
    func validateEndpoint() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw MacInstallClientError.endpointUnavailable
        }
    }

    func prepareInstall(
        request _: Data,
        transactionID _: String
    ) throws -> InstallReservationResponseV1 {
        throw MacInstallClientError.endpointUnavailable
    }

    func commitAfterExit(
        transactionID _: String,
        readyToken _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }

    func cancelReservation(
        transactionID _: String,
        readyToken _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }

    func queryTransaction(
        transactionID _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }

    func recoverPendingInstall(
        transactionID _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }
}

public struct MacInstallHelper {
    private let targetResolver: MacInstallTargetResolver
    private let evidenceBuilder: any MacInstallRequestEvidenceBuilding
    private let transport: MacInstallHelperTransport

    public init() {
        targetResolver = {
            MacInstallTarget(
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                bundleURL: Bundle.main.bundleURL
            )
        }
        evidenceBuilder = SystemMacInstallRequestEvidenceBuilder()
        transport = PackagedMacInstallHelperTransport()
    }

    init(targetResolver: @escaping MacInstallTargetResolver) {
        self.targetResolver = targetResolver
        evidenceBuilder = SystemMacInstallRequestEvidenceBuilder()
        transport = PackagedMacInstallHelperTransport()
    }

    init(
        targetResolver: @escaping MacInstallTargetResolver,
        evidenceBuilder: any MacInstallRequestEvidenceBuilding =
            SystemMacInstallRequestEvidenceBuilder(),
        transport: MacInstallHelperTransport
    ) {
        self.targetResolver = targetResolver
        self.evidenceBuilder = evidenceBuilder
        self.transport = transport
    }

    public func scheduleInstallAndRelaunch(_ request: MacInstallRequest) throws {
        let reservation = try prepareInstall(request)
        _ = try commitAfterExit(reservation)
    }

    public func prepareInstall(
        _ request: MacInstallRequest
    ) throws -> MacInstallReservation {
        try validateCompleteHandoff(request)
        try transport.validateEndpoint()
        let target = targetResolver()
        let evidence = try evidenceBuilder.build(for: target)
        let transactionID = UUID().uuidString.lowercased()
        let requestData = try request.helperRequestData(
            transactionID: transactionID,
            processIdentifier: target.processIdentifier,
            bundleURL: target.bundleURL,
            evidence: evidence
        )
        let response = try transport.prepareInstall(
            request: requestData,
            transactionID: transactionID
        )
        guard response.protocolVersion == 1,
              response.transactionID == transactionID,
              HelperProtocolValidation.isReadyToken(response.readyToken),
              HelperProtocolValidation.isSHA256(response.journalSHA256),
              HelperProtocolValidation.isSHA256(
                  response.helperEndpointIdentitySHA256
              ),
              response.expiresAtUnixMilliseconds > 0 else {
            throw MacInstallClientError.invalidReservationResponse
        }
        let cancellationTransport = transport
        return MacInstallReservation(response: response) {
            _ = try? cancellationTransport.cancelReservation(
                transactionID: response.transactionID,
                readyToken: response.readyToken
            )
        }
    }

    public func commitAfterExit(
        _ reservation: MacInstallReservation
    ) throws -> InstallTransactionStatus {
        guard reservation.isActive else {
            throw MacInstallClientError.inactiveReservation
        }
        let status = try transport.commitAfterExit(
            transactionID: reservation.transactionID,
            readyToken: reservation.readyToken
        )
        try validate(
            status,
            transactionID: reservation.transactionID,
            reservation: reservation
        )
        guard status.state == .commitAccepted ||
            status.state == .completed else {
            throw MacInstallClientError.invalidReservationResponse
        }
        reservation.release()
        return status
    }

    public func cancelReservation(
        _ reservation: MacInstallReservation
    ) throws -> InstallTransactionStatus {
        guard reservation.isActive else {
            throw MacInstallClientError.inactiveReservation
        }
        let status = try transport.cancelReservation(
            transactionID: reservation.transactionID,
            readyToken: reservation.readyToken
        )
        try validate(
            status,
            transactionID: reservation.transactionID,
            reservation: reservation
        )
        guard status.state == .cancelled else {
            throw MacInstallClientError.invalidReservationResponse
        }
        reservation.release()
        return status
    }

    public func queryTransaction(
        _ transactionID: String
    ) throws -> InstallTransactionStatus {
        try validateTransactionID(transactionID)
        let status = try transport.queryTransaction(
            transactionID: transactionID
        )
        try validate(status, transactionID: transactionID)
        return status
    }

    public func recoverPendingInstall(
        _ transactionID: String
    ) throws -> InstallTransactionStatus {
        try validateTransactionID(transactionID)
        let status = try transport.recoverPendingInstall(
            transactionID: transactionID
        )
        try validate(status, transactionID: transactionID)
        return status
    }

    private func validateTransactionID(_ value: String) throws {
        guard HelperProtocolValidation.isTransactionID(value) else {
            throw MacInstallClientError.invalidTransactionID
        }
    }

    private func validate(
        _ status: InstallTransactionStatus,
        transactionID: String,
        reservation: MacInstallReservation? = nil
    ) throws {
        guard status.transactionID == transactionID,
              HelperProtocolValidation.isSHA256(
                  status.responseDigestSHA256
              ),
              HelperProtocolValidation.isSHA256(
                  status.helperEndpointIdentitySHA256
              ),
              reservation?.responseDigestSHA256
                  == status.responseDigestSHA256 || reservation == nil,
              reservation?.helperEndpointIdentitySHA256
                  == status.helperEndpointIdentitySHA256 || reservation == nil
        else {
            throw MacInstallClientError.invalidReservationResponse
        }
    }

    func validateCompleteHandoff(_ request: MacInstallRequest) throws {
        guard let stagingPath = request.stagingPath else { return }
        guard let root = request.stageRoot,
              !root.isEmpty,
              let expectedProvenance = request.expectedProvenanceSHA256,
              expectedProvenance.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              let artifactKind = request.artifactKind,
              !artifactKind.isEmpty,
              let expectedArtifact = request.expectedArtifactSHA256,
              expectedArtifact.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil
        else {
            throw MacInstallHelperError(
                message: "Verified stage provenance is required before scheduling.",
                path: stagingPath
            )
        }
        try validateStagingPath(stagingPath)

        let stageRoot = URL(fileURLWithPath: root).standardizedFileURL
        let staged = URL(fileURLWithPath: stagingPath).standardizedFileURL
        guard staged == stageRoot ||
            staged.deletingLastPathComponent() == stageRoot
        else {
            throw MacInstallHelperError(
                message: "Staged update is not owned by its verified stage root.",
                path: stagingPath
            )
        }
        let marker = try StageProvenance.verify(
            stageRoot: stageRoot,
            expectedMarkerSHA256: expectedProvenance
        )
        guard marker.artifactSha256 == expectedArtifact,
              marker.entries == request.provenanceEntries
        else {
            throw MacInstallHelperError(
                message: "Verified stage provenance does not match the helper request.",
                path: stagingPath
            )
        }
    }

    func validateStagingPath(_ stagingPath: String?) throws {
        guard let stagingPath else {
            return
        }
        let values: URLResourceValues
        do {
            values = try URL(fileURLWithPath: stagingPath)
                .resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        } catch {
            throw MacInstallHelperError(
                message: "Staged macOS update directory does not exist.",
                path: stagingPath
            )
        }
        if values.isSymbolicLink == true {
            throw MacInstallHelperError(
                message: "Staged macOS update must be a real .app directory, not a symlink.",
                path: stagingPath
            )
        }
        if values.isDirectory != true {
            throw MacInstallHelperError(
                message: "Staged macOS update directory does not exist.",
                path: stagingPath
            )
        }
    }

}

struct MacInstallHelperError: LocalizedError {
    let message: String
    let path: String

    var errorDescription: String? {
        return message
    }
}
