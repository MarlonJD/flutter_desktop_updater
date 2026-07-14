import Foundation

public struct HelperPolicySigner: Equatable {
    public let kind: String
    public let value: String
}

public struct HelperPolicy: Equatable {
    public let policyVersion: Int
    public let policyID: String
    public let applicationPackageID: String
    public let helperServiceID: String
    public let allowedApplicationSigner: HelperPolicySigner
    public let allowedHelperSigner: HelperPolicySigner
    public let minimumHelperProtocolVersion: Int
    public let canonicalSHA256: String

    static func load(
        sealedJSON: Data,
        expectedSHA256: String
    ) throws -> HelperPolicy {
        guard HelperProtocolValidation.isSHA256(expectedSHA256),
              HelperSHA256.hex(sealedJSON) == expectedSHA256 else {
            throw HelperPolicyError.digestMismatch
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: sealedJSON)
        } catch {
            throw HelperPolicyError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw HelperPolicyError.invalidPolicy
        }
        try requireExactKeys(
            object,
            expected: [
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
        try validateAuthorityArrays(object)
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let canonicalText = String(decoding: canonical, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        guard Data(canonicalText.utf8) == sealedJSON else {
            throw HelperPolicyError.nonCanonicalJSON
        }
        guard let policyVersion = integer(object["policyVersion"]),
              policyVersion >= 1,
              let policyID = nonemptyString(object["policyId"]),
              let applicationPackageID = nonemptyString(
                  object["applicationPackageId"]
              ),
              let helperServiceID = nonemptyString(object["helperServiceId"]),
              let minimumProtocol = integer(
                  object["minimumHelperProtocolVersion"]
              ),
              minimumProtocol >= 1 else {
            throw HelperPolicyError.invalidPolicy
        }
        return HelperPolicy(
            policyVersion: policyVersion,
            policyID: policyID,
            applicationPackageID: applicationPackageID,
            helperServiceID: helperServiceID,
            allowedApplicationSigner: try signer(
                object["allowedApplicationSigner"]
            ),
            allowedHelperSigner: try signer(object["allowedHelperSigner"]),
            minimumHelperProtocolVersion: minimumProtocol,
            canonicalSHA256: expectedSHA256
        )
    }

    private static func signer(_ value: Any?) throws -> HelperPolicySigner {
        guard let object = value as? [String: Any] else {
            throw HelperPolicyError.invalidPolicy
        }
        try requireExactKeys(object, expected: ["kind", "value"])
        guard let kind = nonemptyString(object["kind"]),
              let signerValue = nonemptyString(object["value"]),
              [
                  "appleDesignatedRequirement",
                  "authenticodePublisher",
                  "sha256",
              ].contains(kind),
              !signerValue.contains("*"),
              !signerValue.contains("?") else {
            throw HelperPolicyError.invalidPolicy
        }
        return HelperPolicySigner(kind: kind, value: signerValue)
    }

    private static func validateAuthorityArrays(
        _ object: [String: Any]
    ) throws {
        guard let targets = object["allowedTargetClasses"] as? [String],
              !targets.isEmpty,
              let roots = object["allowedInstallRoots"] as? [String],
              let releaseKeys = object["releaseRootPublicKeys"]
                  as? [[String: Any]],
              !releaseKeys.isEmpty,
              let strategies = object["allowedStrategies"]
                  as? [[String: Any]],
              !strategies.isEmpty else {
            throw HelperPolicyError.invalidPolicy
        }
        _ = roots
        for key in releaseKeys {
            try requireExactKeys(
                key,
                expected: ["keyId", "algorithm", "publicKeyBase64"]
            )
        }
        for strategy in strategies {
            try requireExactKeys(
                strategy,
                expected: ["strategy", "provider"]
            )
        }
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        expected: Set<String>
    ) throws {
        guard Set(object.keys) == expected else {
            throw HelperPolicyError.unknownOrMissingField
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              !["c", "f", "d"].contains(String(cString: number.objCType)) else {
            return nil
        }
        return number.intValue
    }
}

public enum HelperPolicyError: Error, Equatable {
    case digestMismatch
    case invalidJSON
    case invalidPolicy
    case nonCanonicalJSON
    case unknownOrMissingField
}
