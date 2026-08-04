import CommonCrypto
#if canImport(CryptoKit)
import CryptoKit
#endif
import Darwin
import Foundation
import Security

public let stageProvenanceFileName =
    ".desktop_updater_stage_provenance.json"
public let updaterOwnedStagePrefix = "desktop_updater_stage_"

func macStagedArtifactFileName(for artifactKind: String) -> String? {
    switch artifactKind {
    case "zip":
        return ".desktop_updater_artifact.zip"
    case "dmg":
        return "artifact.dmg"
    case "pkgInstaller":
        return "installer.pkg"
    default:
        return nil
    }
}

public struct StageProvenanceEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let length: Int64
    public let sha256: String?
    public let target: String?
}

public struct StageProvenanceMarker: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let packageId: String
    public let descriptorSha256: String
    public let artifactSha256: String
    public let entries: [StageProvenanceEntry]
}

public struct StageProvenanceState: Sendable {
    public let marker: StageProvenanceMarker
    public let markerSHA256: String
}

public struct MacVerifiedStage: Sendable {
    public let stagedPath: URL
    public let stageRoot: URL
    public let provenance: StageProvenanceState
    public let artifactKind: String
    public let expectedPackageIDs: [String]

    init(
        stagedPath: URL,
        stageRoot: URL,
        provenance: StageProvenanceState,
        artifactKind: String,
        expectedPackageIDs: [String] = []
    ) {
        self.stagedPath = stagedPath
        self.stageRoot = stageRoot
        self.provenance = provenance
        self.artifactKind = artifactKind
        self.expectedPackageIDs = expectedPackageIDs
    }

    public static func loadAndVerify(
        stagedPath: URL,
        stageRoot: URL,
        expectedPackageID: String,
        trustedReleasePublicKeys: [String: Data]
    ) throws -> MacVerifiedStage {
        let expectedPackageID = expectedPackageID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !expectedPackageID.isEmpty,
              !trustedReleasePublicKeys.isEmpty else {
            throw macInstallRequestFailure(
                "Trusted release identity is required."
            )
        }
        let root = stageRoot.standardizedFileURL
        let staged = stagedPath.standardizedFileURL
        guard staged == root || staged.deletingLastPathComponent() == root else {
            throw macInstallRequestFailure(
                "Staged update is not owned by its stage root."
            )
        }

        let manifestURL = root.appendingPathComponent(
            ".desktop_updater_release_manifest.json"
        )
        let manifestValues = try manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true,
              let manifestSize = manifestValues.fileSize,
              manifestSize > 0,
              manifestSize <= 4 * 1024 * 1024 else {
            throw macInstallRequestFailure(
                "Signed release manifest is missing or unsafe."
            )
        }
        let manifestData = try Data(
            contentsOf: manifestURL,
            options: [.mappedIfSafe]
        )
        guard let manifest = try JSONSerialization.jsonObject(
            with: manifestData
        ) as? [String: Any],
            exactInt64(manifest["schemaVersion"]) == 3,
            manifest["platform"] as? String == "macos",
            manifest["packageId"] as? String == expectedPackageID,
            let artifact = manifest["artifact"] as? [String: Any],
            let artifactKind = artifact["kind"] as? String,
            ["zip", "dmg", "pkgInstaller"].contains(artifactKind),
            let artifactSHA256 = artifact["sha256"] as? String,
            macInstallValidSHA256(artifactSHA256),
            let artifactLength = exactInt64(artifact["length"]),
            artifactLength > 0,
            let signature = manifest["signature"] as? [String: Any],
            Set(signature.keys) == ["algorithm", "publicKeyId", "value"],
            signature["algorithm"] as? String == "ed25519",
            let keyID = signature["publicKeyId"] as? String,
            !keyID.isEmpty,
            let publicKeyData = trustedReleasePublicKeys[keyID],
            publicKeyData.count == 32,
            let signatureText = signature["value"] as? String,
            let signatureData = Data(base64Encoded: signatureText),
            signatureData.count == 64 else {
            throw macInstallRequestFailure(
                "Signed release manifest is invalid."
            )
        }

        var unsignedManifest = manifest
        var blankSignature = signature
        blankSignature["value"] = ""
        unsignedManifest["signature"] = blankSignature
        let signatureBytes = try macInstallCanonicalJSON(unsignedManifest)
#if canImport(CryptoKit)
        if #available(macOS 10.15, *) {
            let publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
            )
            guard publicKey.isValidSignature(
                signatureData,
                for: signatureBytes
            ) else {
                throw macInstallRequestFailure(
                    "Signed release manifest verification failed."
                )
            }
        } else {
            throw macInstallRequestFailure(
                "Signed release verification requires macOS 10.15 or newer."
            )
        }
#else
        throw macInstallRequestFailure(
            "Signed release verification is unavailable."
        )
#endif

        let provenance = try StageProvenance.read(stageRoot: root)
        let marker = try StageProvenance.verify(
            stageRoot: root,
            expectedMarkerSHA256: provenance.markerSHA256
        )
        let descriptorSHA256 = macInstallRequestSHA256(
            try macInstallCanonicalJSON(manifest)
        )
        guard marker.packageId == expectedPackageID,
              marker.artifactSha256 == artifactSHA256,
              marker.descriptorSha256 == descriptorSHA256 else {
            throw macInstallRequestFailure(
                "Signed package, artifact, and stage binding failed."
            )
        }

        guard let retainedArtifactName = macStagedArtifactFileName(
            for: artifactKind
        ) else {
            throw macInstallRequestFailure(
                "The staged artifact has no native helper strategy."
            )
        }
        let retainedArtifact = root.appendingPathComponent(
            retainedArtifactName
        )
        let retainedValues = try retainedArtifact.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard retainedArtifact.deletingLastPathComponent() == root,
              retainedValues.isRegularFile == true,
              retainedValues.isSymbolicLink != true else {
            throw macInstallRequestFailure(
                "The retained staged artifact is missing or unsafe."
            )
        }
        let retainedIdentity = try macInstallRequestFileIdentity(
            retainedArtifact
        )
        guard retainedIdentity.length == artifactLength,
              retainedIdentity.sha256 == artifactSHA256 else {
            throw macInstallRequestFailure(
                "The retained staged artifact does not match the signed descriptor."
            )
        }

        let expectedPackageIDs: [String]
        switch artifactKind {
        case "zip", "dmg":
            let values = try staged.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard staged != root,
                  staged.pathExtension.lowercased() == "app",
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  Bundle(url: staged)?.bundleIdentifier == expectedPackageID
            else {
                throw macInstallRequestFailure(
                    "Staged application package identity changed."
                )
            }
            expectedPackageIDs = []
        case "pkgInstaller":
            guard staged == root,
                  let install = manifest["install"] as? [String: Any],
                  install["strategy"] as? String == "pkgInstaller",
                  let macosPKG = install["macosPkg"] as? [String: Any],
                  let packageIDs = macosPKG["expectedPackageIds"] as? [String],
                  packageIDs.count == 1,
                  packageIDs.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines)
                          .isEmpty
                  }),
                  macosPKG["relaunchAfterInstall"] as? Bool == false else {
                throw macInstallRequestFailure(
                    "Signed PKG installation policy is invalid."
                )
            }
            expectedPackageIDs = packageIDs
        default:
            throw macInstallRequestFailure(
                "The staged artifact has no native helper strategy."
            )
        }

        return MacVerifiedStage(
            stagedPath: staged,
            stageRoot: root,
            provenance: provenance,
            artifactKind: artifactKind,
            expectedPackageIDs: expectedPackageIDs
        )
    }
}

struct MacInstallRequestEvidence: Sendable {
    let policyID: String
    let packageID: String
    let processStartIdentity: String
    let executableSHA256: String
    let signerIdentity: String
    let targetClass: String
    let executableRelativePath: String
    let currentVersion: String
    let currentBuildNumber: Int64
    let currentPackageIdentitySHA256: String
    let targetIdentityProofSHA256: String
    let requestNonce: String
}

protocol MacInstallRequestEvidenceBuilding: Sendable {
    func build(for target: MacInstallTarget) throws
        -> MacInstallRequestEvidence
}

struct SystemMacInstallRequestEvidenceBuilder:
    MacInstallRequestEvidenceBuilding
{
    func build(for target: MacInstallTarget) throws
        -> MacInstallRequestEvidence
    {
        guard target.processIdentifier
            == ProcessInfo.processInfo.processIdentifier,
            let info = Bundle(url: target.bundleURL)?.infoDictionary,
            let policyID = info["DesktopUpdaterInstallPolicyID"] as? String,
            let packageID = info["CFBundleIdentifier"] as? String,
            let executableName = info["CFBundleExecutable"] as? String,
            isSimpleComponent(executableName),
            let version = info["CFBundleShortVersionString"] as? String,
            !version.isEmpty,
            let buildText = info["CFBundleVersion"] as? String,
            let buildNumber = Int64(buildText),
            buildNumber >= 0 else {
            throw macInstallRequestFailure(
                "Signed application helper metadata is incomplete."
            )
        }
        let executableRelativePath = "Contents/MacOS/\(executableName)"
        let executableURL = target.bundleURL.appendingPathComponent(
            executableRelativePath
        )
        let executableData = try Data(
            contentsOf: executableURL,
            options: [.mappedIfSafe]
        )
        let executableSHA256 = macInstallRequestSHA256(executableData)
        let startIdentity = try processStartIdentity(
            target.processIdentifier
        )
        let signerIdentity = try designatedRequirement(
            target.bundleURL
        )
        let packageIdentity = macInstallRequestSHA256(
            Data(
                "\(packageID)\n\(version)\n\(buildNumber)\n"
                    .appending(executableSHA256).utf8
            )
        )
        return MacInstallRequestEvidence(
            policyID: policyID,
            packageID: packageID,
            processStartIdentity: startIdentity,
            executableSHA256: executableSHA256,
            signerIdentity: signerIdentity,
            targetClass: Self.targetClass(for: target.bundleURL),
            executableRelativePath: executableRelativePath,
            currentVersion: version,
            currentBuildNumber: buildNumber,
            currentPackageIdentitySHA256: packageIdentity,
            targetIdentityProofSHA256: executableSHA256,
            requestNonce: try requestNonce()
        )
    }

    static func targetClass(
        for bundleURL: URL,
        isWritableDirectory: (String) -> Bool = {
            FileManager.default.isWritableFile(atPath: $0)
        }
    ) -> String {
        let parent = bundleURL.standardizedFileURL
            .deletingLastPathComponent()
        return parent.path == "/Applications"
            && !isWritableDirectory(parent.path)
            ? "protectedApplication" : "applicationBundle"
    }

    private func processStartIdentity(_ processIdentifier: Int32) throws
        -> String
    {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(size)
        ) == size else {
            throw macInstallRequestFailure(
                "Caller process identity is unavailable."
            )
        }
        return "macos:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    private func designatedRequirement(_ bundleURL: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code)
            == errSecSuccess,
            let code,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                nil
            ) == errSecSuccess else {
            throw macInstallRequestFailure(
                "Caller code signature is invalid."
            )
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            code,
            [],
            &requirement
        ) == errSecSuccess,
            let requirement else {
            throw macInstallRequestFailure(
                "Caller designated requirement is unavailable."
            )
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text)
            == errSecSuccess,
            let text else {
            throw macInstallRequestFailure(
                "Caller designated requirement is unavailable."
            )
        }
        return text as String
    }

    private func requestNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            throw macInstallRequestFailure(
                "Secure request nonce generation failed."
            )
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func isSimpleComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }
}

public enum StageProvenance {
    public static func createOwnedStage(
        parent: URL,
        nonce: UUID = UUID()
    ) throws -> URL {
        let values = try parent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw failure("Staging parent must be a real directory.")
        }
        let requestedParent = URL(
            fileURLWithPath: parent.standardizedFileURL.path,
            isDirectory: true
        )
        guard requestedParent.deletingLastPathComponent() != requestedParent else {
            throw failure("Filesystem roots cannot be staging parents.")
        }
        let nonceText = nonce.uuidString.lowercased()
        guard validNonce(nonceText) else {
            throw failure("Owned staging nonce is invalid.")
        }
        let child = requestedParent.appendingPathComponent(
            updaterOwnedStagePrefix + nonceText,
            isDirectory: true
        )
        guard child.deletingLastPathComponent() == requestedParent else {
            throw failure("Owned staging child escapes its parent.")
        }
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: false
        )
        let canonicalParent = requestedParent.resolvingSymlinksInPath()
        let canonicalChild = child.resolvingSymlinksInPath()
        guard canonicalChild.deletingLastPathComponent() == canonicalParent else {
            try? FileManager.default.removeItem(at: child)
            throw failure("Owned staging child escapes its canonical parent.")
        }
        return child
    }

    public static func write(
        stageRoot: URL,
        nonce: String,
        packageID: String,
        descriptorSHA256: String,
        artifactSHA256: String
    ) throws -> StageProvenanceState {
        try validateRoot(stageRoot, nonce: nonce)
        guard !packageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validSHA256(descriptorSHA256),
              validSHA256(artifactSHA256)
        else {
            throw failure("Stage provenance metadata is invalid.")
        }
        let marker = StageProvenanceMarker(
            schemaVersion: 1,
            nonce: nonce,
            packageId: packageID,
            descriptorSha256: descriptorSHA256,
            artifactSha256: artifactSHA256,
            entries: try inventory(stageRoot)
        )
        let bytes = try canonicalBytes(marker)
        try bytes.write(
            to: stageRoot.appendingPathComponent(stageProvenanceFileName),
            options: .withoutOverwriting
        )
        return StageProvenanceState(
            marker: marker,
            markerSHA256: sha256(bytes)
        )
    }

    public static func read(stageRoot: URL) throws -> StageProvenanceState {
        let markerURL = stageRoot.appendingPathComponent(
            stageProvenanceFileName
        )
        let markerValues = try markerURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true
        else {
            throw failure("Stage provenance marker is missing or unsafe.")
        }
        let bytes = try Data(contentsOf: markerURL)
        let marker = try JSONDecoder().decode(
            StageProvenanceMarker.self,
            from: bytes
        )
        try validate(marker)
        guard bytes == (try canonicalBytes(marker)) else {
            throw failure("Stage provenance marker is not canonical.")
        }
        try validateRoot(stageRoot, nonce: marker.nonce)
        return StageProvenanceState(
            marker: marker,
            markerSHA256: sha256(bytes)
        )
    }

    @discardableResult
    public static func verify(
        stageRoot: URL,
        expectedMarkerSHA256: String
    ) throws -> StageProvenanceMarker {
        guard validSHA256(expectedMarkerSHA256) else {
            throw failure("Expected stage provenance SHA-256 is invalid.")
        }
        let state = try read(stageRoot: stageRoot)
        guard state.markerSHA256 == expectedMarkerSHA256 else {
            throw failure("Stage provenance marker digest changed.")
        }
        guard try inventory(stageRoot) == state.marker.entries else {
            throw failure("Staged update inventory changed.")
        }
        return state.marker
    }

    public static func removeOwnedStage(
        parent: URL,
        stageRoot: URL,
        nonce: String
    ) throws {
        let canonicalParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = stageRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalRoot.deletingLastPathComponent() == canonicalParent else {
            throw failure("Owned stage cleanup path escapes parent.")
        }
        let state = try read(stageRoot: stageRoot)
        guard state.marker.nonce == nonce else {
            throw failure("Owned stage cleanup nonce changed.")
        }
        _ = try verify(
            stageRoot: stageRoot,
            expectedMarkerSHA256: state.markerSHA256
        )
        try FileManager.default.removeItem(at: stageRoot)
    }

    public static func canonicalJSONSHA256(_ value: Any) throws -> String {
        let bytes = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        )
        return sha256(try canonicalSlashBytes(bytes))
    }

    private static func inventory(_ stageRoot: URL) throws
        -> [StageProvenanceEntry]
    {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: stageRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw failure("Unable to enumerate staged update.")
        }
        var entries: [StageProvenanceEntry] = []
        while let entry = enumerator.nextObject() as? URL {
            let relative = relativePath(entry, from: stageRoot)
            try validateRelative(relative, field: "inventory path")
            if relative == stageProvenanceFileName { continue }
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(
                    atPath: entry.path
                ).replacingOccurrences(of: "\\", with: "/")
                try validateRelative(target, field: "symlink target")
                let resolved = entry.deletingLastPathComponent()
                    .appendingPathComponent(target)
                    .standardizedFileURL
                let root = stageRoot.standardizedFileURL
                guard resolved.path == root.path ||
                    resolved.path.hasPrefix(root.path + "/")
                else {
                    throw failure("Staged symlink escapes stage root.")
                }
                entries.append(StageProvenanceEntry(
                    path: relative,
                    kind: "symlink",
                    length: 0,
                    sha256: nil,
                    target: target
                ))
            } else if values.isDirectory == true {
                entries.append(StageProvenanceEntry(
                    path: relative,
                    kind: "directory",
                    length: 0,
                    sha256: nil,
                    target: nil
                ))
            } else if values.isRegularFile == true {
                let bytes = try Data(contentsOf: entry, options: .mappedIfSafe)
                entries.append(StageProvenanceEntry(
                    path: relative,
                    kind: "file",
                    length: Int64(bytes.count),
                    sha256: sha256(bytes),
                    target: nil
                ))
            } else {
                throw failure("Unsupported staged filesystem entry.")
            }
        }
        if let enumerationError { throw enumerationError }
        return entries.sorted { utf8Less($0.path, $1.path) }
    }

    private static func validate(_ marker: StageProvenanceMarker) throws {
        guard marker.schemaVersion == 1,
              validNonce(marker.nonce),
              !marker.packageId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              validSHA256(marker.descriptorSha256),
              validSHA256(marker.artifactSha256)
        else {
            throw failure("Stage provenance identity is invalid.")
        }
        var seen = Set<String>()
        var previous: String?
        for entry in marker.entries {
            try validateRelative(entry.path, field: "entry path")
            guard seen.insert(entry.path).inserted else {
                throw failure("Stage provenance contains duplicate paths.")
            }
            if let previous, !utf8Less(previous, entry.path) {
                throw failure("Stage provenance entries are not sorted.")
            }
            previous = entry.path
            switch entry.kind {
            case "file":
                guard entry.length >= 0,
                      entry.sha256.map(validSHA256) == true,
                      entry.target == nil
                else { throw failure("Provenance file entry is invalid.") }
            case "directory":
                guard entry.length == 0,
                      entry.sha256 == nil,
                      entry.target == nil
                else { throw failure("Provenance directory entry is invalid.") }
            case "symlink":
                guard entry.length == 0,
                      entry.sha256 == nil,
                      let target = entry.target
                else { throw failure("Provenance symlink entry is invalid.") }
                try validateRelative(target, field: "symlink target")
            default:
                throw failure("Unsupported provenance entry kind.")
            }
        }
    }

    private static func validateRoot(_ root: URL, nonce: String) throws {
        let values = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              validNonce(nonce),
              root.lastPathComponent == updaterOwnedStagePrefix + nonce
        else {
            throw failure("Stage root is not bound to its marker nonce.")
        }
    }

    private static func validateRelative(_ value: String, field: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains("\\"),
              value.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw failure("Invalid \(field): \(value)")
        }
    }

    private static func relativePath(_ entry: URL, from root: URL) -> String {
        String(entry.standardizedFileURL.path.dropFirst(
            root.standardizedFileURL.path.count + 1
        ))
    }

    private static func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try canonicalSlashBytes(encoder.encode(value))
    }

    private static func canonicalSlashBytes(_ data: Data) throws -> Data {
        guard let json = String(data: data, encoding: .utf8) else {
            throw failure("Canonical stage provenance JSON is not UTF-8.")
        }
        return Data(json.replacingOccurrences(of: "\\/", with: "/").utf8)
    }

    private static func sha256(_ data: Data) -> String {
        var context = CC_SHA256_CTX()
        _ = CC_SHA256_Init(&context)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = min(bytes.count - offset, Int(CC_LONG.max))
                _ = CC_SHA256_Update(
                    &context,
                    baseAddress.advanced(by: offset),
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

    private static func validSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validNonce(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func utf8Less(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "DesktopUpdaterKit.StageProvenance",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

public struct MacInstallRequest: Sendable {
    public let stagingPath: String
    public let stageRoot: String
    public let expectedProvenanceSHA256: String
    public let artifactKind: String
    public let expectedArtifactSHA256: String
    public let expectedPackageIDs: [String]
    public let provenanceEntries: [StageProvenanceEntry]

    public init(verifiedStage: MacVerifiedStage) {
        stagingPath = verifiedStage.stagedPath.path
        stageRoot = verifiedStage.stageRoot.path
        expectedProvenanceSHA256 = verifiedStage.provenance.markerSHA256
        artifactKind = verifiedStage.artifactKind
        expectedArtifactSHA256 =
            verifiedStage.provenance.marker.artifactSha256
        expectedPackageIDs = verifiedStage.expectedPackageIDs
        provenanceEntries = verifiedStage.provenance.marker.entries
    }

    func helperRequestData(
        transactionID: String,
        processIdentifier: Int32,
        bundleURL: URL,
        evidence: MacInstallRequestEvidence
    ) throws -> Data {
        let root = URL(fileURLWithPath: stageRoot).standardizedFileURL
        let staged = URL(fileURLWithPath: stagingPath).standardizedFileURL
        let marker = try StageProvenance.verify(
            stageRoot: root,
            expectedMarkerSHA256: expectedProvenanceSHA256
        )
        guard marker.packageId == evidence.packageID,
              marker.artifactSha256 == expectedArtifactSHA256 else {
            throw macInstallRequestFailure(
                "Stage provenance is not bound to the install request."
            )
        }
        let manifestURL = root.appendingPathComponent(
            ".desktop_updater_release_manifest.json"
        )
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(
            with: manifestData
        ) as? [String: Any],
            let packageID = manifest["packageId"] as? String,
            packageID == evidence.packageID,
            let desiredVersion = manifest["version"] as? String,
            let artifact = manifest["artifact"] as? [String: Any],
            artifact["sha256"] as? String == expectedArtifactSHA256,
            let artifactLength = exactInt64(artifact["length"]),
            artifactLength > 0,
            let signature = manifest["signature"] as? [String: Any],
            signature["algorithm"] as? String == "ed25519",
            let keyID = signature["publicKeyId"] as? String,
            let signatureBase64 = signature["value"] as? String else {
            throw macInstallRequestFailure(
                "Signed release manifest is invalid."
            )
        }
        let canonicalManifest = try macInstallCanonicalJSON(manifest)
        guard macInstallRequestSHA256(canonicalManifest)
            == marker.descriptorSha256 else {
            throw macInstallRequestFailure(
                "Signed release manifest digest changed."
            )
        }
        let strategy: String
        let provider: String
        switch artifactKind {
        case "zip", "dmg":
            guard expectedPackageIDs.isEmpty else {
                throw macInstallRequestFailure(
                    "Package receipt IDs are only valid for PKG updates."
                )
            }
            strategy = "directoryReplace"
            provider = "platformDirectory"
        case "pkgInstaller":
            guard let install = manifest["install"] as? [String: Any],
                  let macosPKG = install["macosPkg"] as? [String: Any],
                  let manifestPackageIDs = macosPKG["expectedPackageIds"]
                    as? [String],
                  manifestPackageIDs.count == 1,
                  manifestPackageIDs == expectedPackageIDs,
                  macosPKG["relaunchAfterInstall"] as? Bool == false else {
                throw macInstallRequestFailure(
                    "PKG receipt IDs are not bound to the signed manifest."
                )
            }
            strategy = "verifiedInstallerHandoff"
            provider = "macosInstaller"
        default:
            throw macInstallRequestFailure(
                "The staged artifact has no native helper strategy."
            )
        }
        let desiredBuild = exactInt64(manifest["buildNumber"]) ?? 0
        let request: [String: Any] = [
            "schemaVersion": 1,
            "protocolVersion": 1,
            "transactionId": transactionID,
            "policyId": evidence.policyID,
            "packageId": evidence.packageID,
            "strategy": strategy,
            "provider": provider,
            "target": [
                "class": evidence.targetClass,
                "pathHint": bundleURL.standardizedFileURL.path,
                "targetNameHint": bundleURL.lastPathComponent,
                "executableRelativePath": evidence.executableRelativePath,
                "identityProofSha256":
                    evidence.targetIdentityProofSHA256,
            ],
            "currentIdentity": [
                "version": evidence.currentVersion,
                "buildNumber": evidence.currentBuildNumber,
                "packageIdentitySha256":
                    evidence.currentPackageIdentitySHA256,
            ],
            "desiredIdentity": [
                "version": desiredVersion,
                "buildNumber": desiredBuild,
                "packageIdentitySha256": marker.descriptorSha256,
            ],
            "stage": [
                "pathHint": staged.path,
                "ownershipNonce": macInstallRequestSHA256(
                    Data(marker.nonce.utf8)
                ),
                "provenanceSha256": expectedProvenanceSHA256,
                "artifactSha256": expectedArtifactSHA256,
                "artifactLength": artifactLength,
            ],
            "signedDescriptor": [
                "canonicalSha256": marker.descriptorSha256,
                "signatureAlgorithm": "ed25519",
                "keyId": keyID,
                "signatureBase64": signatureBase64,
            ],
            "caller": [
                "processId": processIdentifier,
                "processStartIdentity": evidence.processStartIdentity,
                "executableSha256": evidence.executableSHA256,
                "packageId": evidence.packageID,
                "signerIdentity": evidence.signerIdentity,
            ],
            "requestNonce": evidence.requestNonce,
            "diagnosticsDestination": ["kind": "platformLog"],
        ]
        return try macInstallCanonicalJSON(request)
    }
}

private func macInstallCanonicalJSON(_ object: Any) throws -> Data {
    let encoded = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    guard let text = String(data: encoded, encoding: .utf8) else {
        throw macInstallRequestFailure("Canonical JSON is not UTF-8.")
    }
    return Data(text.replacingOccurrences(of: "\\/", with: "/").utf8)
}

private func exactInt64(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
          !["c", "f", "d"].contains(String(cString: number.objCType)) else {
        return nil
    }
    let result = number.int64Value
    return NSNumber(value: result) == number ? result : nil
}

private func macInstallValidSHA256(_ value: String) -> Bool {
    value.range(
        of: #"^[0-9a-f]{64}$"#,
        options: .regularExpression
    ) != nil
}

private func macInstallRequestFileIdentity(
    _ url: URL
) throws -> (length: Int64, sha256: String) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }
    var context = CC_SHA256_CTX()
    _ = CC_SHA256_Init(&context)
    var length: Int64 = 0
    while true {
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { break }
        let chunkLength = Int64(chunk.count)
        guard length <= Int64.max - chunkLength else {
            throw macInstallRequestFailure(
                "The retained staged artifact length overflowed."
            )
        }
        length += chunkLength
        chunk.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = CC_SHA256_Update(
                &context,
                baseAddress,
                CC_LONG(bytes.count)
            )
        }
    }
    var digest = [UInt8](
        repeating: 0,
        count: Int(CC_SHA256_DIGEST_LENGTH)
    )
    _ = CC_SHA256_Final(&digest, &context)
    return (
        length,
        digest.map { String(format: "%02x", $0) }.joined()
    )
}

private func macInstallRequestSHA256(_ data: Data) -> String {
    var context = CC_SHA256_CTX()
    _ = CC_SHA256_Init(&context)
    data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = min(bytes.count - offset, Int(CC_LONG.max))
            _ = CC_SHA256_Update(
                &context,
                baseAddress.advanced(by: offset),
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

private func macInstallRequestFailure(_ message: String) -> NSError {
    NSError(
        domain: "DesktopUpdaterKit.MacInstallRequest",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
