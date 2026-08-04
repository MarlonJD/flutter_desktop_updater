import CryptoKit
import Darwin
import Foundation
import Security

final class SystemMacStageInstallEvidenceInspector:
    MacStageInstallEvidenceInspecting
{
    private let installerVerifierFactory:
        any MacVerifiedInstallerCheckingCreating

    init(
        installerVerifierFactory:
            any MacVerifiedInstallerCheckingCreating =
            SystemMacVerifiedInstallerCheckerFactory()
    ) {
        self.installerVerifierFactory = installerVerifierFactory
    }

    func inspect(
        request: NativeInstallTransactionRequestV1,
        policy: MacSealedInstallPolicyV1
    ) throws -> MacStageInstallEvidence {
        do {
            guard #available(macOS 10.15, *) else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
            return try inspectAvailable(request: request, policy: policy)
        } catch {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
    }

    @available(macOS 10.15, *)
    private func inspectAvailable(
        request: NativeInstallTransactionRequestV1,
        policy: MacSealedInstallPolicyV1
    ) throws -> MacStageInstallEvidence {
        let stageURL = URL(fileURLWithPath: request.stage.pathHint)
            .standardizedFileURL
        let isInstaller = request.strategy == "verifiedInstallerHandoff"
            && request.provider == "macosInstaller"
        guard stageURL.path == request.stage.pathHint,
              try isRealDirectory(stageURL)
        else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let rootURL = isInstaller
            ? stageURL : stageURL.deletingLastPathComponent()
        guard isInstaller
            || stageURL.lastPathComponent == request.target.targetNameHint
        else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let rootDirectory = try MacTransactionDirectory(url: rootURL)
        let markerURL = rootURL.appendingPathComponent(
            ".desktop_updater_stage_provenance.json"
        )
        let markerData = try MacRetainedFileObject(
            directory: rootDirectory,
            name: markerURL.lastPathComponent
        ).readData(maximumLength: macStageMetadataMaximumLength)
        guard macPrivilegeSHA256(markerData)
                == request.stage.provenanceSHA256,
              try NativeStrictJSON.canonicalize(markerData) == markerData,
              let marker = try NativeStrictJSON.decode(markerData)
                as? [String: Any],
              Set(marker.keys) == [
                  "schemaVersion", "nonce", "packageId",
                  "descriptorSha256", "artifactSha256", "entries",
              ],
              exactInteger(marker["schemaVersion"]) == 1,
              let nonce = marker["nonce"] as? String,
              isNonce(nonce),
              rootURL.lastPathComponent
                == "desktop_updater_stage_\(nonce)",
              macPrivilegeSHA256(Data(nonce.utf8))
                == request.stage.ownershipNonce,
              marker["packageId"] as? String == request.packageID,
              marker["descriptorSha256"] as? String
                == request.signedDescriptor.canonicalSHA256,
              marker["artifactSha256"] as? String
                == request.stage.artifactSHA256,
              let rawEntries = marker["entries"] as? [Any]
        else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let expectedEntries = try parseEntries(rawEntries)
        let actualEntries = try inventory(
            rootURL,
            excludingMarker: true,
            expectedEntries: expectedEntries
        )
        guard expectedEntries == actualEntries else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }

        let descriptorURL = rootURL.appendingPathComponent(
            ".desktop_updater_release_manifest.json"
        )
        let descriptorData = try MacRetainedFileObject(
            directory: rootDirectory,
            name: descriptorURL.lastPathComponent
        ).readData(maximumLength: macStageMetadataMaximumLength)
        let canonicalDescriptor = try NativeStrictJSON.canonicalize(
            descriptorData
        )
        guard macPrivilegeSHA256(canonicalDescriptor)
                == request.signedDescriptor.canonicalSHA256,
              let descriptor = try NativeStrictJSON.decode(descriptorData)
                as? [String: Any]
        else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let descriptorEvidence = try validateDescriptor(
            descriptor,
            request: request,
            policy: policy
        )
        try verifyArtifact(
            rootDirectory: rootDirectory,
            kind: descriptorEvidence.artifactKind,
            request: request
        )

        if isInstaller {
            guard descriptorEvidence.artifactKind == "pkgInstaller",
                  !descriptorEvidence.expectedPackageIdentifiers.isEmpty
            else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
            let expectation = MacVerifiedInstallerExpectation(
                installerURL: rootURL.appendingPathComponent(
                    "installer.pkg"
                ),
                kind: .pkg,
                targetURL: URL(
                    fileURLWithPath: request.target.pathHint
                ).standardizedFileURL,
                packageIdentifier: request.packageID,
                expectedVersion: request.desiredIdentity.version,
                expectedBuildNumber: request.desiredIdentity.buildNumber,
                designatedRequirement:
                    policy.allowedApplicationSigner.value,
                artifactSHA256: request.stage.artifactSHA256,
                artifactLength: request.stage.artifactLength,
                expectedPackageIdentifiers:
                    descriptorEvidence.expectedPackageIdentifiers,
                descriptorSHA256:
                    request.signedDescriptor.canonicalSHA256,
                provenanceSHA256: request.stage.provenanceSHA256
            )
            let checker = try installerVerifierFactory.makeVerifier(
                expectation: expectation
            )
            let evidence = try checker.verifyInstaller(expectation)
            let boundExpectation = expectation.binding(evidence)
            return MacStageInstallEvidence(
                stageURL: rootURL,
                installerExpectation: boundExpectation,
                handoff: MacVerifiedInstallerHandoff(
                    verifier: checker,
                    runner: MacPlatformInstallerRunner()
                )
            )
        }

        guard let executableSHA256 =
                descriptorEvidence.executableSHA256,
              let bundleTreeSHA256 =
                descriptorEvidence.bundleTreeSHA256 else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let verifier = MacAuthorizedBundlePayloadVerifier(
            expectation: MacAuthorizedBundlePayloadExpectation(
                packageIdentifier: request.packageID,
                designatedRequirement:
                    policy.allowedApplicationSigner.value,
                version: request.desiredIdentity.version,
                buildNumber: request.desiredIdentity.buildNumber,
                provenanceSHA256: request.stage.provenanceSHA256,
                executableSHA256: executableSHA256,
                bundleTreeSHA256: bundleTreeSHA256
            )
        )
        let identity = try verifier.verifyPayload(at: stageURL)
        return MacStageInstallEvidence(
            stageURL: stageURL,
            payloadIdentity: identity,
            verifier: verifier
        )
    }

    @available(macOS 10.15, *)
    private func validateDescriptor(
        _ descriptor: [String: Any],
        request: NativeInstallTransactionRequestV1,
        policy: MacSealedInstallPolicyV1
    ) throws -> MacDescriptorInstallEvidence
    {
        let required: Set<String> = [
            "schemaVersion", "packageId", "appName", "version",
            "platform", "channel", "artifact", "install",
            "minimumUpdaterVersion", "generatedAt", "signature",
        ]
        let optional: Set<String> = [
            "buildNumber", "minimumOS", "deltaArtifacts",
        ]
        guard Set(descriptor.keys).isSuperset(of: required),
              Set(descriptor.keys).subtracting(required).isSubset(of: optional),
              exactInteger(descriptor["schemaVersion"]) == 3,
              descriptor["packageId"] as? String == request.packageID,
              descriptor["appName"] as? String
                == request.target.targetNameHint,
              descriptor["version"] as? String
                == request.desiredIdentity.version,
              (exactInteger(descriptor["buildNumber"]) ?? 0)
                == request.desiredIdentity.buildNumber,
              request.desiredIdentity.packageIdentitySHA256
                == request.signedDescriptor.canonicalSHA256,
              descriptor["platform"] as? String == "macos",
              let artifact = descriptor["artifact"] as? [String: Any],
              Set(artifact.keys) == ["kind", "url", "sha256", "length"],
              let artifactKind = artifact["kind"] as? String,
              ["zip", "dmg", "pkgInstaller"].contains(artifactKind),
              artifact["url"] as? String != nil,
              artifact["sha256"] as? String
                == request.stage.artifactSHA256,
              exactInteger(artifact["length"])
                == request.stage.artifactLength,
              let install = descriptor["install"] as? [String: Any],
              try validInstall(
                  install,
                  artifactKind: artifactKind,
                  request: request
              ),
              let signature = descriptor["signature"]
                as? [String: Any],
              Set(signature.keys) == ["algorithm", "publicKeyId", "value"],
              signature["algorithm"] as? String
                == request.signedDescriptor.signatureAlgorithm,
              signature["publicKeyId"] as? String
                == request.signedDescriptor.keyID,
              signature["value"] as? String
                == request.signedDescriptor.signatureBase64,
              let signatureData = Data(
                  base64Encoded: request.signedDescriptor.signatureBase64
              ),
              signatureData.count == 64,
              let rootKey = policy.releaseRootPublicKeys.first(where: {
                  $0.keyID == request.signedDescriptor.keyID
                    && $0.algorithm
                        == request.signedDescriptor.signatureAlgorithm
              })
        else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        if artifactKind == "pkgInstaller",
           exactInteger(descriptor["buildNumber"]) == nil {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        var unsigned = descriptor
        var unsignedSignature = signature
        unsignedSignature["value"] = ""
        unsigned["signature"] = unsignedSignature
        let signingData = try NativeStrictJSON.canonicalize(
            JSONSerialization.data(withJSONObject: unsigned)
        )
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: rootKey.publicKey
        )
        guard publicKey.isValidSignature(signatureData, for: signingData)
        else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }

        if artifactKind == "pkgInstaller" {
            guard let macosPKG = install["macosPkg"] as? [String: Any],
                  let identifiers = macosPKG["expectedPackageIds"]
                    as? [String] else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
            return MacDescriptorInstallEvidence(
                artifactKind: artifactKind,
                executableSHA256: nil,
                bundleTreeSHA256: nil,
                expectedPackageIdentifiers: identifiers
            )
        }

        let stageURL = URL(fileURLWithPath: request.stage.pathHint)
            .standardizedFileURL
        let infoURL = stageURL.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(
            from: try macReadBoundedRegularFile(
                infoURL,
                maximumLength: macStageMetadataMaximumLength
            ),
            options: [],
            format: nil
        ) as? [String: Any],
            info["CFBundleIdentifier"] as? String == request.packageID,
            info["CFBundleShortVersionString"] as? String
                == request.desiredIdentity.version,
            let buildText = info["CFBundleVersion"] as? String,
            Int64(buildText) == request.desiredIdentity.buildNumber,
            let executableName = info["CFBundleExecutable"] as? String,
            isSimpleComponent(executableName)
        else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let executableURL = stageURL.appendingPathComponent(
            "Contents/MacOS/\(executableName)"
        )
        do {
            try macValidateRequiredBundleExecutables(
                stageURL,
                executableName: executableName
            )
        } catch {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let executableSHA256 = try macBoundedFileSHA256(
            executableURL,
            maximumLength: macStageTreeFileMaximumLength
        )
        let bundleTreeSHA256 = try macAuthorizedTreeSHA256(stageURL)
        let verifier = MacAuthorizedBundlePayloadVerifier(
            expectation: MacAuthorizedBundlePayloadExpectation(
                packageIdentifier: request.packageID,
                designatedRequirement:
                    policy.allowedApplicationSigner.value,
                version: request.desiredIdentity.version,
                buildNumber: request.desiredIdentity.buildNumber,
                provenanceSHA256: request.stage.provenanceSHA256,
                executableSHA256: executableSHA256,
                bundleTreeSHA256: bundleTreeSHA256
            )
        )
        _ = try verifier.verifyPayload(at: stageURL)
        return MacDescriptorInstallEvidence(
            artifactKind: artifactKind,
            executableSHA256: executableSHA256,
            bundleTreeSHA256: bundleTreeSHA256,
            expectedPackageIdentifiers: []
        )
    }

    private func verifyArtifact(
        rootDirectory: MacTransactionDirectory,
        kind: String,
        request: NativeInstallTransactionRequestV1
    ) throws {
        let name: String
        switch kind {
        case "zip":
            name = ".desktop_updater_artifact.zip"
        case "dmg":
            name = "artifact.dmg"
        case "pkgInstaller":
            name = "installer.pkg"
        default:
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let artifact = try MacRetainedFileObject(
            directory: rootDirectory,
            name: name
        )
        guard try artifact.sha256(
            expectedLength: request.stage.artifactLength
        ) == request.stage.artifactSHA256 else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
    }

    private func validInstall(
        _ install: [String: Any],
        artifactKind: String,
        request: NativeInstallTransactionRequestV1
    ) throws -> Bool {
        if artifactKind == "pkgInstaller" {
            guard request.strategy == "verifiedInstallerHandoff",
                  request.provider == "macosInstaller",
                  Set(install.keys) == ["strategy", "macosPkg"],
                  install["strategy"] as? String == "pkgInstaller",
                  let pkg = install["macosPkg"] as? [String: Any],
                  Set(pkg.keys) == [
                      "launchMode", "expectedPackageIds",
                      "relaunchAfterInstall",
                  ],
                  let launchMode = pkg["launchMode"] as? String,
                  launchMode == "installerApp" ||
                      launchMode == "privilegedInstallerTool",
                  pkg["relaunchAfterInstall"] as? Bool == false,
                  let identifiers = pkg["expectedPackageIds"] as? [String],
                  identifiers.count == 1,
                  Set(identifiers).count == identifiers.count,
                  identifiers.allSatisfy({ identifier in
                      identifier.range(
                          of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9._-]{0,126}[a-zA-Z0-9])?$"#,
                          options: .regularExpression
                      ) != nil
                  }) else {
                return false
            }
            return true
        }
        guard request.strategy == "directoryReplace",
              request.provider == "platformDirectory",
              install["strategy"] as? String == "wholeBundleReplace" else {
            return false
        }
        if artifactKind == "zip" {
            return Set(install.keys) == ["strategy"]
        }
        guard Set(install.keys) == ["strategy", "macosDmg"],
              let dmg = install["macosDmg"] as? [String: Any],
              Set(dmg.keys) == ["appBundleName", "verifyPrimarySignature"],
              let name = dmg["appBundleName"] as? String,
              name.hasSuffix(".app"),
              !name.contains("/"),
              dmg["verifyPrimarySignature"] is Bool else {
            return false
        }
        return true
    }
}

private struct MacDescriptorInstallEvidence {
    let artifactKind: String
    let executableSHA256: String?
    let bundleTreeSHA256: String?
    let expectedPackageIdentifiers: [String]
}

private struct MacStageInventoryEntry: Equatable {
    let path: String
    let kind: String
    let length: Int64
    let sha256: String?
    let target: String?
    let mode: UInt16?
}

private struct MacAuthorizedBundlePayloadExpectation {
    let packageIdentifier: String
    let designatedRequirement: String
    let version: String
    let buildNumber: Int64
    let provenanceSHA256: String
    let executableSHA256: String
    let bundleTreeSHA256: String
}

private final class MacAuthorizedBundlePayloadVerifier:
    MacInstallPayloadVerifying
{
    private let expectation: MacAuthorizedBundlePayloadExpectation

    init(expectation: MacAuthorizedBundlePayloadExpectation) {
        self.expectation = expectation
    }

    func verifyPayload(at bundleURL: URL) throws -> MacVerifiedPayloadIdentity {
        let canonical = bundleURL.standardizedFileURL
        guard canonical.path == bundleURL.standardizedFileURL.path,
              try isRealDirectory(canonical),
              let info = try PropertyListSerialization.propertyList(
                  from: try macReadBoundedRegularFile(
                      canonical.appendingPathComponent(
                          "Contents/Info.plist"
                      ),
                      maximumLength: macStageMetadataMaximumLength
                  ),
                  options: [],
                  format: nil
              ) as? [String: Any],
              info["CFBundleIdentifier"] as? String
                == expectation.packageIdentifier,
              info["CFBundleShortVersionString"] as? String
                == expectation.version,
              let build = info["CFBundleVersion"] as? String,
              Int64(build) == expectation.buildNumber,
              let executableName = info["CFBundleExecutable"] as? String,
              isSimpleComponent(executableName) else {
            throw MacPayloadVerificationError.invalidBundle
        }
        let executableSHA256 = try macBoundedFileSHA256(
            canonical.appendingPathComponent(
                "Contents/MacOS/\(executableName)"
            ),
            maximumLength: macStageTreeFileMaximumLength
        )
        do {
            try macValidateRequiredBundleExecutables(
                canonical,
                executableName: executableName
            )
        } catch {
            throw MacPayloadVerificationError.invalidBundle
        }
        guard executableSHA256 == expectation.executableSHA256 else {
            throw MacPayloadVerificationError.executableMismatch
        }
        guard try macAuthorizedTreeSHA256(canonical)
                == expectation.bundleTreeSHA256
        else {
            throw MacPayloadVerificationError.invalidBundle
        }
        try macVerifyBundleSignature(
            bundleURL: canonical,
            requirement: expectation.designatedRequirement
        )
        return MacVerifiedPayloadIdentity(
            packageIdentifier: expectation.packageIdentifier,
            designatedRequirement: expectation.designatedRequirement,
            bundleSHA256: expectation.bundleTreeSHA256,
            provenanceSHA256: expectation.provenanceSHA256,
            executableSHA256: expectation.executableSHA256
        )
    }
}

private func parseEntries(_ values: [Any]) throws
    -> [MacStageInventoryEntry]
{
    var result: [MacStageInventoryEntry] = []
    var previous: String?
    var paths = Set<String>()
    for value in values {
        guard let entry = value as? [String: Any],
              let path = entry["path"] as? String,
              validRelativePath(path),
              paths.insert(path).inserted,
              previous.map({ $0.utf8.lexicographicallyPrecedes(path.utf8) })
                ?? true,
              let kind = entry["kind"] as? String,
              let length = exactInteger(entry["length"]),
              length >= 0 else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let sha = entry["sha256"] as? String
        let target = entry["target"] as? String
        switch kind {
        case "file":
            guard Set(entry.keys) == ["path", "kind", "length", "sha256"],
                  sha?.range(
                      of: "^[0-9a-f]{64}$",
                      options: .regularExpression
                  ) != nil else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
        case "directory":
            guard Set(entry.keys) == ["path", "kind", "length"],
                  length == 0 else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
        case "symlink":
            guard Set(entry.keys) == ["path", "kind", "length", "target"],
                  length == 0,
                  let target,
                  validRelativePath(target),
                  symlinkStaysInside(path: path, target: target) else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
        default:
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        result.append(
            MacStageInventoryEntry(
                path: path,
                kind: kind,
                length: length,
                sha256: sha,
                target: target,
                mode: nil
            )
        )
        previous = path
    }
    return result
}

private func inventory(
    _ rootURL: URL,
    excludingMarker: Bool,
    expectedEntries: [MacStageInventoryEntry]? = nil,
    includeModes: Bool = false
) throws -> [MacStageInventoryEntry] {
    let canonicalRoot = try realURL(rootURL)
    guard try isRealDirectory(rootURL),
          let enumerator = FileManager.default.enumerator(
              at: canonicalRoot,
              includingPropertiesForKeys: [
                  .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
              ],
              options: []
          ) else {
        throw MacOneShotAuthorizationError.stageAuthenticationFailed
    }
    let rootDirectory = try MacTransactionDirectory(url: canonicalRoot)
    let expectedByPath = expectedEntries.map { entries in
        Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    }
    var result: [MacStageInventoryEntry] = []
    for case let url as URL in enumerator {
        let prefix = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path : canonicalRoot.path + "/"
        guard url.path.hasPrefix(prefix) else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let relative = String(url.path.dropFirst(prefix.count))
        guard validRelativePath(relative) else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        if excludingMarker
            && relative == ".desktop_updater_stage_provenance.json" {
            continue
        }
        if let expectedByPath, expectedByPath[relative] == nil {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: url.path
            )
            guard validRelativePath(target),
                  symlinkStaysInside(path: relative, target: target) else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
            result.append(
                MacStageInventoryEntry(
                    path: relative,
                    kind: "symlink",
                    length: 0,
                    sha256: nil,
                    target: target,
                    mode: nil
                )
            )
        } else if values.isDirectory == true {
            result.append(
                MacStageInventoryEntry(
                    path: relative,
                    kind: "directory",
                    length: 0,
                    sha256: nil,
                    target: nil,
                    mode: includeModes ? try macStageMode(url) : nil
                )
            )
        } else if values.isRegularFile == true {
            let retained = try MacRetainedFileObject(
                directory: rootDirectory,
                name: relative
            )
            let length: Int64
            if let expected = expectedByPath?[relative] {
                guard expected.kind == "file" else {
                    throw MacOneShotAuthorizationError
                        .stageAuthenticationFailed
                }
                length = expected.length
            } else {
                length = try retained.length(
                    maximumLength: macStageTreeFileMaximumLength
                )
            }
            result.append(
                MacStageInventoryEntry(
                    path: relative,
                    kind: "file",
                    length: length,
                    sha256: try retained.sha256(expectedLength: length),
                    target: nil,
                    mode: includeModes
                        ? try retained.rootOwnedBundleFileMode() : nil
                )
            )
        } else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
    }
    return result.sorted {
        $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
    }
}

private let macStageMetadataMaximumLength: Int64 = 1_048_576
private let macStageTreeFileMaximumLength: Int64 = 16 * 1024 * 1024 * 1024

func macReadBoundedRegularFile(
    _ url: URL,
    maximumLength: Int64
) throws -> Data {
    let directory = try MacTransactionDirectory(
        url: url.deletingLastPathComponent()
    )
    return try MacRetainedFileObject(
        directory: directory,
        name: url.lastPathComponent
    ).readData(maximumLength: maximumLength)
}

func macBoundedFileSHA256(
    _ url: URL,
    maximumLength: Int64
) throws -> String {
    let directory = try MacTransactionDirectory(
        url: url.deletingLastPathComponent()
    )
    let retained = try MacRetainedFileObject(
        directory: directory,
        name: url.lastPathComponent
    )
    let length = try retained.length(maximumLength: maximumLength)
    return try retained.sha256(expectedLength: length)
}

private func realURL(_ url: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard url.path.withCString({ realpath($0, &buffer) }) != nil else {
        throw MacOneShotAuthorizationError.stageAuthenticationFailed
    }
    return URL(fileURLWithPath: String(cString: buffer))
}

func macAuthorizedTreeSHA256(_ rootURL: URL) throws -> String {
    let entries = try inventory(
        rootURL,
        excludingMarker: false,
        includeModes: true
    )
    let object: [[String: Any]] = entries.map { entry in
        var value: [String: Any] = [
            "path": entry.path,
            "kind": entry.kind,
            "length": entry.length,
        ]
        if let sha = entry.sha256 { value["sha256"] = sha }
        if let target = entry.target { value["target"] = target }
        if let mode = entry.mode { value["mode"] = Int(mode) }
        return value
    }
    return macPrivilegeSHA256(
        try NativeStrictJSON.canonicalize(
            JSONSerialization.data(withJSONObject: object)
        )
    )
}

private func macStageMode(_ url: URL) throws -> UInt16 {
    var value = stat()
    let status = url.path.withCString({ Darwin.lstat($0, &value) })
    let kind = value.st_mode & mode_t(S_IFMT)
    let mode = value.st_mode & mode_t(0o7777)
    let accessible = kind == mode_t(S_IFDIR)
        ? mode & 0o005 == 0o005
        : kind == mode_t(S_IFREG)
            && mode & 0o004 == 0o004
            && (mode & 0o111 == 0 || mode & 0o101 == 0o101)
    guard status == 0,
          value.st_flags == 0,
          mode & 0o7000 == 0,
          mode & 0o022 == 0,
          accessible else {
        throw MacOneShotAuthorizationError.stageAuthenticationFailed
    }
    return UInt16(mode)
}

private func macValidateRequiredBundleExecutables(
    _ bundleURL: URL,
    executableName: String
) throws {
    guard isSimpleComponent(executableName) else {
        throw MacOneShotAuthorizationError.stageAuthenticationFailed
    }
    let root = try MacTransactionDirectory(url: bundleURL)
    for components in [
        ["Contents", "MacOS", executableName],
        ["Contents", "Helpers", "DesktopUpdaterInstallHelper"],
    ] {
        var descriptor = Darwin.dup(root.fileDescriptor)
        guard descriptor >= 0 else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        defer { _ = Darwin.close(descriptor) }
        for component in components.dropLast() {
            let child = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard child >= 0 else {
                throw MacOneShotAuthorizationError.stageAuthenticationFailed
            }
            _ = Darwin.close(descriptor)
            descriptor = child
        }
        let executable = components.last!.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard executable >= 0 else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
        var status = stat()
        let valid = Darwin.fstat(executable, &status) == 0
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && status.st_mode & mode_t(0o101) == mode_t(0o101)
            && status.st_mode & mode_t(0o004) == mode_t(0o004)
            && status.st_mode & mode_t(0o7000) == 0
            && status.st_mode & mode_t(0o022) == 0
            && status.st_flags == 0
        _ = Darwin.close(executable)
        guard valid else {
            throw MacOneShotAuthorizationError.stageAuthenticationFailed
        }
    }
}

func macVerifyBundleSignature(
    bundleURL: URL,
    requirement: String
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
        throw MacPayloadVerificationError.invalidCodeSignature
    }
}

private func isRealDirectory(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    return values.isDirectory == true && values.isSymbolicLink != true
}

private func exactInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)) else {
        return nil
    }
    let result = number.int64Value
    return NSNumber(value: result) == number ? result : nil
}

private func isNonce(_ value: String) -> Bool {
    value.range(
        of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: .regularExpression
    ) != nil
}

private func isSimpleComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\\")
        && !value.contains("\0")
}

private func validRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.hasSuffix("/")
        && !value.contains("\\")
        && value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

private func symlinkStaysInside(path: String, target: String) -> Bool {
    var components = path.split(separator: "/").dropLast().map(String.init)
    for component in target.split(separator: "/") {
        if component == ".." {
            guard !components.isEmpty else { return false }
            components.removeLast()
        } else if component != "." && !component.isEmpty {
            components.append(String(component))
        }
    }
    return true
}
