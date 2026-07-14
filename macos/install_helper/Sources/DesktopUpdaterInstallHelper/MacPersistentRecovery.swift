import Darwin
import Foundation
import Security

protocol MacRecoveryCallerAuthenticating: AnyObject {
    func authenticate(policy: MacSealedInstallPolicyV1) throws
}

protocol MacRecoveryPayloadVerifierCreating: AnyObject {
    func makeVerifier(
        expectedIdentity: MacVerifiedPayloadIdentity
    ) throws -> any MacInstallPayloadVerifying
}

struct MacPersistentTransactionStatusV1: Equatable {
    let protocolVersion: Int
    let transactionID: String
    let state: String
    let resultCode: String
    let journalSHA256: String
}

struct MacPersistentRecoveryResultV1: Equatable {
    let protocolVersion: Int
    let transactionID: String
    let resultCode: String
    let verifiedOutcome: String
    let journalSHA256: String
}

enum MacPersistentRecoveryError: Error, Equatable {
    case invalidTransactionID
    case ambiguousTransaction
    case journalCorrupt
    case callerAuthenticationFailed
}

final class MacPersistentRecoveryService {
    private struct LocatedTransaction {
        let targetURL: URL
        let journal: MacTransactionJournal
        let journalSHA256: String
    }

    private let policy: MacSealedInstallPolicyV1
    private let callerAuthenticator: any MacRecoveryCallerAuthenticating
    private let verifierFactory: any MacRecoveryPayloadVerifierCreating

    var policyID: String { policy.policyID }

    init(
        policy: MacSealedInstallPolicyV1,
        callerAuthenticator: any MacRecoveryCallerAuthenticating,
        verifierFactory: any MacRecoveryPayloadVerifierCreating
    ) {
        self.policy = policy
        self.callerAuthenticator = callerAuthenticator
        self.verifierFactory = verifierFactory
    }

    func query(transactionID: String) throws
        -> MacPersistentTransactionStatusV1
    {
        try authenticateAndValidate(transactionID)
        guard let located = try locate(transactionID: transactionID) else {
            return MacPersistentTransactionStatusV1(
                protocolVersion: 1,
                transactionID: transactionID,
                state: "completed",
                resultCode: "completed",
                journalSHA256: String(repeating: "0", count: 64)
            )
        }
        return MacPersistentTransactionStatusV1(
            protocolVersion: 1,
            transactionID: transactionID,
            state: located.journal.state.rawValue,
            resultCode: located.journal.state == .completed
                ? "completed" : "recoveryRequired",
            journalSHA256: located.journalSHA256
        )
    }

    func recover(transactionID: String) throws
        -> MacPersistentRecoveryResultV1
    {
        try authenticateAndValidate(transactionID)
        guard let located = try locate(transactionID: transactionID) else {
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: "completed",
                verifiedOutcome: "none",
                journalSHA256: String(repeating: "0", count: 64)
            )
        }
        let verifier = try verifierFactory.makeVerifier(
            expectedIdentity: located.journal.expectedPayloadIdentity
        )
        let outcome = try MacRecoveryService(
            targetURL: located.targetURL,
            transactionID: transactionID,
            expectedPayloadIdentity:
                located.journal.expectedPayloadIdentity,
            verifier: verifier
        ).recover()
        switch outcome {
        case .liveOwner:
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: "recoveryRequired",
                verifiedOutcome: "none",
                journalSHA256: located.journalSHA256
            )
        case .nothingToRecover:
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: "completed",
                verifiedOutcome: "none",
                journalSHA256: located.journalSHA256
            )
        case .recovered:
            let installed = (try? verifier.verifyPayload(
                at: located.targetURL
            )) == located.journal.expectedPayloadIdentity
            return MacPersistentRecoveryResultV1(
                protocolVersion: 1,
                transactionID: transactionID,
                resultCode: installed ? "completed" : "rolledBack",
                verifiedOutcome: installed ? "newTarget" : "oldTarget",
                journalSHA256: located.journalSHA256
            )
        }
    }

    private func authenticateAndValidate(_ transactionID: String) throws {
        guard transactionID == transactionID.lowercased(),
              let uuid = UUID(uuidString: transactionID),
              uuid.uuidString.lowercased() == transactionID else {
            throw MacPersistentRecoveryError.invalidTransactionID
        }
        do {
            try callerAuthenticator.authenticate(policy: policy)
        } catch {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
    }

    private func locate(transactionID: String) throws
        -> LocatedTransaction?
    {
        let suffix = ".desktop-updater-\(transactionID).journal.json"
        var matches: [LocatedTransaction] = []
        for root in policy.allowedInstallRoots {
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: rootURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                continue
            }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(
                    atPath: rootURL.path
                )
            } catch {
                throw MacPersistentRecoveryError.journalCorrupt
            }
            for name in names where name.hasPrefix(".")
                && name.hasSuffix(suffix) {
                let end = name.index(name.endIndex, offsetBy: -suffix.count)
                let targetName = String(name[name.index(after: name.startIndex)..<end])
                guard persistentSimpleName(targetName) else {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
                let paths: MacTransactionPaths
                let directory: MacTransactionDirectory
                do {
                    paths = try MacTransactionPaths(
                        targetName: targetName,
                        transactionID: transactionID
                    )
                    directory = try MacTransactionDirectory(url: rootURL)
                } catch {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
                let store = DurableTransactionJournalStore(
                    directory: directory,
                    paths: paths
                )
                do {
                    guard let journal = try store.load(),
                          journal.transactionID == transactionID,
                          journal.targetName == targetName else {
                        throw MacPersistentRecoveryError.journalCorrupt
                    }
                    matches.append(
                        LocatedTransaction(
                            targetURL: rootURL.appendingPathComponent(
                                targetName
                            ),
                            journal: journal,
                            journalSHA256: try store.sha256()
                        )
                    )
                } catch let error as MacPersistentRecoveryError {
                    throw error
                } catch {
                    throw MacPersistentRecoveryError.journalCorrupt
                }
            }
        }
        guard matches.count <= 1 else {
            throw MacPersistentRecoveryError.ambiguousTransaction
        }
        return matches.first
    }
}

enum MacPersistentRecoveryWireError: Error, Equatable {
    case invalidRequest
}

final class MacPersistentRecoveryWireRuntime: MacOneShotServiceRunning {
    private let service: MacPersistentRecoveryService
    private let channel: any MacOneShotWireChannel

    init(
        service: MacPersistentRecoveryService,
        channel: any MacOneShotWireChannel
    ) {
        self.service = service
        self.channel = channel
    }

    func run() throws {
        let data = try channel.readFrame()
        guard try NativeStrictJSON.canonicalize(data) == data,
              let request = try NativeStrictJSON.decode(data)
                as? [String: Any],
              Set(request.keys) == [
                  "operation", "policyId", "protocolVersion",
                  "transactionId",
              ],
              persistentInteger(request["protocolVersion"]) == 1,
              request["policyId"] as? String == service.policyID,
              let operation = request["operation"] as? String,
              ["queryTransaction", "recoverPendingInstall"]
                .contains(operation),
              let transactionID = request["transactionId"] as? String else {
            throw MacPersistentRecoveryWireError.invalidRequest
        }
        if operation == "queryTransaction" {
            let status = try service.query(transactionID: transactionID)
            try channel.writeFrame(
                try persistentCanonicalData([
                    "protocolVersion": status.protocolVersion,
                    "transactionId": status.transactionID,
                    "state": status.state,
                    "resultCode": status.resultCode,
                    "journalSha256": status.journalSHA256,
                ])
            )
        } else {
            let result = try service.recover(transactionID: transactionID)
            try channel.writeFrame(
                try persistentCanonicalData([
                    "protocolVersion": result.protocolVersion,
                    "transactionId": result.transactionID,
                    "resultCode": result.resultCode,
                    "verifiedOutcome": result.verifiedOutcome,
                    "journalSha256": result.journalSHA256,
                ])
            )
        }
    }
}

private func persistentCanonicalData(_ value: Any) throws -> Data {
    try NativeStrictJSON.canonicalize(
        JSONSerialization.data(withJSONObject: value)
    )
}

private func persistentInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)) else {
        return nil
    }
    let result = number.int64Value
    return NSNumber(value: result) == number ? result : nil
}

final class SystemMacRecoveryCallerAuthenticator:
    MacRecoveryCallerAuthenticating
{
    private let processIdentifier: () -> Int32

    init(processIdentifier: @escaping () -> Int32 = { Darwin.getppid() }) {
        self.processIdentifier = processIdentifier
    }

    func authenticate(policy: MacSealedInstallPolicyV1) throws {
        guard policy.allowedApplicationSigner.kind
                == "appleDesignatedRequirement" else {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
        let pid = processIdentifier()
        guard pid > 0 else {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
        let attributes = NSDictionary(
            object: NSNumber(value: pid),
            forKey: kSecGuestAttributePid as String as NSString
        )
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess,
            let code,
            SecRequirementCreateWithString(
                policy.allowedApplicationSigner.value as CFString,
                [],
                &requirement
            ) == errSecSuccess,
            let requirement,
            SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
            signingIdentifier(code) == policy.applicationPackageID else {
            throw MacPersistentRecoveryError.callerAuthenticationFailed
        }
    }

    private func signingIdentifier(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode,
            SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any] else {
            return nil
        }
        return values[kSecCodeInfoIdentifier as String] as? String
    }
}

final class SystemMacRecoveryPayloadVerifierFactory:
    MacRecoveryPayloadVerifierCreating
{
    func makeVerifier(
        expectedIdentity: MacVerifiedPayloadIdentity
    ) throws -> any MacInstallPayloadVerifying {
        MacJournalPayloadVerifier(expectedIdentity: expectedIdentity)
    }
}

private final class MacJournalPayloadVerifier: MacInstallPayloadVerifying {
    private let expectedIdentity: MacVerifiedPayloadIdentity

    init(expectedIdentity: MacVerifiedPayloadIdentity) {
        self.expectedIdentity = expectedIdentity
    }

    func verifyPayload(at bundleURL: URL) throws -> MacVerifiedPayloadIdentity {
        let canonical = bundleURL.standardizedFileURL
        let info = try PropertyListSerialization.propertyList(
            from: Data(
                contentsOf: canonical.appendingPathComponent(
                    "Contents/Info.plist"
                )
            ),
            options: [],
            format: nil
        )
        guard let dictionary = info as? [String: Any],
              dictionary["CFBundleIdentifier"] as? String
                == expectedIdentity.packageIdentifier,
              let executableName = dictionary["CFBundleExecutable"]
                as? String,
              persistentSimpleName(executableName) else {
            throw MacPayloadVerificationError.invalidBundle
        }
        let executable = try Data(
            contentsOf: canonical.appendingPathComponent(
                "Contents/MacOS/\(executableName)"
            ),
            options: [.mappedIfSafe]
        )
        guard macPrivilegeSHA256(executable)
                == expectedIdentity.executableSHA256,
              try macAuthorizedTreeSHA256(canonical)
                == expectedIdentity.bundleSHA256 else {
            throw MacPayloadVerificationError.executableMismatch
        }
        try macVerifyBundleSignature(
            bundleURL: canonical,
            requirement: expectedIdentity.designatedRequirement
        )
        return expectedIdentity
    }
}

private func persistentSimpleName(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\\")
        && !value.contains("\0")
}
