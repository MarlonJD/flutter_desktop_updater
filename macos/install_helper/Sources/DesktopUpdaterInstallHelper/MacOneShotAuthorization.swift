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
        try validateCodeSignature(
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
            signerIdentity: applicationRequirement,
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
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
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
    ) throws {
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
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
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
    }
}

struct MacStageInstallEvidence {
    let stageURL: URL
    let payloadIdentity: MacVerifiedPayloadIdentity
    let verifier: any MacInstallPayloadVerifying
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
        guard request.strategy == "directoryReplace",
              request.provider == "platformDirectory" else {
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
              caller.signerIdentity
                == policy.allowedApplicationSigner.value,
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
            == request.stage.pathHint,
            stage.payloadIdentity.packageIdentifier == request.packageID,
            stage.payloadIdentity.provenanceSHA256
                == request.stage.provenanceSHA256 else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
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

    init(
        policy: MacSealedInstallPolicyV1,
        helperEndpointIdentitySHA256: String,
        requestValidator: any MacOneShotInstallRequestValidating
    ) {
        self.policy = policy
        self.helperEndpointIdentitySHA256 =
            helperEndpointIdentitySHA256
        self.requestValidator = requestValidator
    }

    func authorize(
        _ request: NativeInstallTransactionRequestV1
    ) throws -> MacFileTransaction {
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
        return try MacFileTransaction(
            targetURL: URL(fileURLWithPath: request.target.pathHint),
            stageURL: stage.stageURL,
            transactionID: request.transactionID,
            ownerProcessIdentifier:
                Int32(request.caller.processIdentifier),
            expectedPayloadIdentity: stage.payloadIdentity,
            verifier: stage.verifier
        )
    }
}
