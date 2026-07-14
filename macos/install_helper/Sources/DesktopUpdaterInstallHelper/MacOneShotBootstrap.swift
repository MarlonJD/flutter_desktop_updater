import Darwin
import Foundation
import Security

final class SystemMacOneShotServiceRuntime: MacOneShotServiceRunning {
    let helperEndpointIdentitySHA256: String
    private let runtime: MacOneShotServiceRuntime
    private let channel: any MacOneShotWireChannel

    init(
        helperEndpointIdentitySHA256: String,
        runtime: MacOneShotServiceRuntime,
        channel: any MacOneShotWireChannel
    ) {
        self.helperEndpointIdentitySHA256 =
            helperEndpointIdentitySHA256
        self.runtime = runtime
        self.channel = channel
    }

    func run() throws {
        try runtime.run(channel: channel)
    }
}

enum MacOneShotBootstrap {
    static func makeRuntime(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        executableURL: URL? = Bundle.main.executableURL,
        identityChecker: any MacSignedExecutableIdentityChecking =
            SecurityMacSignedExecutableIdentityChecker()
    ) throws -> SystemMacOneShotServiceRuntime {
        let policy = try MacSealedInstallPolicyV1.load(
            infoDictionary: infoDictionary ?? [:]
        )
        guard policy.allowedHelperSigner.kind
                == "appleDesignatedRequirement",
              let executableURL else {
            throw MacOneShotAuthorizationError.invalidHelperIdentity
        }
        let canonicalExecutable = executableURL.standardizedFileURL
        let identity: MacSignedExecutableIdentity
        do {
            identity = try identityChecker.identity(
                at: canonicalExecutable,
                requirement: policy.allowedHelperSigner.value
            )
        } catch {
            throw MacOneShotAuthorizationError.invalidHelperIdentity
        }
        guard identity.isSignatureValid,
              identity.bundleIdentifier == policy.helperServiceID,
              identity.designatedRequirement
                == policy.allowedHelperSigner.value else {
            throw MacOneShotAuthorizationError.invalidHelperIdentity
        }
        let endpointIdentity: String
        do {
            endpointIdentity = macPrivilegeSHA256(
                try Data(
                    contentsOf: canonicalExecutable,
                    options: [.mappedIfSafe]
                )
            )
        } catch {
            throw MacOneShotAuthorizationError.invalidHelperIdentity
        }
        let validator = MacOneShotInstallRequestValidator(
            parentProcessIdentifier: { Darwin.getppid() },
            callerInspector: SystemMacCallerInstallEvidenceInspector(),
            stageInspector: SystemMacStageInstallEvidenceInspector()
        )
        let authorizer = SealedMacOneShotInstallAuthorizer(
            policy: policy,
            helperEndpointIdentitySHA256: endpointIdentity,
            requestValidator: validator
        )
        let session = MacOneShotInstallSession(
            authorizer: authorizer,
            readyTokenGenerator: secureReadyToken,
            nowUnixMilliseconds: unixMilliseconds,
            reservationLifetimeMilliseconds: 300_000
        )
        return SystemMacOneShotServiceRuntime(
            helperEndpointIdentitySHA256: endpointIdentity,
            runtime: MacOneShotServiceRuntime(
                session: session,
                callerMonitorFactory: SystemMacCallerExitMonitorFactory()
            ),
            channel: MacLengthPrefixedFileHandleChannel(
                input: .standardInput,
                output: .standardOutput
            )
        )
    }

    private static func secureReadyToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            throw MacOneShotInstallError.invalidReadyToken
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
