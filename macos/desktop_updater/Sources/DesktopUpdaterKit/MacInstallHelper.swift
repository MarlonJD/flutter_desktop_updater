import CommonCrypto
import Darwin
import Dispatch
import Foundation
import Security
import ServiceManagement
import XPC

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

    static func isDottedIdentifier(_ value: String) -> Bool {
        guard let range = value.range(
            of: #"^[a-z0-9](?:[a-z0-9._-]{1,126}[a-z0-9])?$"#,
            options: .regularExpression
        ) else {
            return false
        }
        return range == value.startIndex ..< value.endIndex
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
    case privilegedHelperApprovalRequired
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

protocol MacOneShotClientSession: AnyObject {
    var processIdentifier: Int32 { get }
    func writeFrame(_ data: Data) throws
    func readFrame() throws -> Data
    func closeInput()
}

protocol MacOneShotProcessLaunching: AnyObject {
    func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> any MacOneShotClientSession
}

protocol MacOneShotEndpointAuthenticating: AnyObject {
    func authenticate(
        executableURL: URL,
        processIdentifier: Int32?
    ) throws -> String
}

protocol MacPrivilegedHelperInstalling: AnyObject {
    func install() throws
}

protocol MacPrivilegedXPCExchanging: AnyObject {
    func validateEndpoint() throws -> String

    func exchange(
        operation: String,
        payload: Data
    ) throws -> (payload: Data, endpointIdentitySHA256: String)
}

final class SystemMacOneShotEndpointAuthenticator:
    MacOneShotEndpointAuthenticating
{
    private let infoDictionary: [String: Any]

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        self.infoDictionary = infoDictionary ?? [:]
    }

    func authenticate(
        executableURL: URL,
        processIdentifier: Int32?
    ) throws -> String {
        guard let serviceID = infoDictionary[
            "DesktopUpdaterInstallHelperServiceID"
        ] as? String,
            let requirementText = infoDictionary[
                "DesktopUpdaterInstallHelperRequirement"
            ] as? String,
            !requirementText.isEmpty else {
            throw MacInstallClientError.endpointUnavailable
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
            let requirement else {
            throw MacInstallClientError.endpointUnavailable
        }

        var staticCode: SecStaticCode?
        if let processIdentifier {
            guard processIdentifier > 0 else {
                throw MacInstallClientError.endpointUnavailable
            }
            var pathBuffer = [CChar](
                repeating: 0,
                count: Int(MAXPATHLEN) * 4
            )
            guard proc_pidpath(
                processIdentifier,
                &pathBuffer,
                UInt32(pathBuffer.count)
            ) > 0,
                URL(fileURLWithPath: String(cString: pathBuffer))
                    .resolvingSymlinksInPath().path
                    == executableURL.resolvingSymlinksInPath().path else {
                throw MacInstallClientError.endpointUnavailable
            }
            let attributes = NSDictionary(
                object: NSNumber(value: processIdentifier),
                forKey: kSecGuestAttributePid as String as NSString
            )
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(
                nil,
                attributes,
                [],
                &code
            ) == errSecSuccess,
                let code,
                SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
                SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess
            else {
                throw MacInstallClientError.endpointUnavailable
            }
        } else {
            guard SecStaticCodeCreateWithPath(
                executableURL as CFURL,
                [],
                &staticCode
            ) == errSecSuccess,
                let staticCode,
                SecStaticCodeCheckValidity(staticCode, [], requirement)
                    == errSecSuccess else {
                throw MacInstallClientError.endpointUnavailable
            }
        }
        guard let staticCode else {
            throw MacInstallClientError.endpointUnavailable
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == serviceID
        else {
            throw MacInstallClientError.endpointUnavailable
        }
        let data: Data
        do {
            data = try Data(
                contentsOf: executableURL,
                options: [.mappedIfSafe]
            )
        } catch {
            throw MacInstallClientError.endpointUnavailable
        }
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
}

enum MacPrivilegedServiceRegistrationStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol MacPrivilegedServiceRegistering: AnyObject {
    func status(
        plistName: String
    ) throws -> MacPrivilegedServiceRegistrationStatus

    func register(plistName: String) throws

    func unregister(plistName: String) throws
}

struct MacAppServiceUnregistrationWaiter {
    func wait(
        timeout: DispatchTime = .now() + 10,
        start: (@escaping (Error?) -> Void) -> Void
    ) throws {
        let completion = DispatchSemaphore(value: 0)
        var unregisterError: Error?
        start { error in
            unregisterError = error
            completion.signal()
        }
        guard completion.wait(timeout: timeout) == .success,
              unregisterError == nil else {
            throw MacInstallClientError.endpointUnavailable
        }
    }
}

final class SystemMacAppServiceRegistrar: MacPrivilegedServiceRegistering {
    func status(
        plistName: String
    ) throws -> MacPrivilegedServiceRegistrationStatus {
        guard #available(macOS 13.0, *) else {
            throw MacInstallClientError.endpointUnavailable
        }
        switch SMAppService.daemon(plistName: plistName).status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register(plistName: String) throws {
        guard #available(macOS 13.0, *) else {
            throw MacInstallClientError.endpointUnavailable
        }
        let service = SMAppService.daemon(plistName: plistName)
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval
                || (error as NSError).code
                    == Int(kSMErrorLaunchDeniedByUser) {
                throw MacInstallClientError
                    .privilegedHelperApprovalRequired
            }
            throw MacInstallClientError.endpointUnavailable
        }
    }

    func unregister(plistName: String) throws {
        guard #available(macOS 13.0, *) else {
            throw MacInstallClientError.endpointUnavailable
        }
        let service = SMAppService.daemon(plistName: plistName)
        try MacAppServiceUnregistrationWaiter().wait { completion in
            service.unregister(completionHandler: completion)
        }
    }
}

final class SystemMacPrivilegedHelperInstaller:
    MacPrivilegedHelperInstalling
{
    private let applicationBundleURL: URL
    private let oneShotHelperURL: URL
    private let infoDictionary: [String: Any]
    private let authenticator: any MacOneShotEndpointAuthenticating
    private let registrar: any MacPrivilegedServiceRegistering

    init(
        applicationBundleURL: URL = Bundle.main.bundleURL,
        oneShotHelperURL: URL,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        authenticator: any MacOneShotEndpointAuthenticating,
        registrar: any MacPrivilegedServiceRegistering =
            SystemMacAppServiceRegistrar()
    ) {
        self.applicationBundleURL =
            applicationBundleURL.standardizedFileURL
        self.oneShotHelperURL = oneShotHelperURL.standardizedFileURL
        self.infoDictionary = infoDictionary ?? [:]
        self.authenticator = authenticator
        self.registrar = registrar
    }

    func install() throws {
        guard #available(macOS 13.0, *) else {
            throw MacInstallClientError.endpointUnavailable
        }
        guard let serviceID = infoDictionary[
            "DesktopUpdaterInstallHelperServiceID"
        ] as? String,
            HelperProtocolValidation.isDottedIdentifier(serviceID),
            let helperRequirement = infoDictionary[
                "DesktopUpdaterInstallHelperRequirement"
            ] as? String,
            !helperRequirement.isEmpty,
            let plistName = infoDictionary[
                "DesktopUpdaterInstallHelperLaunchDaemonPlistName"
            ] as? String,
            plistName == "\(serviceID).plist" else {
            throw MacInstallClientError.endpointUnavailable
        }
        let launchDaemonURL = applicationBundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(plistName)"
        ).standardizedFileURL
        guard launchDaemonURL.deletingLastPathComponent()
            == applicationBundleURL.appendingPathComponent(
                "Contents/Library/LaunchDaemons"
            ).standardizedFileURL else {
            throw MacInstallClientError.endpointUnavailable
        }
        let launchDaemon: [String: Any]
        do {
            let value = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: launchDaemonURL),
                options: [],
                format: nil
            )
            guard let dictionary = value as? [String: Any] else {
                throw MacInstallClientError.endpointUnavailable
            }
            launchDaemon = dictionary
        } catch let error as MacInstallClientError {
            throw error
        } catch {
            throw MacInstallClientError.endpointUnavailable
        }
        guard launchDaemon["Label"] as? String == serviceID,
              launchDaemon["BundleProgram"] as? String
                == "Contents/Helpers/DesktopUpdaterInstallHelper",
              launchDaemon["Program"] == nil,
              launchDaemon["ProgramArguments"] == nil,
              launchDaemon["MachServices"] as? [String: Bool]
                == [serviceID: true] else {
            throw MacInstallClientError.endpointUnavailable
        }
        let helperIdentity = try authenticator.authenticate(
            executableURL: oneShotHelperURL,
            processIdentifier: nil
        )
        guard HelperProtocolValidation.isSHA256(helperIdentity) else {
            throw MacInstallClientError.endpointUnavailable
        }

        switch try registrar.status(plistName: plistName) {
        case .enabled:
            try registrar.unregister(plistName: plistName)
            try registrar.register(plistName: plistName)
        case .notRegistered, .notFound:
            try registrar.register(plistName: plistName)
        case .requiresApproval:
            throw MacInstallClientError.privilegedHelperApprovalRequired
        }
        switch try registrar.status(plistName: plistName) {
        case .enabled:
            return
        case .requiresApproval:
            throw MacInstallClientError.privilegedHelperApprovalRequired
        case .notRegistered, .notFound:
            throw MacInstallClientError.endpointUnavailable
        }
    }
}

final class SystemMacPrivilegedXPCExchange: MacPrivilegedXPCExchanging {
    private let serviceID: String
    private let helperRequirement: String

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        let info = infoDictionary ?? [:]
        let identifier = info[
            "DesktopUpdaterInstallHelperServiceID"
        ] as? String
        serviceID = identifier ?? ""
        helperRequirement = info[
            "DesktopUpdaterInstallHelperRequirement"
        ] as? String ?? ""
    }

    func validateEndpoint() throws -> String {
        guard #available(macOS 13.0, *) else {
            throw MacInstallClientError.endpointUnavailable
        }
        let reply = try send(operation: "health", payload: nil)
        guard xpc_dictionary_get_bool(reply, "ok"),
              xpc_dictionary_get_int64(reply, "protocolVersion") == 1
        else {
            throw MacInstallClientError.endpointUnavailable
        }
        return try endpointIdentity(from: reply)
    }

    func exchange(
        operation: String,
        payload: Data
    ) throws -> (payload: Data, endpointIdentitySHA256: String) {
        guard #available(macOS 13.0, *),
              [
                  "prepareInstall", "commitAfterExit",
                  "cancelReservation", "queryTransaction",
                  "recoverPendingInstall",
              ].contains(operation),
              (1 ... 1_048_576).contains(payload.count) else {
            throw MacInstallClientError.endpointUnavailable
        }
        let reply = try send(operation: operation, payload: payload)
        var length = 0
        guard let bytes = xpc_dictionary_get_data(
            reply,
            "payload",
            &length
        ), (1 ... 1_048_576).contains(length) else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return (
            Data(bytes: bytes, count: length),
            try endpointIdentity(from: reply)
        )
    }

    @available(macOS 13.0, *)
    private func send(
        operation: String,
        payload: Data?
    ) throws -> xpc_object_t {
        guard HelperProtocolValidation.isDottedIdentifier(serviceID),
              !helperRequirement.isEmpty,
              !helperRequirement.contains("\0"),
              !helperRequirement.contains("\n") else {
            throw MacInstallClientError.endpointUnavailable
        }
        let queue = DispatchQueue(label: "\(serviceID).client")
        let connection = serviceID.withCString {
            xpc_connection_create_mach_service($0, queue, 0)
        }
        let status = helperRequirement.withCString {
            xpc_connection_set_peer_code_signing_requirement(
                connection,
                $0
            )
        }
        guard status == 0 else {
            xpc_connection_cancel(connection)
            throw MacInstallClientError.endpointUnavailable
        }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        defer { xpc_connection_cancel(connection) }

        let message = xpc_dictionary_create(nil, nil, 0)
        operation.withCString {
            xpc_dictionary_set_string(message, "operation", $0)
        }
        if let payload {
            payload.withUnsafeBytes { bytes in
                xpc_dictionary_set_data(
                    message,
                    "payload",
                    bytes.baseAddress,
                    bytes.count
                )
            }
        }
        let reply = xpc_connection_send_message_with_reply_sync(
            connection,
            message
        )
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
            throw MacInstallClientError.endpointUnavailable
        }
        return reply
    }

    private func endpointIdentity(
        from reply: xpc_object_t
    ) throws -> String {
        guard let value = xpc_dictionary_get_string(
            reply,
            "helperEndpointIdentitySha256"
        ) else {
            throw MacInstallClientError.invalidReservationResponse
        }
        let result = String(cString: value)
        guard HelperProtocolValidation.isSHA256(result) else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return result
    }
}

final class ProcessMacOneShotProcessLauncher: MacOneShotProcessLaunching {
    func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> any MacOneShotClientSession {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw MacInstallClientError.endpointUnavailable
        }
        return ProcessMacOneShotClientSession(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading
        )
    }
}

private final class ProcessMacOneShotClientSession:
    MacOneShotClientSession
{
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var inputIsClosed = false

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    func writeFrame(_ data: Data) throws {
        guard (1 ... 1_048_576).contains(data.count), !inputIsClosed else {
            throw MacInstallClientError.invalidReservationResponse
        }
        let length = UInt32(data.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        frame.append(data)
        input.write(frame)
    }

    func readFrame() throws -> Data {
        let header = try readExactly(4)
        let length = header.reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
        guard (1 ... 1_048_576).contains(length) else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return try readExactly(length)
    }

    func closeInput() {
        guard !inputIsClosed else { return }
        input.closeFile()
        inputIsClosed = true
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let fragment = output.readData(ofLength: count - result.count)
            guard !fragment.isEmpty else {
                throw MacInstallClientError.invalidReservationResponse
            }
            result.append(fragment)
        }
        return result
    }
}

final class PackagedMacInstallHelperTransport:
    MacInstallHelperTransport
{
    private final class ActiveSession {
        let channel: (any MacOneShotClientSession)?
        let isPrivileged: Bool
        let reservation: InstallReservationResponseV1

        init(
            channel: (any MacOneShotClientSession)?,
            isPrivileged: Bool,
            reservation: InstallReservationResponseV1
        ) {
            self.channel = channel
            self.isPrivileged = isPrivileged
            self.reservation = reservation
        }
    }

    private let helperURL: URL
    private let policyID: String?
    private let launcher: any MacOneShotProcessLaunching
    private let authenticator: any MacOneShotEndpointAuthenticating
    private let privilegedInstaller: any MacPrivilegedHelperInstalling
    private let privilegedExchange: any MacPrivilegedXPCExchanging
    private let privilegeRequired: (Data) throws -> Bool
    private let forcePrivilegedPersistentOperations: Bool
    private let lock = NSLock()
    private var sessions: [String: ActiveSession] = [:]
    private var privilegedTransactions: Set<String> = []

    init(
        helperURL: URL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        ),
        policyID: String? = Bundle.main.infoDictionary?[
            "DesktopUpdaterInstallPolicyID"
        ] as? String,
        launcher: any MacOneShotProcessLaunching =
            ProcessMacOneShotProcessLauncher(),
        authenticator: any MacOneShotEndpointAuthenticating =
            SystemMacOneShotEndpointAuthenticator(),
        privilegedInstaller: (any MacPrivilegedHelperInstalling)? = nil,
        privilegedExchange: (any MacPrivilegedXPCExchanging)? = nil,
        privilegeRequired: @escaping (Data) throws -> Bool =
            PackagedMacInstallHelperTransport.defaultPrivilegeRequired,
        forcePrivilegedPersistentOperations: Bool = false
    ) {
        self.helperURL = helperURL.standardizedFileURL
        self.policyID = policyID
        self.launcher = launcher
        self.authenticator = authenticator
        self.privilegedInstaller = privilegedInstaller
            ?? SystemMacPrivilegedHelperInstaller(
                oneShotHelperURL: self.helperURL,
                authenticator: authenticator
            )
        self.privilegedExchange = privilegedExchange
            ?? SystemMacPrivilegedXPCExchange()
        self.privilegeRequired = privilegeRequired
        self.forcePrivilegedPersistentOperations =
            forcePrivilegedPersistentOperations
    }

    func validateEndpoint() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path)
        else {
            throw MacInstallClientError.endpointUnavailable
        }
        _ = try authenticator.authenticate(
            executableURL: helperURL,
            processIdentifier: nil
        )
    }

    func prepareInstall(
        request: Data,
        transactionID: String
    ) throws -> InstallReservationResponseV1 {
        if try privilegeRequired(request) {
            return try preparePrivilegedInstall(
                request: request,
                transactionID: transactionID
            )
        }
        let expectedEndpoint = try authenticator.authenticate(
            executableURL: helperURL,
            processIdentifier: nil
        )
        let channel = try launcher.launch(
            executableURL: helperURL,
            arguments: ["--one-shot-service"]
        )
        do {
            let runningEndpoint = try authenticator.authenticate(
                executableURL: helperURL,
                processIdentifier: channel.processIdentifier
            )
            guard runningEndpoint == expectedEndpoint else {
                throw MacInstallClientError.invalidReservationResponse
            }
            try channel.writeFrame(request)
            let reservation = try parseReservation(
                channel.readFrame(),
                transactionID: transactionID
            )
            guard reservation.helperEndpointIdentitySHA256
                    == runningEndpoint else {
                throw MacInstallClientError.invalidReservationResponse
            }
            lock.lock()
            defer { lock.unlock() }
            guard sessions[transactionID] == nil else {
                throw MacInstallClientError.invalidReservationResponse
            }
            sessions[transactionID] = ActiveSession(
                channel: channel,
                isPrivileged: false,
                reservation: reservation
            )
            return reservation
        } catch {
            channel.closeInput()
            throw error
        }
    }

    private func preparePrivilegedInstall(
        request: Data,
        transactionID: String
    ) throws -> InstallReservationResponseV1 {
        let runningEndpoint = try authenticatedPrivilegedEndpoint(
            allowInstallation: true
        )
        let exchange = try privilegedExchange.exchange(
            operation: "prepareInstall",
            payload: request
        )
        guard exchange.endpointIdentitySHA256 == runningEndpoint else {
            throw MacInstallClientError.invalidReservationResponse
        }
        let reservation = try parseReservation(
            exchange.payload,
            transactionID: transactionID
        )
        guard reservation.helperEndpointIdentitySHA256
                == runningEndpoint else {
            throw MacInstallClientError.invalidReservationResponse
        }
        lock.lock()
        defer { lock.unlock() }
        guard sessions[transactionID] == nil else {
            throw MacInstallClientError.invalidReservationResponse
        }
        sessions[transactionID] = ActiveSession(
            channel: nil,
            isPrivileged: true,
            reservation: reservation
        )
        privilegedTransactions.insert(transactionID)
        return reservation
    }

    func commitAfterExit(
        transactionID: String,
        readyToken: String
    ) throws -> InstallTransactionStatus {
        let session = try takeSession(
            transactionID: transactionID,
            readyToken: readyToken
        )
        if session.isPrivileged {
            return try commitPrivileged(session)
        }
        guard let channel = session.channel else {
            throw MacInstallClientError.invalidReservationResponse
        }
        do {
            try channel.writeFrame(
                try commandData(
                    operation: "commitAfterExit",
                    reservation: session.reservation
                )
            )
            let acknowledgement = try parseReservation(
                channel.readFrame(),
                transactionID: transactionID
            )
            guard acknowledgement == session.reservation else {
                throw MacInstallClientError.invalidReservationResponse
            }
            channel.closeInput()
            return InstallTransactionStatus(
                transactionID: transactionID,
                state: .commitAccepted,
                resultCode: .accepted,
                detail: "",
                responseDigestSHA256: acknowledgement.journalSHA256,
                helperEndpointIdentitySHA256:
                    acknowledgement.helperEndpointIdentitySHA256
            )
        } catch {
            channel.closeInput()
            throw error
        }
    }

    func cancelReservation(
        transactionID: String,
        readyToken: String
    ) throws -> InstallTransactionStatus {
        let session = try takeSession(
            transactionID: transactionID,
            readyToken: readyToken
        )
        if session.isPrivileged {
            return try cancelPrivileged(session)
        }
        guard let channel = session.channel else {
            throw MacInstallClientError.invalidReservationResponse
        }
        do {
            try channel.writeFrame(
                try commandData(
                    operation: "cancelReservation",
                    reservation: session.reservation
                )
            )
            try validateCancellation(
                channel.readFrame(),
                reservation: session.reservation
            )
            channel.closeInput()
            return InstallTransactionStatus(
                transactionID: transactionID,
                state: .cancelled,
                resultCode: .succeeded,
                detail: "",
                responseDigestSHA256:
                    session.reservation.journalSHA256,
                helperEndpointIdentitySHA256:
                    session.reservation.helperEndpointIdentitySHA256
            )
        } catch {
            channel.closeInput()
            throw error
        }
    }

    func queryTransaction(
        transactionID: String
    ) throws -> InstallTransactionStatus {
        if forcePrivilegedPersistentOperations
            || usesPrivilegedTransport(transactionID) {
            return try persistentPrivilegedStatus(
                operation: "queryTransaction",
                transactionID: transactionID,
                isRecovery: false,
                allowInstallation: forcePrivilegedPersistentOperations
            )
        }
        do {
            let (response, endpoint) = try persistentRecoveryExchange(
                operation: "queryTransaction",
                transactionID: transactionID
            )
            return try parseTransactionStatus(
                response,
                transactionID: transactionID,
                endpointIdentitySHA256: endpoint
            )
        } catch let unprivilegedError {
            do {
                return try persistentPrivilegedStatus(
                    operation: "queryTransaction",
                    transactionID: transactionID,
                    isRecovery: false,
                    allowInstallation: false
                )
            } catch {
                throw unprivilegedError
            }
        }
    }

    func recoverPendingInstall(
        transactionID: String
    ) throws -> InstallTransactionStatus {
        if forcePrivilegedPersistentOperations
            || usesPrivilegedTransport(transactionID) {
            return try persistentPrivilegedStatus(
                operation: "recoverPendingInstall",
                transactionID: transactionID,
                isRecovery: true,
                allowInstallation: true
            )
        }
        do {
            let (response, endpoint) = try persistentRecoveryExchange(
                operation: "recoverPendingInstall",
                transactionID: transactionID
            )
            return try parseRecoveryResult(
                response,
                transactionID: transactionID,
                endpointIdentitySHA256: endpoint
            )
        } catch {
            return try persistentPrivilegedStatus(
                operation: "recoverPendingInstall",
                transactionID: transactionID,
                isRecovery: true,
                allowInstallation: true
            )
        }
    }

    private func commitPrivileged(
        _ session: ActiveSession
    ) throws -> InstallTransactionStatus {
        let exchange = try privilegedExchange.exchange(
            operation: "commitAfterExit",
            payload: try commandData(
                operation: "commitAfterExit",
                reservation: session.reservation
            )
        )
        let acknowledgement = try parseReservation(
            exchange.payload,
            transactionID: session.reservation.transactionID
        )
        guard acknowledgement == session.reservation,
              exchange.endpointIdentitySHA256
                == acknowledgement.helperEndpointIdentitySHA256 else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return InstallTransactionStatus(
            transactionID: acknowledgement.transactionID,
            state: .commitAccepted,
            resultCode: .accepted,
            detail: "",
            responseDigestSHA256: acknowledgement.journalSHA256,
            helperEndpointIdentitySHA256:
                acknowledgement.helperEndpointIdentitySHA256
        )
    }

    private func cancelPrivileged(
        _ session: ActiveSession
    ) throws -> InstallTransactionStatus {
        let exchange = try privilegedExchange.exchange(
            operation: "cancelReservation",
            payload: try commandData(
                operation: "cancelReservation",
                reservation: session.reservation
            )
        )
        guard exchange.endpointIdentitySHA256
                == session.reservation.helperEndpointIdentitySHA256 else {
            throw MacInstallClientError.invalidReservationResponse
        }
        try validateCancellation(
            exchange.payload,
            reservation: session.reservation
        )
        return InstallTransactionStatus(
            transactionID: session.reservation.transactionID,
            state: .cancelled,
            resultCode: .succeeded,
            detail: "",
            responseDigestSHA256: session.reservation.journalSHA256,
            helperEndpointIdentitySHA256:
                session.reservation.helperEndpointIdentitySHA256
        )
    }

    private func persistentPrivilegedStatus(
        operation: String,
        transactionID: String,
        isRecovery: Bool,
        allowInstallation: Bool
    ) throws -> InstallTransactionStatus {
        guard let policyID,
              HelperProtocolValidation.isDottedIdentifier(policyID) else {
            throw MacInstallClientError.endpointUnavailable
        }
        let expectedEndpoint = try authenticatedPrivilegedEndpoint(
            allowInstallation: allowInstallation
        )
        let exchange = try privilegedExchange.exchange(
            operation: operation,
            payload: try canonicalData([
                "operation": operation,
                "policyId": policyID,
                "protocolVersion": 1,
                "transactionId": transactionID,
            ])
        )
        guard exchange.endpointIdentitySHA256 == expectedEndpoint else {
            throw MacInstallClientError.invalidReservationResponse
        }
        if isRecovery {
            return try parseRecoveryResult(
                exchange.payload,
                transactionID: transactionID,
                endpointIdentitySHA256: expectedEndpoint
            )
        }
        return try parseTransactionStatus(
            exchange.payload,
            transactionID: transactionID,
            endpointIdentitySHA256: expectedEndpoint
        )
    }

    private func authenticatedPrivilegedEndpoint(
        allowInstallation: Bool
    ) throws -> String {
        let expectedEndpoint = try authenticator.authenticate(
            executableURL: helperURL,
            processIdentifier: nil
        )
        do {
            let runningEndpoint = try privilegedExchange
                .validateEndpoint()
            if runningEndpoint == expectedEndpoint {
                return runningEndpoint
            }
            guard allowInstallation else {
                throw MacInstallClientError.invalidReservationResponse
            }
        } catch let error as MacInstallClientError {
            guard allowInstallation,
                  error == .endpointUnavailable else {
                throw error
            }
        }
        try privilegedInstaller.install()
        let installedEndpoint = try privilegedExchange.validateEndpoint()
        guard installedEndpoint == expectedEndpoint else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return installedEndpoint
    }

    private func usesPrivilegedTransport(_ transactionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return privilegedTransactions.contains(transactionID)
    }

    static func defaultPrivilegeRequired(_ request: Data) throws -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: request)
                as? [String: Any],
              let target = object["target"] as? [String: Any],
              let targetClass = target["class"] as? String,
              let path = target["pathHint"] as? String,
              path.hasPrefix("/") else {
            return false
        }
        if ["protectedApplication", "systemPackage"]
            .contains(targetClass) {
            return true
        }
        let parent = URL(fileURLWithPath: path)
            .standardizedFileURL.deletingLastPathComponent()
        return !FileManager.default.isWritableFile(atPath: parent.path)
    }

    private func persistentRecoveryExchange(
        operation: String,
        transactionID: String
    ) throws -> (Data, String) {
        guard let policyID,
              HelperProtocolValidation.isDottedIdentifier(policyID),
              ["queryTransaction", "recoverPendingInstall"]
                .contains(operation) else {
            throw MacInstallClientError.endpointUnavailable
        }
        let expectedEndpoint = try authenticator.authenticate(
            executableURL: helperURL,
            processIdentifier: nil
        )
        let channel = try launcher.launch(
            executableURL: helperURL,
            arguments: ["--one-shot-recovery"]
        )
        do {
            let runningEndpoint = try authenticator.authenticate(
                executableURL: helperURL,
                processIdentifier: channel.processIdentifier
            )
            guard runningEndpoint == expectedEndpoint,
                  HelperProtocolValidation.isSHA256(runningEndpoint) else {
                throw MacInstallClientError.invalidReservationResponse
            }
            try channel.writeFrame(
                try canonicalData([
                    "operation": operation,
                    "policyId": policyID,
                    "protocolVersion": 1,
                    "transactionId": transactionID,
                ])
            )
            let response = try channel.readFrame()
            channel.closeInput()
            return (response, runningEndpoint)
        } catch {
            channel.closeInput()
            throw error
        }
    }

    private func parseTransactionStatus(
        _ data: Data,
        transactionID: String,
        endpointIdentitySHA256: String
    ) throws -> InstallTransactionStatus {
        let object = try canonicalObject(data)
        guard Set(object.keys) == [
            "protocolVersion", "transactionId", "state", "resultCode",
            "journalSha256",
        ],
            exactInteger(object["protocolVersion"]) == 1,
            object["transactionId"] as? String == transactionID,
            let stateText = object["state"] as? String,
            let state = transactionState(stateText),
            let resultText = object["resultCode"] as? String,
            let resultCode = transactionResultCode(resultText),
            validStatusCombination(stateText, resultText),
            let journalSHA256 = object["journalSha256"] as? String,
            HelperProtocolValidation.isSHA256(journalSHA256) else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return InstallTransactionStatus(
            transactionID: transactionID,
            state: state,
            resultCode: resultCode,
            detail: "",
            responseDigestSHA256: journalSHA256,
            helperEndpointIdentitySHA256: endpointIdentitySHA256
        )
    }

    private func parseRecoveryResult(
        _ data: Data,
        transactionID: String,
        endpointIdentitySHA256: String
    ) throws -> InstallTransactionStatus {
        let object = try canonicalObject(data)
        guard Set(object.keys) == [
            "protocolVersion", "transactionId", "resultCode",
            "verifiedOutcome", "journalSha256",
        ],
            exactInteger(object["protocolVersion"]) == 1,
            object["transactionId"] as? String == transactionID,
            let result = object["resultCode"] as? String,
            let outcome = object["verifiedOutcome"] as? String,
            let mapped = recoveryStatus(result: result, outcome: outcome),
            let journalSHA256 = object["journalSha256"] as? String,
            HelperProtocolValidation.isSHA256(journalSHA256) else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return InstallTransactionStatus(
            transactionID: transactionID,
            state: mapped.0,
            resultCode: mapped.1,
            detail: outcome,
            responseDigestSHA256: journalSHA256,
            helperEndpointIdentitySHA256: endpointIdentitySHA256
        )
    }

    private func transactionState(_ value: String)
        -> InstallTransactionState?
    {
        switch value {
        case "prepared":
            return .prepared
        case "backupCreated", "targetActivated", "managerStarted",
             "verificationPending":
            return .commitAccepted
        case "completed":
            return .completed
        case "rolledBack":
            return .rolledBack
        case "manualActionRequired":
            return .manualActionRequired
        default:
            return nil
        }
    }

    private func transactionResultCode(_ value: String)
        -> InstallTransactionResultCode?
    {
        switch value {
        case "completed", "rolledBack":
            return .succeeded
        case "recoveryRequired", "manualActionRequired":
            return .recoveryRequired
        default:
            return nil
        }
    }

    private func validStatusCombination(
        _ state: String,
        _ result: String
    ) -> Bool {
        switch (state, result) {
        case ("completed", "completed"),
             ("rolledBack", "rolledBack"),
             ("manualActionRequired", "manualActionRequired"):
            return true
        case ("prepared", "recoveryRequired"),
             ("backupCreated", "recoveryRequired"),
             ("targetActivated", "recoveryRequired"),
             ("managerStarted", "recoveryRequired"),
             ("verificationPending", "recoveryRequired"):
            return true
        default:
            return false
        }
    }

    private func recoveryStatus(
        result: String,
        outcome: String
    ) -> (InstallTransactionState, InstallTransactionResultCode)? {
        switch (result, outcome) {
        case ("completed", "newTarget"), ("completed", "none"):
            return (.completed, .succeeded)
        case ("rolledBack", "oldTarget"):
            return (.rolledBack, .succeeded)
        case ("recoveryRequired", "none"):
            return (.prepared, .recoveryRequired)
        case ("manualActionRequired", "none"):
            return (.manualActionRequired, .recoveryRequired)
        default:
            return nil
        }
    }

    private func takeSession(
        transactionID: String,
        readyToken: String
    ) throws -> ActiveSession {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions.removeValue(forKey: transactionID),
              session.reservation.readyToken == readyToken else {
            throw MacInstallClientError.inactiveReservation
        }
        return session
    }

    private func parseReservation(
        _ data: Data,
        transactionID: String
    ) throws -> InstallReservationResponseV1 {
        let object = try canonicalObject(data)
        guard Set(object.keys) == [
            "protocolVersion",
            "transactionId",
            "readyToken",
            "journalSha256",
            "helperEndpointIdentitySha256",
            "expiresAtUnixMilliseconds",
        ],
            exactInteger(object["protocolVersion"]) == 1,
            object["transactionId"] as? String == transactionID,
            let readyToken = object["readyToken"] as? String,
            HelperProtocolValidation.isReadyToken(readyToken),
            let journalSHA256 = object["journalSha256"] as? String,
            HelperProtocolValidation.isSHA256(journalSHA256),
            let endpoint = object["helperEndpointIdentitySha256"] as? String,
            HelperProtocolValidation.isSHA256(endpoint),
            let expiresAt = exactInteger(
                object["expiresAtUnixMilliseconds"]
            ),
            expiresAt > 0 else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return InstallReservationResponseV1(
            protocolVersion: 1,
            transactionID: transactionID,
            readyToken: readyToken,
            journalSHA256: journalSHA256,
            helperEndpointIdentitySHA256: endpoint,
            expiresAtUnixMilliseconds: expiresAt
        )
    }

    private func validateCancellation(
        _ data: Data,
        reservation: InstallReservationResponseV1
    ) throws {
        let object = try canonicalObject(data)
        guard Set(object.keys) == [
            "protocolVersion",
            "transactionId",
            "resultCode",
            "verifiedOutcome",
            "journalSha256",
        ],
            exactInteger(object["protocolVersion"]) == 1,
            object["transactionId"] as? String
                == reservation.transactionID,
            object["resultCode"] as? String == "rolledBack",
            object["verifiedOutcome"] as? String == "oldTarget",
            object["journalSha256"] as? String
                == reservation.journalSHA256 else {
            throw MacInstallClientError.invalidReservationResponse
        }
    }

    private func commandData(
        operation: String,
        reservation: InstallReservationResponseV1
    ) throws -> Data {
        try canonicalData([
            "operation": operation,
            "protocolVersion": 1,
            "transactionId": reservation.transactionID,
            "readyToken": reservation.readyToken,
            "journalSha256": reservation.journalSHA256,
            "helperEndpointIdentitySha256":
                reservation.helperEndpointIdentitySHA256,
        ])
    }

    private func canonicalObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              try canonicalData(object) == data else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return object
    }

    private func canonicalData(_ object: Any) throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return Data(text.replacingOccurrences(of: "\\/", with: "/").utf8)
    }

    private func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              !["c", "f", "d"].contains(
                  String(cString: number.objCType)
              ) else {
            return nil
        }
        let result = number.int64Value
        return NSNumber(value: result) == number ? result : nil
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

    @_spi(DesktopUpdaterSmoke)
    public static func smAppServiceSmokeHost() -> MacInstallHelper {
        MacInstallHelper(
            targetResolver: {
                MacInstallTarget(
                    processIdentifier:
                        ProcessInfo.processInfo.processIdentifier,
                    bundleURL: Bundle.main.bundleURL
                )
            },
            transport: PackagedMacInstallHelperTransport(
                privilegeRequired: { _ in true },
                forcePrivilegedPersistentOperations: true
            )
        )
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
