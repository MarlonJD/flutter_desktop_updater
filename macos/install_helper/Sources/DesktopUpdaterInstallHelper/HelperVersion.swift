import Foundation

enum HelperVersion {
    static let semanticVersion = "2.7.0"
    static let protocolVersion = 1
    static let displayString =
        "DesktopUpdaterInstallHelper \(semanticVersion) (protocol \(protocolVersion))"
}

enum HelperCommand: Equatable {
    case version
    case testParseProtocol

    static func parse(arguments: [String]) throws -> HelperCommand {
        switch arguments {
        case ["--version"]:
            return .version
        case ["--test-parse-protocol"]:
            return .testParseProtocol
        default:
            throw HelperBootstrapError.unsupportedArguments
        }
    }
}

struct TestProtocolEnvelope: Equatable {
    let schemaVersion: Int
    let protocolVersion: Int

    static func parse(_ data: Data) throws -> TestProtocolEnvelope {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HelperBootstrapError.invalidTestProtocol
        }
        guard let object = value as? [String: Any],
              object.count == 2,
              let schemaVersion = integer(object["schemaVersion"]),
              let protocolVersion = integer(object["protocolVersion"]),
              schemaVersion == 1,
              protocolVersion == HelperVersion.protocolVersion else {
            throw HelperBootstrapError.invalidTestProtocol
        }
        return TestProtocolEnvelope(
            schemaVersion: schemaVersion,
            protocolVersion: protocolVersion
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else {
            return nil
        }
        let type = String(cString: number.objCType)
        guard !["c", "f", "d"].contains(type) else {
            return nil
        }
        return number.intValue
    }
}

enum HelperBootstrapError: Error, Equatable {
    case unsupportedArguments
    case invalidTestProtocol
}
