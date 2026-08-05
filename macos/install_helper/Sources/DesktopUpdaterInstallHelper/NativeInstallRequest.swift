import CoreFoundation
import Foundation

struct NativeInstallProtocolError: Error, Equatable {
    let code: String
}

struct NativeInstallTargetV1: Equatable {
    let targetClass: String
    let pathHint: String
    let targetNameHint: String
    let executableRelativePath: String
    let identityProofSHA256: String
}

struct NativeInstallVersionIdentityV1: Equatable {
    let version: String
    let buildNumber: Int64
    let packageIdentitySHA256: String
}

struct NativeInstallStageV1: Equatable {
    let pathHint: String
    let ownershipNonce: String
    let provenanceSHA256: String
    let artifactSHA256: String
    let artifactLength: Int64
}

struct NativeInstallSignedDescriptorV1: Equatable {
    let canonicalSHA256: String
    let signatureAlgorithm: String
    let keyID: String
    let signatureBase64: String
}

struct NativeInstallCallerV1: Equatable {
    let processIdentifier: Int64
    let processStartIdentity: String
    let executableSHA256: String
    let packageID: String
    let signerIdentity: String
}

struct NativeInstallDiagnosticsDestinationV1: Equatable {
    let kind: String
    let stream: String?
}

struct NativeInstallTransactionRequestV1: Equatable {
    let schemaVersion: Int
    let protocolVersion: Int
    let transactionID: String
    let policyID: String
    let packageID: String
    let strategy: String
    let provider: String
    let target: NativeInstallTargetV1
    let currentIdentity: NativeInstallVersionIdentityV1
    let desiredIdentity: NativeInstallVersionIdentityV1
    let stage: NativeInstallStageV1
    let signedDescriptor: NativeInstallSignedDescriptorV1
    let caller: NativeInstallCallerV1
    let requestNonce: String
    let diagnosticsDestination: NativeInstallDiagnosticsDestinationV1?

    static func parse(_ data: Data) throws -> Self {
        let value = try NativeStrictJSON.decode(data)
        let request = try NativeRequestValidation.map(value, "request")
        try NativeRequestValidation.exactKeys(
            request,
            required: [
                "schemaVersion",
                "protocolVersion",
                "transactionId",
                "policyId",
                "packageId",
                "strategy",
                "provider",
                "target",
                "currentIdentity",
                "desiredIdentity",
                "stage",
                "signedDescriptor",
                "caller",
                "requestNonce",
            ],
            optional: ["diagnosticsDestination"]
        )

        guard try NativeRequestValidation.integer(
            request["schemaVersion"],
            "schemaVersion",
            minimum: Int64.min
        ) == 1 else {
            throw NativeInstallProtocolError(
                code: "unsupportedSchemaVersion"
            )
        }
        guard try NativeRequestValidation.integer(
            request["protocolVersion"],
            "protocolVersion",
            minimum: Int64.min
        ) == 1 else {
            throw NativeInstallProtocolError(
                code: "unsupportedProtocolVersion"
            )
        }
        let transactionID = try NativeRequestValidation.pattern(
            request["transactionId"],
            field: "transactionId",
            expression: NativeRequestValidation.lowercaseUUID,
            failure: "invalidTransactionId"
        )
        let policyID = try NativeRequestValidation.pattern(
            request["policyId"],
            field: "policyId",
            expression: NativeRequestValidation.dottedIdentifier,
            failure: "invalidPolicyId"
        )
        let packageID = try NativeRequestValidation.pattern(
            request["packageId"],
            field: "packageId",
            expression: NativeRequestValidation.dottedIdentifier,
            failure: "invalidPackageId"
        )
        let strategy = try NativeRequestValidation.enumeration(
            request["strategy"],
            field: "strategy",
            allowed: Set(NativeRequestValidation.strategyProviders.keys),
            failure: "unknownStrategy"
        )
        let provider = try NativeRequestValidation.enumeration(
            request["provider"],
            field: "provider",
            allowed: NativeRequestValidation.providers,
            failure: "unknownProvider"
        )
        guard NativeRequestValidation.strategyProviders[strategy]?
            .contains(provider) == true else {
            throw NativeInstallProtocolError(
                code: "strategyProviderMismatch"
            )
        }

        return try Self(
            schemaVersion: 1,
            protocolVersion: 1,
            transactionID: transactionID,
            policyID: policyID,
            packageID: packageID,
            strategy: strategy,
            provider: provider,
            target: NativeRequestValidation.target(
                request["target"],
                strategy: strategy
            ),
            currentIdentity: NativeRequestValidation.versionIdentity(
                request["currentIdentity"],
                field: "currentIdentity"
            ),
            desiredIdentity: NativeRequestValidation.versionIdentity(
                request["desiredIdentity"],
                field: "desiredIdentity"
            ),
            stage: NativeRequestValidation.stage(request["stage"]),
            signedDescriptor: NativeRequestValidation.signedDescriptor(
                request["signedDescriptor"]
            ),
            caller: NativeRequestValidation.caller(
                request["caller"],
                expectedPackageID: packageID
            ),
            requestNonce: NativeRequestValidation.pattern(
                request["requestNonce"],
                field: "requestNonce",
                expression: NativeRequestValidation.readyToken,
                failure: "invalidRequestNonce"
            ),
            diagnosticsDestination: request["diagnosticsDestination"].map {
                try NativeRequestValidation.diagnosticsDestination($0)
            }
        )
    }
}

enum NativeStrictJSON {
    static func decode(_ data: Data) throws -> Any {
        guard let source = String(data: data, encoding: .utf8) else {
            throw NativeInstallProtocolError(code: "invalidJson")
        }
        var scanner = NativeDuplicateKeyScanner(source: source)
        try scanner.scan()
        do {
            return try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw NativeInstallProtocolError(code: "invalidJson")
        }
    }

    static func canonicalize(_ data: Data) throws -> Data {
        var result = Data()
        try appendCanonical(try decode(data), to: &result)
        return result
    }

    private static func appendCanonical(_ value: Any, to data: inout Data)
        throws
    {
        switch value {
        case is NSNull:
            data.append(contentsOf: "null".utf8)
        case let value as String:
            data.append(try encodedString(value))
        case let value as [Any]:
            data.append(UInt8(ascii: "["))
            for (index, item) in value.enumerated() {
                if index > 0 { data.append(UInt8(ascii: ",")) }
                try appendCanonical(item, to: &data)
            }
            data.append(UInt8(ascii: "]"))
        case let value as [String: Any]:
            data.append(UInt8(ascii: "{"))
            let keys = value.keys.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { data.append(UInt8(ascii: ",")) }
                data.append(try encodedString(key))
                data.append(UInt8(ascii: ":"))
                try appendCanonical(value[key] as Any, to: &data)
            }
            data.append(UInt8(ascii: "}"))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                data.append(
                    contentsOf: (value.boolValue ? "true" : "false").utf8
                )
            } else {
                let number = value.stringValue
                guard !number.contains("nan"),
                      !number.contains("inf") else {
                    throw NativeInstallProtocolError(code: "nonFiniteNumber")
                }
                data.append(contentsOf: number.utf8)
            }
        default:
            throw NativeInstallProtocolError(code: "unsupportedJsonValue")
        }
    }

    private static func encodedString(_ value: String) throws -> Data {
        let encoded = try JSONSerialization.data(
            withJSONObject: [value]
        )
        guard encoded.count >= 2 else {
            throw NativeInstallProtocolError(code: "invalidJson")
        }
        let escaped = String(
            decoding: encoded.subdata(in: 1 ..< encoded.count - 1),
            as: UTF8.self
        )
        return Data(escaped.replacingOccurrences(of: "\\/", with: "/").utf8)
    }
}

private enum NativeRequestValidation {
    static let lowercaseUUID =
        #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
    static let sha256 = #"^[0-9a-f]{64}$"#
    static let readyToken = #"^[A-Za-z0-9_-]{43}$"#
    static let dottedIdentifier =
        #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{1,126}[A-Za-z0-9])?$"#
    static let keyID = #"^[A-Za-z0-9._-]{1,128}$"#
    static let signature = #"^[A-Za-z0-9+/]{86}==$"#

    static let providers: Set<String> = [
        "platformDirectory",
        "platformFile",
        "macosInstaller",
        "windowsInno",
        "apt",
        "dnf",
        "flatpak",
        "snap",
    ]
    static let strategyProviders: [String: Set<String>] = [
        "directoryReplace": ["platformDirectory"],
        "singleFileReplace": ["platformFile"],
        "verifiedInstallerHandoff": ["macosInstaller", "windowsInno"],
        "systemPackageTransaction": ["apt", "dnf"],
        "externalManagedRefresh": ["flatpak", "snap"],
    ]
    private static let targetClasses: Set<String> = [
        "applicationBundle",
        "applicationDirectory",
        "singleExecutable",
        "systemPackage",
        "externalManaged",
    ]
    private static let strategyTargetClasses: [String: Set<String>] = [
        "directoryReplace": ["applicationBundle", "applicationDirectory"],
        "singleFileReplace": ["singleExecutable"],
        "verifiedInstallerHandoff": [
            "applicationBundle",
            "applicationDirectory",
        ],
        "systemPackageTransaction": ["systemPackage"],
        "externalManagedRefresh": ["externalManaged"],
    ]

    static func exactKeys(
        _ value: [String: Any],
        required: [String],
        optional: Set<String> = [],
        path: String = ""
    ) throws {
        for key in required where value[key] == nil {
            throw NativeInstallProtocolError(
                code: "missingField:\(field(path, key))"
            )
        }
        let allowed = Set(required).union(optional)
        for key in value.keys.sorted() where !allowed.contains(key) {
            throw NativeInstallProtocolError(
                code: "unknownField:\(field(path, key))"
            )
        }
    }

    static func map(_ value: Any?, _ field: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else {
            throw NativeInstallProtocolError(code: "invalidType:\(field)")
        }
        return result
    }

    static func pattern(
        _ value: Any?,
        field: String,
        expression: String,
        failure: String
    ) throws -> String {
        guard let value = value as? String else {
            throw NativeInstallProtocolError(code: "invalidType:\(field)")
        }
        guard value.range(
            of: expression,
            options: .regularExpression
        ) != nil else {
            throw NativeInstallProtocolError(code: failure)
        }
        return value
    }

    static func enumeration(
        _ value: Any?,
        field: String,
        allowed: Set<String>,
        failure: String
    ) throws -> String {
        guard let value = value as? String else {
            throw NativeInstallProtocolError(code: "invalidType:\(field)")
        }
        guard allowed.contains(value) else {
            throw NativeInstallProtocolError(code: failure)
        }
        return value
    }

    static func boundedString(
        _ value: Any?,
        field: String,
        maximum: Int
    ) throws -> String {
        guard let value = value as? String else {
            throw NativeInstallProtocolError(code: "invalidType:\(field)")
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum else {
            throw NativeInstallProtocolError(code: "invalidString:\(field)")
        }
        return value
    }

    static func integer(
        _ value: Any?,
        _ field: String,
        minimum: Int64,
        maximum: Int64 = Int64.max
    ) throws -> Int64 {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else {
            throw NativeInstallProtocolError(code: "invalidInteger:\(field)")
        }
        let result = number.int64Value
        guard result >= minimum, result <= maximum,
              NSNumber(value: result) == number else {
            throw NativeInstallProtocolError(code: "invalidInteger:\(field)")
        }
        return result
    }

    static func target(
        _ value: Any?,
        strategy: String
    ) throws -> NativeInstallTargetV1 {
        let target = try map(value, "target")
        try exactKeys(
            target,
            required: [
                "class",
                "pathHint",
                "targetNameHint",
                "executableRelativePath",
                "identityProofSha256",
            ],
            path: "target"
        )
        let targetClass = try enumeration(
            target["class"],
            field: "target.class",
            allowed: targetClasses,
            failure: "unknownTargetClass"
        )
        guard strategyTargetClasses[strategy]?.contains(targetClass) == true
        else {
            throw NativeInstallProtocolError(code: "strategyTargetMismatch")
        }
        return try NativeInstallTargetV1(
            targetClass: targetClass,
            pathHint: boundedString(
                target["pathHint"],
                field: "target.pathHint",
                maximum: 4096
            ),
            targetNameHint: safeSiblingName(target["targetNameHint"]),
            executableRelativePath: safeRelativePath(
                target["executableRelativePath"]
            ),
            identityProofSHA256: pattern(
                target["identityProofSha256"],
                field: "target.identityProofSha256",
                expression: sha256,
                failure: "invalidSha256:target.identityProofSha256"
            )
        )
    }

    static func versionIdentity(
        _ value: Any?,
        field name: String
    ) throws -> NativeInstallVersionIdentityV1 {
        let identity = try map(value, name)
        try exactKeys(
            identity,
            required: ["version", "buildNumber", "packageIdentitySha256"],
            path: name
        )
        return try NativeInstallVersionIdentityV1(
            version: boundedString(
                identity["version"],
                field: "\(name).version",
                maximum: 128
            ),
            buildNumber: integer(
                identity["buildNumber"],
                "\(name).buildNumber",
                minimum: 0
            ),
            packageIdentitySHA256: pattern(
                identity["packageIdentitySha256"],
                field: "\(name).packageIdentitySha256",
                expression: sha256,
                failure: "invalidSha256:\(name).packageIdentitySha256"
            )
        )
    }

    static func stage(_ value: Any?) throws -> NativeInstallStageV1 {
        let stage = try map(value, "stage")
        try exactKeys(
            stage,
            required: [
                "pathHint",
                "ownershipNonce",
                "provenanceSha256",
                "artifactSha256",
                "artifactLength",
            ],
            path: "stage"
        )
        return try NativeInstallStageV1(
            pathHint: boundedString(
                stage["pathHint"],
                field: "stage.pathHint",
                maximum: 4096
            ),
            ownershipNonce: pattern(
                stage["ownershipNonce"],
                field: "stage.ownershipNonce",
                expression: sha256,
                failure: "invalidStageOwnershipNonce"
            ),
            provenanceSHA256: pattern(
                stage["provenanceSha256"],
                field: "stage.provenanceSha256",
                expression: sha256,
                failure: "invalidSha256:stage.provenanceSha256"
            ),
            artifactSHA256: pattern(
                stage["artifactSha256"],
                field: "stage.artifactSha256",
                expression: sha256,
                failure: "invalidSha256:stage.artifactSha256"
            ),
            artifactLength: integer(
                stage["artifactLength"],
                "stage.artifactLength",
                minimum: 1
            )
        )
    }

    static func signedDescriptor(
        _ value: Any?
    ) throws -> NativeInstallSignedDescriptorV1 {
        let descriptor = try map(value, "signedDescriptor")
        try exactKeys(
            descriptor,
            required: [
                "canonicalSha256",
                "signatureAlgorithm",
                "keyId",
                "signatureBase64",
            ],
            path: "signedDescriptor"
        )
        let algorithm = try string(
            descriptor["signatureAlgorithm"],
            "signedDescriptor.signatureAlgorithm"
        )
        guard algorithm == "ed25519" else {
            throw NativeInstallProtocolError(
                code: "unsupportedDescriptorSignatureAlgorithm"
            )
        }
        let signatureValue = try pattern(
            descriptor["signatureBase64"],
            field: "signedDescriptor.signatureBase64",
            expression: signature,
            failure: "invalidDescriptorSignature"
        )
        guard Data(base64Encoded: signatureValue)?.count == 64 else {
            throw NativeInstallProtocolError(
                code: "invalidDescriptorSignature"
            )
        }
        return try NativeInstallSignedDescriptorV1(
            canonicalSHA256: pattern(
                descriptor["canonicalSha256"],
                field: "signedDescriptor.canonicalSha256",
                expression: sha256,
                failure:
                    "invalidSha256:signedDescriptor.canonicalSha256"
            ),
            signatureAlgorithm: algorithm,
            keyID: pattern(
                descriptor["keyId"],
                field: "signedDescriptor.keyId",
                expression: keyID,
                failure: "invalidDescriptorKeyId"
            ),
            signatureBase64: signatureValue
        )
    }

    static func caller(
        _ value: Any?,
        expectedPackageID: String
    ) throws -> NativeInstallCallerV1 {
        let caller = try map(value, "caller")
        try exactKeys(
            caller,
            required: [
                "processId",
                "processStartIdentity",
                "executableSha256",
                "packageId",
                "signerIdentity",
            ],
            path: "caller"
        )
        let packageID = try pattern(
            caller["packageId"],
            field: "caller.packageId",
            expression: dottedIdentifier,
            failure: "invalidCallerPackageId"
        )
        guard packageID == expectedPackageID else {
            throw NativeInstallProtocolError(code: "callerPackageIdMismatch")
        }
        return try NativeInstallCallerV1(
            processIdentifier: integer(
                caller["processId"],
                "caller.processId",
                minimum: 1,
                maximum: 4_294_967_295
            ),
            processStartIdentity: boundedString(
                caller["processStartIdentity"],
                field: "caller.processStartIdentity",
                maximum: 256
            ),
            executableSHA256: pattern(
                caller["executableSha256"],
                field: "caller.executableSha256",
                expression: sha256,
                failure: "invalidSha256:caller.executableSha256"
            ),
            packageID: packageID,
            signerIdentity: boundedString(
                caller["signerIdentity"],
                field: "caller.signerIdentity",
                maximum: 512
            )
        )
    }

    static func diagnosticsDestination(
        _ value: Any?
    ) throws -> NativeInstallDiagnosticsDestinationV1 {
        let destination = try map(value, "diagnosticsDestination")
        try exactKeys(
            destination,
            required: ["kind"],
            optional: ["stream"],
            path: "diagnosticsDestination"
        )
        let kind = try enumeration(
            destination["kind"],
            field: "diagnosticsDestination.kind",
            allowed: ["platformLog", "inheritedStream"],
            failure: "invalidDiagnosticsDestination"
        )
        let stream = destination["stream"] as? String
        guard kind == "inheritedStream"
            ? stream == "stderr"
            : destination["stream"] == nil else {
            throw NativeInstallProtocolError(
                code: "invalidDiagnosticsDestination"
            )
        }
        return NativeInstallDiagnosticsDestinationV1(
            kind: kind,
            stream: stream
        )
    }

    private static func string(_ value: Any?, _ field: String) throws
        -> String
    {
        guard let value = value as? String else {
            throw NativeInstallProtocolError(code: "invalidType:\(field)")
        }
        return value
    }

    private static func safeSiblingName(_ value: Any?) throws -> String {
        guard let value = value as? String,
              !value.isEmpty,
              value.count <= 255,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains(":") else {
            throw NativeInstallProtocolError(code: "invalidTargetNameHint")
        }
        return value
    }

    private static func safeRelativePath(_ value: Any?) throws -> String {
        guard let value = value as? String,
              !value.isEmpty,
              value.count <= 1024,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              value.range(
                  of: #"^[A-Za-z]:"#,
                  options: .regularExpression
              ) == nil,
              !value.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw NativeInstallProtocolError(
                code: "invalidExecutableRelativePath"
            )
        }
        return value
    }

    private static func field(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}

private struct NativeDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(source: String) {
        bytes = Array(source.utf8)
    }

    mutating func scan() throws {
        skipWhitespace()
        try scanValue()
        skipWhitespace()
        guard index == bytes.count else { throw invalidJSON() }
    }

    private mutating func scanValue() throws {
        guard index < bytes.count else { throw invalidJSON() }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            try scanObject()
        case UInt8(ascii: "["):
            try scanArray()
        case UInt8(ascii: "\""):
            _ = try scanString()
        case UInt8(ascii: "t"):
            try scanLiteral("true")
        case UInt8(ascii: "f"):
            try scanLiteral("false")
        case UInt8(ascii: "n"):
            try scanLiteral("null")
        default:
            try scanNumber()
        }
    }

    private mutating func scanObject() throws {
        index += 1
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return }
        var keys = Set<String>()
        while true {
            guard index < bytes.count,
                  bytes[index] == UInt8(ascii: "\"") else {
                throw invalidJSON()
            }
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw NativeInstallProtocolError(code: "duplicateKey:\(key)")
            }
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw invalidJSON() }
            skipWhitespace()
            try scanValue()
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return }
            guard consume(UInt8(ascii: ",")) else { throw invalidJSON() }
            skipWhitespace()
        }
    }

    private mutating func scanArray() throws {
        index += 1
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return }
        while true {
            try scanValue()
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return }
            guard consume(UInt8(ascii: ",")) else { throw invalidJSON() }
            skipWhitespace()
        }
    }

    private mutating func scanString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                if byte == UInt8(ascii: "u") {
                    for _ in 0 ..< 4 {
                        guard index < bytes.count, isHex(bytes[index]) else {
                            throw invalidJSON()
                        }
                        index += 1
                    }
                } else if ![
                    UInt8(ascii: "\""),
                    UInt8(ascii: "\\"),
                    UInt8(ascii: "/"),
                    UInt8(ascii: "b"),
                    UInt8(ascii: "f"),
                    UInt8(ascii: "n"),
                    UInt8(ascii: "r"),
                    UInt8(ascii: "t"),
                ].contains(byte) {
                    throw invalidJSON()
                }
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                let data = Data(bytes[start ..< index])
                guard let result = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                ) as? String else {
                    throw invalidJSON()
                }
                return result
            } else if byte < 0x20 {
                throw invalidJSON()
            }
        }
        throw invalidJSON()
    }

    private mutating func scanLiteral(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard bytes[index...].starts(with: literalBytes) else {
            throw invalidJSON()
        }
        index += literalBytes.count
    }

    private mutating func scanNumber() throws {
        let start = index
        if consume(UInt8(ascii: "-")) {}
        guard index < bytes.count else { throw invalidJSON() }
        if consume(UInt8(ascii: "0")) {
            if index < bytes.count, isDigit(bytes[index]) {
                throw invalidJSON()
            }
        } else {
            guard index < bytes.count,
                  (UInt8(ascii: "1") ... UInt8(ascii: "9"))
                    .contains(bytes[index]) else {
                throw invalidJSON()
            }
            index += 1
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if consume(UInt8(ascii: ".")) {
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw invalidJSON()
            }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count,
           bytes[index] == UInt8(ascii: "e") ||
            index < bytes.count && bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count,
               bytes[index] == UInt8(ascii: "+") ||
                index < bytes.count && bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw invalidJSON()
            }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        guard index > start else { throw invalidJSON() }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              [UInt8(ascii: " "), 0x0A, 0x0D, 0x09]
                .contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }

    private func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte)
            || (UInt8(ascii: "A") ... UInt8(ascii: "F")).contains(byte)
            || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
    }

    private func invalidJSON() -> NativeInstallProtocolError {
        NativeInstallProtocolError(code: "invalidJson")
    }
}
