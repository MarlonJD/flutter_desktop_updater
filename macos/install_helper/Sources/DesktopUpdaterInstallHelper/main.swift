import Darwin
import Foundation

do {
    switch try HelperCommand.parse(arguments: Array(CommandLine.arguments.dropFirst())) {
    case .version:
        print(HelperVersion.displayString)
    case .testParseProtocol:
        let envelope = try TestProtocolEnvelope.parse(
            FileHandle.standardInput.readDataToEndOfFile()
        )
        print(
            "valid schema=\(envelope.schemaVersion) "
                + "protocol=\(envelope.protocolVersion)"
        )
    }
} catch let error as HelperBootstrapError {
    let code: String
    switch error {
    case .unsupportedArguments:
        code = "unsupportedArguments"
    case .invalidTestProtocol:
        code = "invalidTestProtocol"
    }
    FileHandle.standardError.write(Data("\(code)\n".utf8))
    Darwin.exit(64)
} catch {
    FileHandle.standardError.write(Data("helperBootstrapFailure\n".utf8))
    Darwin.exit(70)
}
