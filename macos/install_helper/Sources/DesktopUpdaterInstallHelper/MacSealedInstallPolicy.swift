import CoreFoundation
import Foundation

struct MacSealedPolicySigner: Equatable {
    let kind: String
    let value: String
}

struct MacSealedInstallStrategy: Equatable, Hashable {
    let strategy: String
    let provider: String
}

struct MacSealedReleaseRootKey: Equatable {
    let keyID: String
    let algorithm: String
    let publicKey: Data
}

enum MacSealedInstallPolicyError: Error, Equatable {
    case digestMismatch
    case invalidJSON
    case nonCanonicalJSON
    case unknownOrMissingField
    case invalidPolicy
    case unauthorized
}

struct MacSealedInstallPolicyV1: Equatable {
    let policyVersion: Int
    let policyID: String
    let applicationPackageID: String
    let helperServiceID: String
    let allowedApplicationSigner: MacSealedPolicySigner
    let allowedHelperSigner: MacSealedPolicySigner
    let allowedTargetClasses: [String]
    let allowedInstallRoots: [String]
    let releaseRootPublicKeys: [MacSealedReleaseRootKey]
    let allowedStrategies: Set<MacSealedInstallStrategy>
    let minimumHelperProtocolVersion: Int
    let canonicalSHA256: String

    static func load(
        sealedJSON: Data,
        expectedSHA256: String
    ) throws -> Self {
        guard isSHA256(expectedSHA256),
              macPrivilegeSHA256(sealedJSON) == expectedSHA256 else {
            throw MacSealedInstallPolicyError.digestMismatch
        }
        let value: Any
        do {
            value = try NativeStrictJSON.decode(sealedJSON)
        } catch {
            throw MacSealedInstallPolicyError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        try exactKeys(
            object,
            [
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
            ]
        )
        guard try NativeStrictJSON.canonicalize(sealedJSON) == sealedJSON else {
            throw MacSealedInstallPolicyError.nonCanonicalJSON
        }

        guard let policyVersion = integer(object["policyVersion"]),
              policyVersion >= 1,
              let policyID = identifier(object["policyId"]),
              let applicationPackageID = identifier(
                  object["applicationPackageId"]
              ),
              let helperServiceID = identifier(object["helperServiceId"]),
              let minimumProtocol = integer(
                  object["minimumHelperProtocolVersion"]
              ),
              minimumProtocol >= 1 else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        let targetClasses = try stringArray(
            object["allowedTargetClasses"],
            allowed: [
                "sameUserWritable",
                "applicationBundle",
                "applicationDirectory",
                "singleExecutable",
                "protectedApplication",
                "systemPackage",
                "externalManaged",
            ],
            allowEmpty: false
        )
        let roots = try installRoots(object["allowedInstallRoots"])
        let releaseKeys = try releaseRootKeys(
            object["releaseRootPublicKeys"]
        )
        let strategies = try strategies(object["allowedStrategies"])
        return Self(
            policyVersion: policyVersion,
            policyID: policyID,
            applicationPackageID: applicationPackageID,
            helperServiceID: helperServiceID,
            allowedApplicationSigner: try signer(
                object["allowedApplicationSigner"]
            ),
            allowedHelperSigner: try signer(
                object["allowedHelperSigner"]
            ),
            allowedTargetClasses: targetClasses,
            allowedInstallRoots: roots,
            releaseRootPublicKeys: releaseKeys,
            allowedStrategies: strategies,
            minimumHelperProtocolVersion: minimumProtocol,
            canonicalSHA256: expectedSHA256
        )
    }

    static func load(infoDictionary: [String: Any]) throws -> Self {
        guard let bytes = infoDictionary["DesktopUpdaterSealedPolicy"]
                as? Data,
              let digest = infoDictionary[
                  "DesktopUpdaterSealedPolicySHA256"
              ] as? String else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        let policy = try load(
            sealedJSON: bytes,
            expectedSHA256: digest
        )
        guard infoDictionary["CFBundleIdentifier"] as? String
            == policy.helperServiceID else {
            throw MacSealedInstallPolicyError.unauthorized
        }
        return policy
    }

    func authorize(
        _ request: NativeInstallTransactionRequestV1,
        canonicalTargetURL: URL
    ) throws {
        guard request.protocolVersion >= minimumHelperProtocolVersion,
              request.policyID == policyID,
              request.packageID == applicationPackageID,
              allowedStrategies.contains(
                  MacSealedInstallStrategy(
                      strategy: request.strategy,
                      provider: request.provider
                  )
              ),
              allowedTargetClasses.contains(request.target.targetClass),
              canonicalTargetURL.path == request.target.pathHint,
              canonicalTargetURL.lastPathComponent
                == request.target.targetNameHint else {
            throw MacSealedInstallPolicyError.unauthorized
        }
        let standardized = canonicalTargetURL.standardizedFileURL
        guard standardized.path == canonicalTargetURL.path,
              allowedInstallRoots.contains(
                  standardized.deletingLastPathComponent().path
              ) else {
            throw MacSealedInstallPolicyError.unauthorized
        }
    }

    private static func signer(_ value: Any?) throws
        -> MacSealedPolicySigner
    {
        guard let object = value as? [String: Any] else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        try exactKeys(object, ["kind", "value"])
        guard let kind = object["kind"] as? String,
              let signerValue = object["value"] as? String,
              !signerValue.isEmpty,
              signerValue.count <= 2_048,
              !signerValue.contains("*"),
              !signerValue.contains("?"),
              [
                  "appleDesignatedRequirement",
                  "authenticodePublisher",
                  "sha256",
              ].contains(kind),
              kind != "sha256" || isSHA256(signerValue) else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        return MacSealedPolicySigner(kind: kind, value: signerValue)
    }

    private static func installRoots(_ value: Any?) throws -> [String] {
        guard let values = value as? [String],
              Set(values).count == values.count else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        for path in values {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            guard path.hasPrefix("/"),
                  path != "/",
                  path.count <= 4_096,
                  standardized.path == path else {
                throw MacSealedInstallPolicyError.invalidPolicy
            }
        }
        return values
    }

    private static func releaseRootKeys(_ value: Any?) throws
        -> [MacSealedReleaseRootKey]
    {
        guard let values = value as? [[String: Any]], !values.isEmpty else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        var identifiers = Set<String>()
        return try values.map { value in
            try exactKeys(
                value,
                ["keyId", "algorithm", "publicKeyBase64"]
            )
            guard let keyID = value["keyId"] as? String,
                  keyID.range(
                      of: #"^[A-Za-z0-9._-]{1,128}$"#,
                      options: .regularExpression
                  ) != nil,
                  identifiers.insert(keyID).inserted,
                  value["algorithm"] as? String == "ed25519",
                  let encoded = value["publicKeyBase64"] as? String,
                  let publicKey = Data(base64Encoded: encoded),
                  publicKey.count == 32 else {
                throw MacSealedInstallPolicyError.invalidPolicy
            }
            return MacSealedReleaseRootKey(
                keyID: keyID,
                algorithm: "ed25519",
                publicKey: publicKey
            )
        }
    }

    private static func strategies(_ value: Any?) throws
        -> Set<MacSealedInstallStrategy>
    {
        guard let values = value as? [[String: Any]], !values.isEmpty else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        let providers: [String: Set<String>] = [
            "directoryReplace": ["platformDirectory"],
            "singleFileReplace": ["platformFile"],
            "verifiedInstallerHandoff": ["macosInstaller", "windowsInno"],
            "systemPackageTransaction": ["apt", "dnf"],
            "externalManagedRefresh": ["flatpak", "snap"],
        ]
        var result = Set<MacSealedInstallStrategy>()
        for value in values {
            try exactKeys(value, ["strategy", "provider"])
            guard let strategy = value["strategy"] as? String,
                  let provider = value["provider"] as? String,
                  providers[strategy]?.contains(provider) == true,
                  result.insert(
                      MacSealedInstallStrategy(
                          strategy: strategy,
                          provider: provider
                      )
                  ).inserted else {
                throw MacSealedInstallPolicyError.invalidPolicy
            }
        }
        return result
    }

    private static func stringArray(
        _ value: Any?,
        allowed: Set<String>,
        allowEmpty: Bool
    ) throws -> [String] {
        guard let values = value as? [String],
              allowEmpty || !values.isEmpty,
              Set(values).count == values.count,
              values.allSatisfy(allowed.contains) else {
            throw MacSealedInstallPolicyError.invalidPolicy
        }
        return values
    }

    private static func exactKeys(
        _ object: [String: Any],
        _ expected: Set<String>
    ) throws {
        guard Set(object.keys) == expected else {
            throw MacSealedInstallPolicyError.unknownOrMissingField
        }
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.range(
                  of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{1,126}[A-Za-z0-9])?$"#,
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else {
            return nil
        }
        return number.intValue
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }
}
