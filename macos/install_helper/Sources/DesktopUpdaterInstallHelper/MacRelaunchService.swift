import CommonCrypto
import Foundation
import Security

struct MacBundlePayloadExpectation {
    let packageIdentifier: String
    let designatedRequirement: String
    let provenanceSHA256: String
    let executableSHA256: String
}

enum MacPayloadVerificationError: Error, Equatable {
    case invalidBundle
    case packageIdentifierMismatch
    case invalidCodeSignature
    case provenanceMismatch
    case executableMismatch
    case relaunchFailed
}

final class MacBundlePayloadVerifier: MacInstallPayloadVerifying {
    private let expectation: MacBundlePayloadExpectation

    init(expectation: MacBundlePayloadExpectation) {
        self.expectation = expectation
    }

    func verifyPayload(at bundleURL: URL) throws -> MacVerifiedPayloadIdentity {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let infoData: Data
        let info: [String: Any]
        do {
            infoData = try Data(contentsOf: infoURL, options: [.mappedIfSafe])
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw MacPayloadVerificationError.invalidBundle
            }
            info = dictionary
        } catch let error as MacPayloadVerificationError {
            throw error
        } catch {
            throw MacPayloadVerificationError.invalidBundle
        }
        guard info["CFBundleIdentifier"] as? String
            == expectation.packageIdentifier else {
            throw MacPayloadVerificationError.packageIdentifierMismatch
        }
        guard let executableName = info["CFBundleExecutable"] as? String,
              isSimpleBundleComponent(executableName) else {
            throw MacPayloadVerificationError.invalidBundle
        }

        let executableURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/\(executableName)"
        )
        let provenanceURL = bundleURL.appendingPathComponent(
            "Contents/Resources/desktop-updater-stage-provenance.json"
        )
        let executableData: Data
        let provenanceData: Data
        do {
            executableData = try Data(
                contentsOf: executableURL,
                options: [.mappedIfSafe]
            )
            provenanceData = try Data(
                contentsOf: provenanceURL,
                options: [.mappedIfSafe]
            )
        } catch {
            throw MacPayloadVerificationError.invalidBundle
        }
        let executableDigest = macPayloadSHA256(executableData)
        guard executableDigest == expectation.executableSHA256 else {
            throw MacPayloadVerificationError.executableMismatch
        }
        let provenanceDigest = macPayloadSHA256(provenanceData)
        guard provenanceDigest == expectation.provenanceSHA256 else {
            throw MacPayloadVerificationError.provenanceMismatch
        }
        try verifyCodeSignature(
            bundleURL: bundleURL,
            requirement: expectation.designatedRequirement
        )

        var bundleMaterial = Data()
        bundleMaterial.append(infoData)
        bundleMaterial.append(executableData)
        bundleMaterial.append(provenanceData)
        return MacVerifiedPayloadIdentity(
            packageIdentifier: expectation.packageIdentifier,
            designatedRequirement: expectation.designatedRequirement,
            bundleSHA256: macPayloadSHA256(bundleMaterial),
            provenanceSHA256: provenanceDigest,
            executableSHA256: executableDigest
        )
    }

    private func verifyCodeSignature(
        bundleURL: URL,
        requirement: String
    ) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code)
            == errSecSuccess,
            let code else {
            throw MacPayloadVerificationError.invalidCodeSignature
        }
        var requirementObject: SecRequirement?
        guard SecRequirementCreateWithString(
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
            throw MacPayloadVerificationError.invalidCodeSignature
        }
    }

    private func isSimpleBundleComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }
}

protocol MacApplicationLaunching {
    func launch(applicationURL: URL) throws
}

struct ProcessMacApplicationLauncher: MacApplicationLaunching {
    func launch(applicationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "--", applicationURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MacPayloadVerificationError.relaunchFailed
        }
        guard process.terminationStatus == 0 else {
            throw MacPayloadVerificationError.relaunchFailed
        }
    }
}

final class MacRelaunchService {
    private let expectedPayloadIdentity: MacVerifiedPayloadIdentity
    private let verifier: any MacInstallPayloadVerifying
    private let launcher: any MacApplicationLaunching

    init(
        expectedPayloadIdentity: MacVerifiedPayloadIdentity,
        verifier: any MacInstallPayloadVerifying,
        launcher: any MacApplicationLaunching = ProcessMacApplicationLauncher()
    ) {
        self.expectedPayloadIdentity = expectedPayloadIdentity
        self.verifier = verifier
        self.launcher = launcher
    }

    func relaunchVerifiedApplication(at applicationURL: URL) throws {
        guard try verifier.verifyPayload(at: applicationURL)
            == expectedPayloadIdentity else {
            throw MacPayloadVerificationError.invalidBundle
        }
        try launcher.launch(applicationURL: applicationURL)
    }
}

func macPayloadSHA256(_ data: Data) -> String {
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
