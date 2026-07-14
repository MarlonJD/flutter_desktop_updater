import Darwin
import Foundation

do {
    let command = try HelperCommand.parse(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
    let input = command == .testParseProtocol
        ? FileHandle.standardInput.readDataToEndOfFile()
        : Data()
    let oneShotRuntime = command == .oneShotService
        ? try MacOneShotBootstrap.makeRuntime()
        : nil
    let oneShotRecoveryRuntime = command == .oneShotRecovery
        ? try MacOneShotBootstrap.makeRecoveryRuntime()
        : nil
    if let output = try command.execute(
        protocolInput: input,
        oneShotServiceRuntime: oneShotRuntime,
        oneShotRecoveryRuntime: oneShotRecoveryRuntime,
        privilegedServiceRuntime: SystemMacPrivilegedServiceRuntime()
    ) {
        print(output)
    }
} catch let error as HelperBootstrapError {
    let code: String
    switch error {
    case .unsupportedArguments:
        code = "unsupportedArguments"
    case .invalidTestProtocol:
        code = "invalidTestProtocol"
    case .oneShotServiceUnavailable:
        code = "oneShotServiceUnavailable"
    case .oneShotRecoveryUnavailable:
        code = "oneShotRecoveryUnavailable"
    }
    FileHandle.standardError.write(Data("\(code)\n".utf8))
    Darwin.exit(64)
} catch {
    FileHandle.standardError.write(Data("helperBootstrapFailure\n".utf8))
    Darwin.exit(70)
}
