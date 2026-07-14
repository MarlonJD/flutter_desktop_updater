import CommonCrypto
import Darwin
import Dispatch
import Foundation
import Security
import ServiceManagement
import XPC

struct MacSignedExecutableIdentity: Equatable {
    var bundleIdentifier: String
    var teamIdentifier: String
    var designatedRequirement: String
    var sha256: String
    var isSignatureValid: Bool
}

protocol MacSignedExecutableIdentityChecking: AnyObject {
    func identity(
        at url: URL,
        requirement: String
    ) throws -> MacSignedExecutableIdentity

    func runningIdentity(
        auditToken: Data,
        requirement: String
    ) throws -> MacSignedExecutableIdentity
}

protocol MacPrivilegeInstalling: AnyObject {
    func install(serviceIdentifier: String) throws
}

enum MacPrivilegeInstallError: Error, Equatable {
    case authorizationCancelled
    case authorizationFailed(OSStatus)
    case invalidBlessing
}

enum MacPrivilegeError: Error, Equatable {
    case invalidConfiguration
    case invalidNestedHelperLocation
    case nestedPayloadMismatch
    case signedIdentityMismatch
    case peerAuthenticationFailed
    case peerAuthenticationUnavailable
    case privilegedServiceRequiresRoot
}

struct MacPrivilegeConfiguration: Equatable {
    let serviceIdentifier: String
    let applicationBundleIdentifier: String
    let applicationRequirement: String
    let helperRequirement: String

    static func fromSealedPolicy(
        _ data: Data,
        expectedSHA256: String
    ) throws -> MacPrivilegeConfiguration {
        guard expectedSHA256.count == 64,
              expectedSHA256.allSatisfy({
                  $0.isNumber || ("a" ... "f").contains($0)
              }),
              macPrivilegeSHA256(data) == expectedSHA256 else {
            throw MacPrivilegeError.invalidConfiguration
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MacPrivilegeError.invalidConfiguration
        }
        guard let object = value as? [String: Any],
              Set(object.keys) == [
                  "policyVersion",
                  "policyId",
                  "applicationPackageId",
                  "helperServiceId",
                  "allowedApplicationSigner",
                  "allowedHelperSigner",
                  "allowedTargetClasses",
                  "allowedInstallRoots",
                  "releaseRootPublicKeys",
                  "allowedStrategies",
                  "minimumHelperProtocolVersion",
              ],
              let serviceIdentifier = object["helperServiceId"] as? String,
              let applicationBundleIdentifier = object[
                  "applicationPackageId"
              ] as? String,
              let applicationSigner = object["allowedApplicationSigner"]
                as? [String: Any],
              let helperSigner = object["allowedHelperSigner"]
                as? [String: Any],
              Set(applicationSigner.keys) == ["kind", "value"],
              Set(helperSigner.keys) == ["kind", "value"],
              applicationSigner["kind"] as? String
                == "appleDesignatedRequirement",
              helperSigner["kind"] as? String
                == "appleDesignatedRequirement",
              let applicationRequirement = applicationSigner["value"]
                as? String,
              let helperRequirement = helperSigner["value"] as? String,
              !serviceIdentifier.isEmpty,
              !applicationBundleIdentifier.isEmpty,
              !applicationRequirement.isEmpty,
              !helperRequirement.isEmpty else {
            throw MacPrivilegeError.invalidConfiguration
        }
        return MacPrivilegeConfiguration(
            serviceIdentifier: serviceIdentifier,
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationRequirement: applicationRequirement,
            helperRequirement: helperRequirement
        )
    }

    static func fromEmbeddedInfoDictionary(
        _ info: [String: Any]
    ) throws -> MacPrivilegeConfiguration {
        guard let policy = info["DesktopUpdaterSealedPolicy"] as? Data,
              let digest = info["DesktopUpdaterSealedPolicySHA256"]
                as? String else {
            throw MacPrivilegeError.invalidConfiguration
        }
        let configuration = try fromSealedPolicy(
            policy,
            expectedSHA256: digest
        )
        guard info["CFBundleIdentifier"] as? String
            == configuration.serviceIdentifier,
            info["SMAuthorizedClients"] as? [String]
                == [configuration.applicationRequirement] else {
            throw MacPrivilegeError.invalidConfiguration
        }
        return configuration
    }

    func validatePlists(in directory: URL) throws {
        let helper = try dictionary(
            at: directory.appendingPathComponent("Helper-Info.plist")
        )
        let launchd = try dictionary(
            at: directory.appendingPathComponent("Helper-Launchd.plist")
        )
        let application = try dictionary(
            at: directory.appendingPathComponent(
                "App-SMPrivilegedExecutables.plist"
            )
        )
        guard helper["CFBundleIdentifier"] as? String == serviceIdentifier,
              helper["SMAuthorizedClients"] as? [String]
                == [applicationRequirement],
              launchd["Label"] as? String == serviceIdentifier,
              let machServices = launchd["MachServices"]
                as? [String: Bool],
              machServices == [serviceIdentifier: true],
              let arguments = launchd["ProgramArguments"] as? [String],
              arguments == [
                  "/Library/PrivilegedHelperTools/\(serviceIdentifier)"
              ],
              application as? [String: String]
                == [serviceIdentifier: helperRequirement] else {
            throw MacPrivilegeError.invalidConfiguration
        }
    }

    private func dictionary(at url: URL) throws -> [String: Any] {
        do {
            let value = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url),
                options: [],
                format: nil
            )
            guard let dictionary = value as? [String: Any] else {
                throw MacPrivilegeError.invalidConfiguration
            }
            return dictionary
        } catch let error as MacPrivilegeError {
            throw error
        } catch {
            throw MacPrivilegeError.invalidConfiguration
        }
    }
}

protocol MacPrivilegedServiceRunning: AnyObject {
    func run() throws
}

enum MacPrivilegedBootstrapEnvironment {
    static func validate(
        effectiveUserIdentifier: uid_t
    ) throws {
        guard effectiveUserIdentifier == 0 else {
            throw MacPrivilegeError.privilegedServiceRequiresRoot
        }
    }
}

enum MacXPCPeerRequirement {
    static func make(
        applicationRequirement: String,
        helperTeamIdentifier: String
    ) throws -> String {
        guard !applicationRequirement.isEmpty,
              !applicationRequirement.contains("\0"),
              !applicationRequirement.contains("\n"),
              (1 ... 64).contains(helperTeamIdentifier.count),
              helperTeamIdentifier.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.uppercaseLetters
                      .union(.decimalDigits)
                      .contains(scalar)
              }) else {
            throw MacPrivilegeError.invalidConfiguration
        }
        return "(\(applicationRequirement)) "
            + "and certificate leaf[subject.OU] = "
            + "\"\(helperTeamIdentifier)\""
    }
}

protocol MacPrivilegedInstallSessionServing: AnyObject {
    func prepare(requestData: Data) throws -> MacOneShotReservationV1

    func acceptCommit(
        transactionID: String,
        readyToken: String,
        journalSHA256: String,
        helperEndpointIdentitySHA256: String
    ) throws -> MacOneShotTransactionStatusV1

    func executeAfterCallerExit() throws
        -> MacOneShotTransactionStatusV1

    func cancelCommitAwaitingCallerExit() throws
        -> MacOneShotTransactionStatusV1

    func cancel(
        transactionID: String,
        readyToken: String,
        journalSHA256: String,
        helperEndpointIdentitySHA256: String
    ) throws -> MacOneShotTransactionStatusV1
}

extension MacOneShotInstallSession: MacPrivilegedInstallSessionServing {}

enum MacPrivilegedTransactionHandlerError: Error, Equatable {
    case invalidOperation
    case invalidPeer
    case duplicateTransaction
    case transactionNotFound
    case transactionBindingMismatch
}

struct MacPrivilegedTransactionResponse {
    let payload: Data
    let helperEndpointIdentitySHA256: String
    let completeAfterReply: (() throws -> Void)?
}

final class MacPrivilegedTransactionHandler {
    private final class PendingTransaction {
        let peerProcessIdentifier: Int32
        let session: any MacPrivilegedInstallSessionServing
        let monitor: any MacCallerExitMonitoring
        let reservation: MacOneShotReservationV1
        var commitAccepted = false

        init(
            peerProcessIdentifier: Int32,
            session: any MacPrivilegedInstallSessionServing,
            monitor: any MacCallerExitMonitoring,
            reservation: MacOneShotReservationV1
        ) {
            self.peerProcessIdentifier = peerProcessIdentifier
            self.session = session
            self.monitor = monitor
            self.reservation = reservation
        }
    }

    let helperEndpointIdentitySHA256: String
    private let sessionFactory:
        (Int32) throws -> any MacPrivilegedInstallSessionServing
    private let monitorFactory: any MacCallerExitMonitorCreating
    private let recoveryHandler: any MacPrivilegedRecoveryRequestHandling
    private let lock = NSLock()
    private var preparing: Set<String> = []
    private var pending: [String: PendingTransaction] = [:]

    init(
        helperEndpointIdentitySHA256: String = String(
            repeating: "c",
            count: 64
        ),
        sessionFactory: @escaping
            (Int32) throws -> any MacPrivilegedInstallSessionServing,
        monitorFactory: any MacCallerExitMonitorCreating,
        recoveryHandler: any MacPrivilegedRecoveryRequestHandling
    ) {
        self.helperEndpointIdentitySHA256 =
            helperEndpointIdentitySHA256
        self.sessionFactory = sessionFactory
        self.monitorFactory = monitorFactory
        self.recoveryHandler = recoveryHandler
    }

    convenience init(
        policy: MacSealedInstallPolicyV1,
        helperEndpointIdentitySHA256: String
    ) {
        let recovery = MacPersistentRecoveryService(
            policy: policy,
            callerAuthenticator:
                AuthenticatedMacXPCRecoveryCallerAuthenticator(),
            verifierFactory: SystemMacRecoveryPayloadVerifierFactory()
        )
        self.init(
            helperEndpointIdentitySHA256:
                helperEndpointIdentitySHA256,
            sessionFactory: { peerProcessIdentifier in
                let validator = MacOneShotInstallRequestValidator(
                    parentProcessIdentifier: {
                        peerProcessIdentifier
                    },
                    callerInspector:
                        SystemMacCallerInstallEvidenceInspector(),
                    stageInspector:
                        SystemMacStageInstallEvidenceInspector()
                )
                let authorizer = SealedMacOneShotInstallAuthorizer(
                    policy: policy,
                    helperEndpointIdentitySHA256:
                        helperEndpointIdentitySHA256,
                    requestValidator: validator
                )
                return MacOneShotInstallSession(
                    authorizer: authorizer,
                    readyTokenGenerator:
                        MacPrivilegedTransactionHandler.secureReadyToken,
                    nowUnixMilliseconds:
                        MacPrivilegedTransactionHandler.unixMilliseconds,
                    reservationLifetimeMilliseconds: 300_000
                )
            },
            monitorFactory: SystemMacCallerExitMonitorFactory(),
            recoveryHandler: MacPersistentRecoveryRequestHandler(
                service: recovery
            )
        )
    }

    func handle(
        operation: String,
        payload: Data,
        peerProcessIdentifier: Int32
    ) throws -> MacPrivilegedTransactionResponse {
        guard peerProcessIdentifier > 0 else {
            throw MacPrivilegedTransactionHandlerError.invalidPeer
        }
        switch operation {
        case "prepareInstall":
            return try prepare(
                payload: payload,
                peerProcessIdentifier: peerProcessIdentifier
            )
        case "commitAfterExit":
            return try commit(
                payload: payload,
                peerProcessIdentifier: peerProcessIdentifier
            )
        case "cancelReservation":
            return try cancel(
                payload: payload,
                peerProcessIdentifier: peerProcessIdentifier
            )
        case "queryTransaction", "recoverPendingInstall":
            guard try NativeStrictJSON.canonicalize(payload) == payload,
                  let object = try NativeStrictJSON.decode(payload)
                    as? [String: Any],
                  object["operation"] as? String == operation else {
                throw MacPrivilegedTransactionHandlerError
                    .invalidOperation
            }
            return MacPrivilegedTransactionResponse(
                payload: try recoveryHandler.response(for: payload),
                helperEndpointIdentitySHA256:
                    helperEndpointIdentitySHA256,
                completeAfterReply: nil
            )
        default:
            throw MacPrivilegedTransactionHandlerError.invalidOperation
        }
    }

    private func prepare(
        payload: Data,
        peerProcessIdentifier: Int32
    ) throws -> MacPrivilegedTransactionResponse {
        let request = try NativeInstallTransactionRequestV1.parse(payload)
        guard request.caller.processIdentifier
                == Int64(peerProcessIdentifier) else {
            throw MacPrivilegedTransactionHandlerError.invalidPeer
        }
        lock.lock()
        guard pending[request.transactionID] == nil,
              preparing.insert(request.transactionID).inserted else {
            lock.unlock()
            throw MacPrivilegedTransactionHandlerError
                .duplicateTransaction
        }
        lock.unlock()

        do {
            let session = try sessionFactory(peerProcessIdentifier)
            let monitor = try monitorFactory.makeMonitor(
                processIdentifier: request.caller.processIdentifier
            )
            let reservation = try session.prepare(requestData: payload)
            guard reservation.transactionID == request.transactionID,
                  reservation.helperEndpointIdentitySHA256
                    == helperEndpointIdentitySHA256 else {
                throw MacPrivilegedTransactionHandlerError
                    .transactionBindingMismatch
            }
            let transaction = PendingTransaction(
                peerProcessIdentifier: peerProcessIdentifier,
                session: session,
                monitor: monitor,
                reservation: reservation
            )
            lock.lock()
            preparing.remove(request.transactionID)
            pending[request.transactionID] = transaction
            lock.unlock()
            return MacPrivilegedTransactionResponse(
                payload: try macEncodeReservation(reservation),
                helperEndpointIdentitySHA256:
                    helperEndpointIdentitySHA256,
                completeAfterReply: nil
            )
        } catch {
            lock.lock()
            preparing.remove(request.transactionID)
            lock.unlock()
            throw error
        }
    }

    private func commit(
        payload: Data,
        peerProcessIdentifier: Int32
    ) throws -> MacPrivilegedTransactionResponse {
        let command = try MacOneShotWireCommand.parse(payload)
        guard command.operation == "commitAfterExit" else {
            throw MacPrivilegedTransactionHandlerError.invalidOperation
        }
        let transaction = try claim(
            command: command,
            peerProcessIdentifier: peerProcessIdentifier,
            acceptingCommit: true
        )
        do {
            _ = try transaction.session.acceptCommit(
                transactionID: command.transactionID,
                readyToken: command.readyToken,
                journalSHA256: command.journalSHA256,
                helperEndpointIdentitySHA256:
                    command.helperEndpointIdentitySHA256
            )
        } catch {
            remove(transaction)
            throw error
        }
        return MacPrivilegedTransactionResponse(
            payload: try macEncodeReservation(transaction.reservation),
            helperEndpointIdentitySHA256:
                helperEndpointIdentitySHA256,
            completeAfterReply: { [weak self, weak transaction] in
                guard let self, let transaction else { return }
                defer { self.remove(transaction) }
                do {
                    try transaction.monitor.waitForExit(
                        expiresAtUnixMilliseconds:
                            transaction.reservation
                            .expiresAtUnixMilliseconds
                    )
                    _ = try transaction.session.executeAfterCallerExit()
                } catch {
                    _ = try? transaction.session
                        .cancelCommitAwaitingCallerExit()
                    throw error
                }
            }
        )
    }

    private func cancel(
        payload: Data,
        peerProcessIdentifier: Int32
    ) throws -> MacPrivilegedTransactionResponse {
        let command = try MacOneShotWireCommand.parse(payload)
        guard command.operation == "cancelReservation" else {
            throw MacPrivilegedTransactionHandlerError.invalidOperation
        }
        let transaction = try claim(
            command: command,
            peerProcessIdentifier: peerProcessIdentifier,
            acceptingCommit: false
        )
        defer { remove(transaction) }
        _ = try transaction.session.cancel(
            transactionID: command.transactionID,
            readyToken: command.readyToken,
            journalSHA256: command.journalSHA256,
            helperEndpointIdentitySHA256:
                command.helperEndpointIdentitySHA256
        )
        return MacPrivilegedTransactionResponse(
            payload: try macEncodeCancellation(transaction.reservation),
            helperEndpointIdentitySHA256:
                helperEndpointIdentitySHA256,
            completeAfterReply: nil
        )
    }

    private func claim(
        command: MacOneShotWireCommand,
        peerProcessIdentifier: Int32,
        acceptingCommit: Bool
    ) throws -> PendingTransaction {
        lock.lock()
        defer { lock.unlock() }
        guard let transaction = pending[command.transactionID] else {
            throw MacPrivilegedTransactionHandlerError
                .transactionNotFound
        }
        guard transaction.peerProcessIdentifier
                == peerProcessIdentifier,
              transaction.reservation.readyToken == command.readyToken,
              transaction.reservation.journalSHA256
                == command.journalSHA256,
              transaction.reservation.helperEndpointIdentitySHA256
                == command.helperEndpointIdentitySHA256,
              !transaction.commitAccepted else {
            throw MacPrivilegedTransactionHandlerError
                .transactionBindingMismatch
        }
        if acceptingCommit {
            transaction.commitAccepted = true
        }
        return transaction
    }

    private func remove(_ transaction: PendingTransaction) {
        lock.lock()
        if pending[transaction.reservation.transactionID]
            === transaction {
            pending.removeValue(
                forKey: transaction.reservation.transactionID
            )
        }
        lock.unlock()
    }

    private static func secureReadyToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            throw MacOneShotInstallError.invalidReadyToken
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

private final class AuthenticatedMacXPCRecoveryCallerAuthenticator:
    MacRecoveryCallerAuthenticating
{
    func authenticate(policy _: MacSealedInstallPolicyV1) throws {}
}

final class SystemMacPrivilegedServiceRuntime: MacPrivilegedServiceRunning {
    private let infoDictionary: [String: Any]

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        self.infoDictionary = infoDictionary ?? [:]
    }

    func run() throws {
        try MacPrivilegedBootstrapEnvironment.validate(
            effectiveUserIdentifier: Darwin.geteuid()
        )
        let configuration = try MacPrivilegeConfiguration
            .fromEmbeddedInfoDictionary(infoDictionary)
        guard #available(macOS 12.0, *) else {
            throw MacPrivilegeError.peerAuthenticationUnavailable
        }
        guard let executableURL = Bundle.main.executableURL else {
            throw MacPrivilegeError.invalidConfiguration
        }
        let helperIdentity = try SecurityMacSignedExecutableIdentityChecker()
            .identity(
                at: executableURL,
                requirement: configuration.helperRequirement
            )
        guard helperIdentity.isSignatureValid,
              helperIdentity.bundleIdentifier
                == configuration.serviceIdentifier,
              helperIdentity.sha256.count == 64,
              helperIdentity.sha256.allSatisfy({
                  $0.isNumber || ("a" ... "f").contains($0)
              }) else {
            throw MacPrivilegeError.signedIdentityMismatch
        }
        let peerRequirement = try MacXPCPeerRequirement.make(
            applicationRequirement: configuration.applicationRequirement,
            helperTeamIdentifier: helperIdentity.teamIdentifier
        )
        let policy = try MacSealedInstallPolicyV1.load(
            infoDictionary: infoDictionary
        )
        let handler = MacPrivilegedTransactionHandler(
            policy: policy,
            helperEndpointIdentitySHA256: helperIdentity.sha256
        )
        MacPrivilegedXPCServer(
            configuration: configuration,
            peerRequirement: peerRequirement,
            transactionHandler: handler
        ).run()
    }
}

@available(macOS 12.0, *)
private final class MacPrivilegedXPCServer {
    private let configuration: MacPrivilegeConfiguration
    private let peerRequirement: String
    private let transactionHandler: MacPrivilegedTransactionHandler

    init(
        configuration: MacPrivilegeConfiguration,
        peerRequirement: String,
        transactionHandler: MacPrivilegedTransactionHandler
    ) {
        self.configuration = configuration
        self.peerRequirement = peerRequirement
        self.transactionHandler = transactionHandler
    }

    func run() -> Never {
        let requirement = peerRequirement
        let handler = transactionHandler
        let queue = DispatchQueue(
            label: "\(configuration.serviceIdentifier).listener"
        )
        let listener = configuration.serviceIdentifier.withCString {
            xpc_connection_create_mach_service(
                $0,
                queue,
                UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
            )
        }
        xpc_connection_set_event_handler(listener) { connection in
            let status = requirement.withCString {
                xpc_connection_set_peer_code_signing_requirement(
                    connection,
                    $0
                )
            }
            guard status == 0 else {
                xpc_connection_cancel(connection)
                return
            }
            xpc_connection_set_event_handler(connection) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
                      let operation = xpc_dictionary_get_string(
                          message,
                          "operation"
                      ), let reply = xpc_dictionary_create_reply(message)
                else {
                    xpc_connection_cancel(connection)
                    return
                }
                let operationText = String(cString: operation)
                if operationText == "health" {
                    xpc_dictionary_set_bool(reply, "ok", true)
                    xpc_dictionary_set_int64(
                        reply,
                        "protocolVersion",
                        1
                    )
                    handler.helperEndpointIdentitySHA256.withCString {
                        xpc_dictionary_set_string(
                            reply,
                            "helperEndpointIdentitySha256",
                            $0
                        )
                    }
                    xpc_connection_send_message(connection, reply)
                    return
                }
                var payloadLength = 0
                guard let payloadBytes = xpc_dictionary_get_data(
                    message,
                    "payload",
                    &payloadLength
                ), (1 ... MacLengthPrefixedFileHandleChannel
                    .maximumFrameLength).contains(payloadLength) else {
                    xpc_connection_cancel(connection)
                    return
                }
                let payload = Data(
                    bytes: payloadBytes,
                    count: payloadLength
                )
                do {
                    let response = try handler.handle(
                        operation: operationText,
                        payload: payload,
                        peerProcessIdentifier:
                            xpc_connection_get_pid(connection)
                    )
                    response.payload.withUnsafeBytes { bytes in
                        xpc_dictionary_set_data(
                            reply,
                            "payload",
                            bytes.baseAddress,
                            bytes.count
                        )
                    }
                    response.helperEndpointIdentitySHA256.withCString {
                        xpc_dictionary_set_string(
                            reply,
                            "helperEndpointIdentitySha256",
                            $0
                        )
                    }
                    xpc_connection_send_message(connection, reply)
                    if let complete = response.completeAfterReply {
                        DispatchQueue.global(qos: .utility).async {
                            try? complete()
                        }
                    }
                } catch {
                    xpc_connection_cancel(connection)
                }
            }
            xpc_connection_resume(connection)
        }
        xpc_connection_resume(listener)
        dispatchMain()
    }
}

final class MacPrivilegeService {
    private let configuration: MacPrivilegeConfiguration
    private let applicationBundleURL: URL
    private let identityChecker: any MacSignedExecutableIdentityChecking
    private let installer: any MacPrivilegeInstalling

    init(
        configuration: MacPrivilegeConfiguration,
        applicationBundleURL: URL,
        identityChecker: any MacSignedExecutableIdentityChecking =
            SecurityMacSignedExecutableIdentityChecker(),
        installer: any MacPrivilegeInstalling = SMJobBlessPrivilegeInstaller()
    ) {
        self.configuration = configuration
        self.applicationBundleURL = applicationBundleURL.standardizedFileURL
        self.identityChecker = identityChecker
        self.installer = installer
    }

    func installPrivilegedHelper() throws {
        let oneShotURL = applicationBundleURL.appendingPathComponent(
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        let privilegedURL = applicationBundleURL.appendingPathComponent(
            "Contents/Library/LaunchServices/"
                + configuration.serviceIdentifier
        )
        guard oneShotURL.deletingLastPathComponent().standardizedFileURL
            == applicationBundleURL.appendingPathComponent(
                "Contents/Helpers"
            ).standardizedFileURL,
            privilegedURL.deletingLastPathComponent().standardizedFileURL
                == applicationBundleURL.appendingPathComponent(
                    "Contents/Library/LaunchServices"
                ).standardizedFileURL else {
            throw MacPrivilegeError.invalidNestedHelperLocation
        }

        let oneShotBytes: Data
        let privilegedBytes: Data
        do {
            oneShotBytes = try Data(
                contentsOf: oneShotURL,
                options: [.mappedIfSafe]
            )
            privilegedBytes = try Data(
                contentsOf: privilegedURL,
                options: [.mappedIfSafe]
            )
        } catch {
            throw MacPrivilegeError.invalidNestedHelperLocation
        }
        guard !oneShotBytes.isEmpty,
              oneShotBytes == privilegedBytes else {
            throw MacPrivilegeError.nestedPayloadMismatch
        }

        let application = try identityChecker.identity(
            at: applicationBundleURL,
            requirement: configuration.applicationRequirement
        )
        let oneShot = try identityChecker.identity(
            at: oneShotURL,
            requirement: configuration.helperRequirement
        )
        let privileged = try identityChecker.identity(
            at: privilegedURL,
            requirement: configuration.helperRequirement
        )
        let byteDigest = macPrivilegeSHA256(oneShotBytes)
        guard application.isSignatureValid,
              oneShot.isSignatureValid,
              privileged.isSignatureValid,
              application.bundleIdentifier
                == configuration.applicationBundleIdentifier,
              oneShot.bundleIdentifier == configuration.serviceIdentifier,
              privileged.bundleIdentifier
                == configuration.serviceIdentifier,
              !application.teamIdentifier.isEmpty,
              application.teamIdentifier == oneShot.teamIdentifier,
              application.teamIdentifier == privileged.teamIdentifier,
              application.designatedRequirement
                == configuration.applicationRequirement,
              oneShot.designatedRequirement
                == configuration.helperRequirement,
              privileged.designatedRequirement
                == configuration.helperRequirement,
              oneShot.sha256 == privileged.sha256,
              oneShot.sha256 == byteDigest else {
            throw MacPrivilegeError.signedIdentityMismatch
        }
        try installer.install(
            serviceIdentifier: configuration.serviceIdentifier
        )
    }

    func authenticatePrivilegedPeer(
        connectionAuditToken: Data,
        claimedAuditToken: Data
    ) throws -> MacSignedExecutableIdentity {
        guard !connectionAuditToken.isEmpty,
              connectionAuditToken == claimedAuditToken else {
            throw MacPrivilegeError.peerAuthenticationFailed
        }
        let caller: MacSignedExecutableIdentity
        let application: MacSignedExecutableIdentity
        do {
            caller = try identityChecker.runningIdentity(
                auditToken: connectionAuditToken,
                requirement: configuration.applicationRequirement
            )
            application = try identityChecker.identity(
                at: applicationBundleURL,
                requirement: configuration.applicationRequirement
            )
        } catch {
            throw MacPrivilegeError.peerAuthenticationFailed
        }
        guard caller.isSignatureValid,
              application.isSignatureValid,
              caller.bundleIdentifier
                == configuration.applicationBundleIdentifier,
              application.bundleIdentifier
                == configuration.applicationBundleIdentifier,
              !caller.teamIdentifier.isEmpty,
              caller.teamIdentifier == application.teamIdentifier,
              caller.designatedRequirement
                == configuration.applicationRequirement,
              application.designatedRequirement
                == configuration.applicationRequirement else {
            throw MacPrivilegeError.peerAuthenticationFailed
        }
        return caller
    }
}

final class SecurityMacSignedExecutableIdentityChecker:
    MacSignedExecutableIdentityChecking
{
    func identity(
        at url: URL,
        requirement: String
    ) throws -> MacSignedExecutableIdentity {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw MacPrivilegeError.signedIdentityMismatch
        }
        var requirementObject: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &requirementObject
        )
        guard requirementStatus == errSecSuccess,
              let requirementObject,
              SecStaticCodeCheckValidity(
                  staticCode,
                  [],
                  requirementObject
              ) == errSecSuccess else {
            throw MacPrivilegeError.signedIdentityMismatch
        }
        let digest: String
        if let bytes = try? Data(
            contentsOf: url,
            options: [.mappedIfSafe]
        ) {
            digest = macPrivilegeSHA256(bytes)
        } else {
            digest = ""
        }
        return try signingIdentity(
            staticCode,
            requirement: requirement,
            sha256: digest
        )
    }

    func runningIdentity(
        auditToken: Data,
        requirement: String
    ) throws -> MacSignedExecutableIdentity {
        let attributes = NSDictionary(
            object: auditToken as NSData,
            forKey: kSecGuestAttributeAudit as String as NSString
        )
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess,
            let code else {
            throw MacPrivilegeError.peerAuthenticationFailed
        }
        var requirementObject: SecRequirement?
        guard SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &requirementObject
        ) == errSecSuccess,
            let requirementObject,
            SecCodeCheckValidity(code, [], requirementObject)
                == errSecSuccess else {
            throw MacPrivilegeError.peerAuthenticationFailed
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw MacPrivilegeError.peerAuthenticationFailed
        }
        return try signingIdentity(
            staticCode,
            requirement: requirement,
            sha256: ""
        )
    }

    private func signingIdentity(
        _ code: SecStaticCode,
        requirement: String,
        sha256: String
    ) throws -> MacSignedExecutableIdentity {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String]
                as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String]
                as? String else {
            throw MacPrivilegeError.signedIdentityMismatch
        }
        return MacSignedExecutableIdentity(
            bundleIdentifier: identifier,
            teamIdentifier: team,
            designatedRequirement: requirement,
            sha256: sha256,
            isSignatureValid: true
        )
    }
}

final class SMJobBlessPrivilegeInstaller: MacPrivilegeInstalling {
    func install(serviceIdentifier: String) throws {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess,
              let authorization else {
            throw MacPrivilegeInstallError.authorizationFailed(createStatus)
        }
        defer { AuthorizationFree(authorization, []) }

        let status = kSMRightBlessPrivilegedHelper.withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(
                    count: 1,
                    items: itemPointer
                )
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [
                        .interactionAllowed,
                        .extendRights,
                        .preAuthorize,
                    ],
                    nil
                )
            }
        }
        if status == errAuthorizationCanceled {
            throw MacPrivilegeInstallError.authorizationCancelled
        }
        guard status == errAuthorizationSuccess else {
            throw MacPrivilegeInstallError.authorizationFailed(status)
        }

        var error: Unmanaged<CFError>?
        guard SMJobBless(
            kSMDomainSystemLaunchd,
            serviceIdentifier as CFString,
            authorization,
            &error
        ) else {
            _ = error?.takeRetainedValue()
            throw MacPrivilegeInstallError.invalidBlessing
        }
    }
}

func macPrivilegeSHA256(_ data: Data) -> String {
    var context = CC_SHA256_CTX()
    _ = CC_SHA256_Init(&context)
    data.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = min(bytes.count - offset, Int(CC_LONG.max))
            _ = CC_SHA256_Update(
                &context,
                address.advanced(by: offset),
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
