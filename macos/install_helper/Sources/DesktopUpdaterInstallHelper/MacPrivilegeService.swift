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
                == configuration.serviceIdentifier else {
            throw MacPrivilegeError.signedIdentityMismatch
        }
        let peerRequirement = try MacXPCPeerRequirement.make(
            applicationRequirement: configuration.applicationRequirement,
            helperTeamIdentifier: helperIdentity.teamIdentifier
        )
        MacPrivilegedXPCServer(
            configuration: configuration,
            peerRequirement: peerRequirement
        ).run()
    }
}

@available(macOS 12.0, *)
private final class MacPrivilegedXPCServer {
    private let configuration: MacPrivilegeConfiguration
    private let peerRequirement: String

    init(
        configuration: MacPrivilegeConfiguration,
        peerRequirement: String
    ) {
        self.configuration = configuration
        self.peerRequirement = peerRequirement
    }

    func run() -> Never {
        let requirement = peerRequirement
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
                      ),
                      String(cString: operation) == "health",
                      let reply = xpc_dictionary_create_reply(message) else {
                    xpc_connection_cancel(connection)
                    return
                }
                xpc_dictionary_set_bool(reply, "ok", true)
                xpc_dictionary_set_int64(reply, "protocolVersion", 1)
                xpc_connection_send_message(connection, reply)
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
