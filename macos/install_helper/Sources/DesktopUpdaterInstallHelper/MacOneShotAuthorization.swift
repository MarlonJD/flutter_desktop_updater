import Darwin
import Foundation
import Security

enum MacOneShotAuthorizationError: Error, Equatable {
    case invalidHelperIdentity
    case callerAuthenticationFailed
    case targetAuthenticationFailed
    case stageAuthenticationFailed
    case unsupportedStrategy
}

struct MacCallerInstallEvidence: Equatable {
    let processIdentifier: Int64
    let processStartIdentity: String
    let executableSHA256: String
    let signerIdentity: String
    let packageID: String
    let targetURL: URL
    let currentVersion: String
    let currentBuildNumber: Int64
    let currentPackageIdentitySHA256: String
    let targetIdentityProofSHA256: String
}

protocol MacCallerInstallEvidenceInspecting: AnyObject {
    func inspect(
        processIdentifier: Int64,
        targetURL: URL,
        executableRelativePath: String,
        applicationRequirement: String
    ) throws -> MacCallerInstallEvidence
}

final class SystemMacCallerInstallEvidenceInspector:
    MacCallerInstallEvidenceInspecting
{
    func inspect(
        processIdentifier: Int64,
        targetURL: URL,
        executableRelativePath: String,
        applicationRequirement: String
    ) throws -> MacCallerInstallEvidence {
        guard processIdentifier > 0,
              processIdentifier <= Int64(Int32.max) else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        let pid = Int32(processIdentifier)
        let canonicalTarget = targetURL.standardizedFileURL
        guard canonicalTarget.path == targetURL.path,
              let info = Bundle(url: canonicalTarget)?.infoDictionary,
              let packageID = info["CFBundleIdentifier"] as? String,
              let executableName = info["CFBundleExecutable"] as? String,
              executableRelativePath
                == "Contents/MacOS/\(executableName)",
              let version = info["CFBundleShortVersionString"] as? String,
              let buildText = info["CFBundleVersion"] as? String,
              let buildNumber = Int64(buildText),
              buildNumber >= 0 else {
            throw MacOneShotAuthorizationError.targetAuthenticationFailed
        }
        let executableURL = canonicalTarget.appendingPathComponent(
            executableRelativePath
        ).standardizedFileURL
        guard try runningExecutablePath(pid: pid)
            == executableURL.resolvingSymlinksInPath().path else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        let signerIdentity = try validateCodeSignature(
            at: canonicalTarget,
            requirement: applicationRequirement,
            packageID: packageID
        )
        let executableData = try Data(
            contentsOf: executableURL,
            options: [.mappedIfSafe]
        )
        let executableSHA256 = macPrivilegeSHA256(executableData)
        let packageIdentity = macPrivilegeSHA256(
            Data(
                "\(packageID)\n\(version)\n\(buildNumber)\n"
                    .appending(executableSHA256).utf8
            )
        )
        return MacCallerInstallEvidence(
            processIdentifier: processIdentifier,
            processStartIdentity: try processStartIdentity(pid: pid),
            executableSHA256: executableSHA256,
            signerIdentity: signerIdentity,
            packageID: packageID,
            targetURL: canonicalTarget,
            currentVersion: version,
            currentBuildNumber: buildNumber,
            currentPackageIdentitySHA256: packageIdentity,
            targetIdentityProofSHA256: executableSHA256
        )
    }

    private func runningExecutablePath(pid: Int32) throws -> String {
        var buffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        let count = buffer.withUnsafeMutableBufferPointer { storage -> Int32 in
            guard let baseAddress = storage.baseAddress else {
                return 0
            }
            return proc_pidpath(
                pid,
                baseAddress,
                UInt32(storage.count)
            )
        }
        guard count > 0 else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath().path
    }

    private func processStartIdentity(pid: Int32) throws -> String {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(size)
        ) == size else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        return "macos:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    private func validateCodeSignature(
        at bundleURL: URL,
        requirement: String,
        packageID: String
    ) throws -> String {
        var code: SecStaticCode?
        var requirementObject: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code)
            == errSecSuccess,
            let code,
            SecRequirementCreateWithString(
                requirement as CFString,
                [],
                &requirementObject
            ) == errSecSuccess,
            let requirementObject,
            SecStaticCodeCheckValidity(
                code,
                // macOS may attach protected provenance metadata after the
                // installed app launches. Caller authentication still checks
                // the executable and designated requirement, but runtime
                // metadata must not invalidate the sealed code identity.
                SecCSFlags(rawValue: kSecCSDoNotValidateResources),
                requirementObject
            ) == errSecSuccess else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String
                == packageID else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        var designatedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            code,
            [],
            &designatedRequirement
        ) == errSecSuccess,
            let designatedRequirement else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        var designatedRequirementText: CFString?
        guard SecRequirementCopyString(
            designatedRequirement,
            [],
            &designatedRequirementText
        ) == errSecSuccess,
            let designatedRequirementText else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        return designatedRequirementText as String
    }
}

enum MacStageInstallPayload {
    case bundle(
        identity: MacVerifiedPayloadIdentity,
        verifier: any MacInstallPayloadVerifying
    )
    case verifiedInstaller(
        expectation: MacVerifiedInstallerExpectation,
        handoff: MacVerifiedInstallerHandoff
    )
}

struct MacStageInstallEvidence {
    let stageURL: URL
    let payload: MacStageInstallPayload

    init(
        stageURL: URL,
        payloadIdentity: MacVerifiedPayloadIdentity,
        verifier: any MacInstallPayloadVerifying
    ) {
        self.stageURL = stageURL
        payload = .bundle(identity: payloadIdentity, verifier: verifier)
    }

    init(
        stageURL: URL,
        installerExpectation: MacVerifiedInstallerExpectation,
        handoff: MacVerifiedInstallerHandoff
    ) {
        self.stageURL = stageURL
        payload = .verifiedInstaller(
            expectation: installerExpectation,
            handoff: handoff
        )
    }

    var payloadIdentity: MacVerifiedPayloadIdentity {
        guard case let .bundle(identity, _) = payload else {
            preconditionFailure("Installer evidence has no bundle identity.")
        }
        return identity
    }

    var verifier: any MacInstallPayloadVerifying {
        guard case let .bundle(_, verifier) = payload else {
            preconditionFailure("Installer evidence has no bundle verifier.")
        }
        return verifier
    }
}

protocol MacStageInstallEvidenceInspecting: AnyObject {
    func inspect(
        request: NativeInstallTransactionRequestV1,
        policy: MacSealedInstallPolicyV1
    ) throws -> MacStageInstallEvidence
}

protocol MacOneShotInstallRequestValidating: AnyObject {
    func validate(
        _ request: NativeInstallTransactionRequestV1,
        policy: MacSealedInstallPolicyV1
    ) throws -> MacStageInstallEvidence
}

final class MacOneShotInstallRequestValidator:
    MacOneShotInstallRequestValidating
{
    private let parentProcessIdentifier: () -> Int32
    private let callerInspector: any MacCallerInstallEvidenceInspecting
    private let stageInspector: any MacStageInstallEvidenceInspecting

    init(
        parentProcessIdentifier: @escaping () -> Int32,
        callerInspector: any MacCallerInstallEvidenceInspecting,
        stageInspector: any MacStageInstallEvidenceInspecting
    ) {
        self.parentProcessIdentifier = parentProcessIdentifier
        self.callerInspector = callerInspector
        self.stageInspector = stageInspector
    }

    func validate(
        _ request: NativeInstallTransactionRequestV1,
        policy: MacSealedInstallPolicyV1
    ) throws -> MacStageInstallEvidence {
        let isDirectory = request.strategy == "directoryReplace"
            && request.provider == "platformDirectory"
        let isInstaller = request.strategy == "verifiedInstallerHandoff"
            && request.provider == "macosInstaller"
        guard isDirectory || isInstaller else {
            throw MacOneShotAuthorizationError.unsupportedStrategy
        }
        let targetURL = URL(fileURLWithPath: request.target.pathHint)
            .standardizedFileURL
        do {
            try policy.authorize(
                request,
                canonicalTargetURL: targetURL
            )
        } catch {
            throw MacOneShotAuthorizationError.targetAuthenticationFailed
        }
        guard request.caller.processIdentifier <= Int64(Int32.max),
              Int32(request.caller.processIdentifier)
                == parentProcessIdentifier() else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        let caller: MacCallerInstallEvidence
        do {
            caller = try callerInspector.inspect(
                processIdentifier: request.caller.processIdentifier,
                targetURL: targetURL,
                executableRelativePath:
                    request.target.executableRelativePath,
                applicationRequirement:
                    policy.allowedApplicationSigner.value
            )
        } catch {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        guard caller.processIdentifier == request.caller.processIdentifier,
              caller.processStartIdentity
                == request.caller.processStartIdentity,
              caller.executableSHA256 == request.caller.executableSHA256,
              caller.signerIdentity == request.caller.signerIdentity,
              caller.packageID == request.packageID,
              caller.packageID == policy.applicationPackageID,
              caller.targetURL.standardizedFileURL == targetURL,
              caller.currentVersion == request.currentIdentity.version,
              caller.currentBuildNumber
                == request.currentIdentity.buildNumber,
              caller.currentPackageIdentitySHA256
                == request.currentIdentity.packageIdentitySHA256,
              caller.targetIdentityProofSHA256
                == request.target.identityProofSHA256 else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        let stage: MacStageInstallEvidence
        do {
            stage = try stageInspector.inspect(
                request: request,
                policy: policy
            )
        } catch {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        guard stage.stageURL.standardizedFileURL.path
            == request.stage.pathHint else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        switch stage.payload {
        case let .bundle(identity, _):
            guard isDirectory,
                  identity.packageIdentifier == request.packageID,
                  identity.provenanceSHA256
                    == request.stage.provenanceSHA256 else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
        case let .verifiedInstaller(expectation, _):
            guard isInstaller,
                  expectation.installerURL.standardizedFileURL.path
                    == URL(fileURLWithPath: request.stage.pathHint)
                        .appendingPathComponent("installer.pkg").path,
                  expectation.targetURL.standardizedFileURL.path
                    == targetURL.path,
                  expectation.packageIdentifier == request.packageID,
                  expectation.expectedVersion
                    == request.desiredIdentity.version,
                  expectation.expectedBuildNumber
                    == request.desiredIdentity.buildNumber,
                  expectation.designatedRequirement
                    == policy.allowedApplicationSigner.value,
                  expectation.artifactSHA256
                    == request.stage.artifactSHA256,
                  expectation.descriptorSHA256
                    == request.signedDescriptor.canonicalSHA256,
                  expectation.provenanceSHA256
                    == request.stage.provenanceSHA256 else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
        }
        return stage
    }
}

final class SealedMacOneShotInstallAuthorizer:
    MacOneShotInstallAuthorizing
{
    let helperEndpointIdentitySHA256: String
    private let policy: MacSealedInstallPolicyV1
    private let requestValidator: any MacOneShotInstallRequestValidating
    private let preserveTargetOwnership: Bool
    private let diagnostics: any MacHelperDiagnosticsRecording

    init(
        policy: MacSealedInstallPolicyV1,
        helperEndpointIdentitySHA256: String,
        requestValidator: any MacOneShotInstallRequestValidating,
        preserveTargetOwnership: Bool = false,
        diagnostics: any MacHelperDiagnosticsRecording =
            NoMacHelperDiagnosticsRecorder()
    ) {
        self.policy = policy
        self.helperEndpointIdentitySHA256 =
            helperEndpointIdentitySHA256
        self.requestValidator = requestValidator
        self.preserveTargetOwnership = preserveTargetOwnership
        self.diagnostics = diagnostics
    }

    func authorize(
        _ request: NativeInstallTransactionRequestV1
    ) throws -> any MacPreparedInstallTransaction {
        guard helperEndpointIdentitySHA256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw MacOneShotAuthorizationError.invalidHelperIdentity
        }
        let stage = try requestValidator.validate(
            request,
            policy: policy
        )
        guard request.caller.processIdentifier <= Int64(Int32.max) else {
            throw MacOneShotAuthorizationError.callerAuthenticationFailed
        }
        switch stage.payload {
        case let .bundle(identity, verifier):
            return try MacFileTransaction(
                targetURL: URL(fileURLWithPath: request.target.pathHint),
                stageURL: stage.stageURL,
                transactionID: request.transactionID,
                ownerProcessIdentifier:
                    Int32(request.caller.processIdentifier),
                expectedPayloadIdentity: identity,
                verifier: verifier,
                preserveTargetOwnership: preserveTargetOwnership,
                diagnostics: diagnostics
            )
        case let .verifiedInstaller(expectation, handoff):
            return try MacVerifiedInstallerTransaction(
                transactionID: request.transactionID,
                ownerProcessIdentifier:
                    Int32(request.caller.processIdentifier),
                ownerProcessStartIdentity:
                    request.caller.processStartIdentity,
                policyID: policy.policyID,
                policySHA256: policy.canonicalSHA256,
                expectation: expectation,
                handoff: handoff,
                diagnostics: diagnostics
            )
        }
    }
}
