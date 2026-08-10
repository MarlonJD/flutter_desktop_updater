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

final class SystemMacPersistentRecoveryServiceRuntime:
    MacOneShotServiceRunning
{
    let helperEndpointIdentitySHA256: String
    private let runtime: MacPersistentRecoveryWireRuntime

    init(
        helperEndpointIdentitySHA256: String,
        runtime: MacPersistentRecoveryWireRuntime
    ) {
        self.helperEndpointIdentitySHA256 = helperEndpointIdentitySHA256
        self.runtime = runtime
    }

    func run() throws {
        try runtime.run()
    }
}

enum MacOneShotBootstrap {
    private struct AuthenticatedHelper {
        let policy: MacSealedInstallPolicyV1
        let endpointIdentitySHA256: String
    }

    static func makeRuntime(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        executableURL: URL? = Bundle.main.executableURL,
        identityChecker: any MacSignedExecutableIdentityChecking =
            SecurityMacSignedExecutableIdentityChecker()
    ) throws -> SystemMacOneShotServiceRuntime {
        let helper = try authenticateHelper(
            infoDictionary: infoDictionary,
            executableURL: executableURL,
            identityChecker: identityChecker
        )
        let validator = MacOneShotInstallRequestValidator(
            parentProcessIdentifier: { Darwin.getppid() },
            callerInspector: SystemMacCallerInstallEvidenceInspector(),
            stageInspector: SystemMacStageInstallEvidenceInspector()
        )
        let diagnostics = MacHelperDiagnosticsRecorder()
        diagnostics.record(
            .helperScheduled,
            state: "starting",
            resultCode: "success",
            detailCode: "oneShot"
        )
        let authorizerWithDiagnostics = SealedMacOneShotInstallAuthorizer(
            policy: helper.policy,
            helperEndpointIdentitySHA256:
                helper.endpointIdentitySHA256,
            requestValidator: validator,
            diagnostics: diagnostics
        )
        let session = MacOneShotInstallSession(
            authorizer: authorizerWithDiagnostics,
            readyTokenGenerator: secureReadyToken,
            nowUnixMilliseconds: unixMilliseconds,
            reservationLifetimeMilliseconds: 300_000
        )
        return SystemMacOneShotServiceRuntime(
            helperEndpointIdentitySHA256:
                helper.endpointIdentitySHA256,
            runtime: MacOneShotServiceRuntime(
                session: session,
                callerMonitorFactory: SystemMacCallerExitMonitorFactory(),
                diagnostics: diagnostics
            ),
            channel: MacLengthPrefixedFileHandleChannel(
                input: .standardInput,
                output: .standardOutput
            )
        )
    }

    static func makeRecoveryRuntime(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        executableURL: URL? = Bundle.main.executableURL,
        identityChecker: any MacSignedExecutableIdentityChecking =
            SecurityMacSignedExecutableIdentityChecker()
    ) throws -> SystemMacPersistentRecoveryServiceRuntime {
        let helper = try authenticateHelper(
            infoDictionary: infoDictionary,
            executableURL: executableURL,
            identityChecker: identityChecker
        )
        let diagnostics = MacHelperDiagnosticsRecorder()
        diagnostics.record(
            .helperScheduled,
            state: "starting",
            resultCode: "success",
            detailCode: "recovery"
        )
        let service = MacPersistentRecoveryService(
            policy: helper.policy,
            callerAuthenticator: SystemMacRecoveryCallerAuthenticator(),
            verifierFactory: SystemMacRecoveryPayloadVerifierFactory(),
            installerVerifierFactory:
                SystemMacVerifiedInstallerCheckerFactory(),
            diagnostics: diagnostics
        )
        return SystemMacPersistentRecoveryServiceRuntime(
            helperEndpointIdentitySHA256:
                helper.endpointIdentitySHA256,
            runtime: MacPersistentRecoveryWireRuntime(
                service: service,
                channel: MacLengthPrefixedFileHandleChannel(
                    input: .standardInput,
                    output: .standardOutput
                )
            )
        )
    }

    private static func authenticateHelper(
        infoDictionary: [String: Any]?,
        executableURL: URL?,
        identityChecker: any MacSignedExecutableIdentityChecking
    ) throws -> AuthenticatedHelper {
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
        return AuthenticatedHelper(
            policy: policy,
            endpointIdentitySHA256: endpointIdentity
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
