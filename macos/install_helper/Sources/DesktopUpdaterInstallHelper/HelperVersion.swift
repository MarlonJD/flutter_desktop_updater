import Foundation

enum HelperVersion {
    static let semanticVersion = "3.1.4"
    static let protocolVersion = 1
    static let displayString =
        "DesktopUpdaterInstallHelper \(semanticVersion) (protocol \(protocolVersion))"
}

enum HelperCommand: Equatable {
    case version
    case testParseProtocol
    case oneShotService
    case oneShotRecovery
    case verifiedInstallerWorker
    case privilegedService

    static func parse(arguments: [String]) throws -> HelperCommand {
        switch arguments {
        case ["--version"]:
            return .version
        case ["--test-parse-protocol"]:
            return .testParseProtocol
        case ["--one-shot-service"]:
            return .oneShotService
        case ["--one-shot-recovery"]:
            return .oneShotRecovery
        case ["--verified-installer-worker"]:
            return .verifiedInstallerWorker
        case []:
            return .privilegedService
        default:
            throw HelperBootstrapError.unsupportedArguments
        }
    }

    func execute(
        protocolInput: Data,
        oneShotServiceRuntime: (any MacOneShotServiceRunning)? = nil,
        oneShotRecoveryRuntime: (any MacOneShotServiceRunning)? = nil,
        privilegedServiceRuntime: any MacPrivilegedServiceRunning
    ) throws -> String? {
        switch self {
        case .version:
            return HelperVersion.displayString
        case .testParseProtocol:
            do {
                let request = try NativeInstallTransactionRequestV1.parse(
                    protocolInput
                )
                return "valid schema=\(request.schemaVersion) "
                    + "protocol=\(request.protocolVersion) "
                    + "transaction=\(request.transactionID)"
            } catch {
                throw HelperBootstrapError.invalidTestProtocol
            }
        case .oneShotService:
            guard let oneShotServiceRuntime else {
                throw HelperBootstrapError.oneShotServiceUnavailable
            }
            try oneShotServiceRuntime.run()
            return nil
        case .oneShotRecovery:
            guard let oneShotRecoveryRuntime else {
                throw HelperBootstrapError.oneShotRecoveryUnavailable
            }
            try oneShotRecoveryRuntime.run()
            return nil
        case .verifiedInstallerWorker:
            try MacInstallerWorkerRuntime.run(requestData: protocolInput)
            return nil
        case .privilegedService:
            try privilegedServiceRuntime.run()
            return nil
        }
    }
}

enum HelperBootstrapError: Error, Equatable {
    case unsupportedArguments
    case invalidTestProtocol
    case oneShotServiceUnavailable
    case oneShotRecoveryUnavailable
}
