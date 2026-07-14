import Foundation
import Security

public struct HelperCodeIdentity: Equatable {
    public var bundleIdentifier: String
    public var teamIdentifier: String
    public var designatedRequirement: String
    public var sha256: String
    public var satisfiesRequirement: Bool

    init(
        bundleIdentifier: String,
        teamIdentifier: String,
        designatedRequirement: String,
        sha256: String,
        satisfiesRequirement: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.designatedRequirement = designatedRequirement
        self.sha256 = sha256
        self.satisfiesRequirement = satisfiesRequirement
    }
}

public protocol HelperCodeIdentityChecking {
    func runningCodeIdentity(
        auditToken: Data,
        requirement: String
    ) throws -> HelperCodeIdentity

    func staticCodeIdentity(
        at url: URL,
        requirement: String
    ) throws -> HelperCodeIdentity
}

public struct AuthenticatedHelperSession: Equatable {
    public let transactionID: String
    public let applicationBundleIdentifier: String
    public let helperBundleIdentifier: String
    public let policySHA256: String
    public let requestSHA256: String
}

public struct HelperAuthenticator {
    private let policy: HelperPolicy
    private let helperURL: URL
    private let identityChecker: any HelperCodeIdentityChecking

    public init(
        policy: HelperPolicy,
        applicationBundleURL: URL,
        identityChecker: any HelperCodeIdentityChecking =
            SecurityFrameworkHelperCodeIdentityChecker()
    ) {
        self.policy = policy
        helperURL = EmbeddedHelperLocator(
            applicationBundleURL: applicationBundleURL
        ).oneShotHelperURL
        self.identityChecker = identityChecker
    }

    func authenticate(
        _ request: HelperAuthenticationRequestV1,
        peerAuditToken: Data,
        canonicalRequestSHA256: String,
        expectedTransactionNonce: String
    ) throws -> AuthenticatedHelperSession {
        guard request.schemaVersion == 1,
              request.protocolVersion == 1,
              request.protocolVersion >= policy.minimumHelperProtocolVersion,
              HelperProtocolValidation.isTransactionID(request.transactionID),
              request.policyID == policy.policyID,
              request.policySHA256 == policy.canonicalSHA256,
              HelperProtocolValidation.isSHA256(request.requestSHA256),
              request.requestSHA256 == canonicalRequestSHA256,
              HelperProtocolValidation.isSHA256(request.helperSHA256),
              HelperProtocolValidation.isReadyToken(request.transactionNonce),
              request.transactionNonce == expectedTransactionNonce,
              !peerAuditToken.isEmpty,
              request.callerAuditToken == peerAuditToken,
              policy.allowedApplicationSigner.kind
                  == "appleDesignatedRequirement",
              policy.allowedHelperSigner.kind
                  == "appleDesignatedRequirement" else {
            throw HelperAuthenticationError.requestBindingMismatch
        }

        let caller = try identityChecker.runningCodeIdentity(
            auditToken: peerAuditToken,
            requirement: policy.allowedApplicationSigner.value
        )
        let helper = try identityChecker.staticCodeIdentity(
            at: helperURL,
            requirement: policy.allowedHelperSigner.value
        )
        guard caller.satisfiesRequirement,
              helper.satisfiesRequirement,
              caller.bundleIdentifier == policy.applicationPackageID,
              helper.bundleIdentifier == policy.helperServiceID,
              !caller.teamIdentifier.isEmpty,
              caller.teamIdentifier == helper.teamIdentifier,
              caller.designatedRequirement
                  == policy.allowedApplicationSigner.value,
              helper.designatedRequirement == policy.allowedHelperSigner.value,
              helper.sha256 == request.helperSHA256 else {
            throw HelperAuthenticationError.codeIdentityMismatch
        }
        return AuthenticatedHelperSession(
            transactionID: request.transactionID,
            applicationBundleIdentifier: caller.bundleIdentifier,
            helperBundleIdentifier: helper.bundleIdentifier,
            policySHA256: request.policySHA256,
            requestSHA256: request.requestSHA256
        )
    }
}

public enum HelperAuthenticationError: Error, Equatable {
    case requestBindingMismatch
    case codeIdentityMismatch
    case securityFrameworkFailure(OSStatus)
}

public struct SecurityFrameworkHelperCodeIdentityChecker:
    HelperCodeIdentityChecking
{
    public init() {}

    public func runningCodeIdentity(
        auditToken: Data,
        requirement: String
    ) throws -> HelperCodeIdentity {
        let attributes = NSDictionary(
            object: auditToken as NSData,
            forKey: kSecGuestAttributeAudit as String as NSString
        )
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        )
        guard status == errSecSuccess, let code else {
            throw HelperAuthenticationError.securityFrameworkFailure(status)
        }
        let requirementObject = try makeRequirement(requirement)
        let validity = SecCodeCheckValidity(code, [], requirementObject)
        guard validity == errSecSuccess else {
            throw HelperAuthenticationError.securityFrameworkFailure(validity)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw HelperAuthenticationError.securityFrameworkFailure(
                staticStatus
            )
        }
        return try identity(
            signingInformationFor: staticCode,
            designatedRequirement: requirement,
            sha256: ""
        )
    }

    public func staticCodeIdentity(
        at url: URL,
        requirement: String
    ) throws -> HelperCodeIdentity {
        var code: SecStaticCode?
        let creation = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard creation == errSecSuccess, let code else {
            throw HelperAuthenticationError.securityFrameworkFailure(creation)
        }
        let requirementObject = try makeRequirement(requirement)
        let validity = SecStaticCodeCheckValidity(code, [], requirementObject)
        guard validity == errSecSuccess else {
            throw HelperAuthenticationError.securityFrameworkFailure(validity)
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw HelperAuthenticationError.codeIdentityMismatch
        }
        return try identity(
            signingInformationFor: code,
            designatedRequirement: requirement,
            sha256: HelperSHA256.hex(bytes)
        )
    }

    private func makeRequirement(_ source: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            source as CFString,
            [],
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw HelperAuthenticationError.securityFrameworkFailure(status)
        }
        return requirement
    }

    private func identity(
        signingInformationFor code: SecStaticCode,
        designatedRequirement: String,
        sha256: String
    ) throws -> HelperCodeIdentity {
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
            throw HelperAuthenticationError.securityFrameworkFailure(status)
        }
        return HelperCodeIdentity(
            bundleIdentifier: identifier,
            teamIdentifier: team,
            designatedRequirement: designatedRequirement,
            sha256: sha256,
            satisfiesRequirement: true
        )
    }
}
