import Foundation

public struct ReleaseArtifact {
    public let kind: String
    public let url: URL
    public let sha256: String
    public let length: Int64
    public let rawJSON: [String: Any]

    init(json: [String: Any]) throws {
        kind = try runtimeString(json, "kind")
        url = try runtimeAbsoluteURL(json, "url")
        sha256 = try runtimeString(json, "sha256")
        guard sha256.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil else {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Artifact SHA-256 must use lowercase hexadecimal."
            )
        }
        guard let parsedLength = try runtimeOptionalInt64(json["length"]),
              parsedLength >= 0
        else {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Artifact length must not be negative."
            )
        }
        length = parsedLength
        rawJSON = [
            "kind": kind,
            "url": url.absoluteString,
            "sha256": sha256,
            "length": length,
        ]
    }
}

public struct ReleaseInstall {
    public let strategy: String
    public let normalizedJSON: [String: Any]
    public let rawJSON: [String: Any]

    init(json: [String: Any], platform: String, artifactKind: String) throws {
        strategy = try runtimeTrimmedString(json, "strategy")
        guard ["zip", "dmg", "pkgInstaller", "innoInstaller"]
            .contains(artifactKind)
        else {
            throw RuntimeError.outcome(
                .unsupportedArtifactKind,
                message: "Unsupported artifact kind \(artifactKind)."
            )
        }

        var normalized: [String: Any] = ["strategy": strategy]
        var pkgWireLaunchMode: String?
        if let rawInno = json["inno"] {
            let metadata = try runtimeDictionary(rawInno)
            let arguments = try runtimeStringList(
                metadata["silentArgs"],
                key: "silentArgs"
            )
            let inheritDirectory = try runtimeOptionalBool(
                metadata["inheritInstallDirectory"],
                default: true
            )
            let logFileName = try runtimeOptionalString(
                metadata["logFileName"],
                default: "desktop_updater_inno_install.log"
            )
            let relaunch = try runtimeOptionalBool(
                metadata["relaunchAfterInstall"],
                default: true
            )
            let elevation = try runtimeOptionalString(
                metadata["requiresElevation"],
                default: "auto"
            )
            var authenticode: [String: Any] = ["required": false]
            if let rawAuthenticode = metadata["authenticode"] {
                let policy = try runtimeDictionary(rawAuthenticode)
                let required = try runtimeOptionalBool(
                    policy["required"],
                    default: false
                )
                let thumbprints = try runtimeStringList(
                    policy["sha256Thumbprints"],
                    key: "sha256Thumbprints",
                    default: []
                )
                authenticode = ["required": required]
                if !thumbprints.isEmpty {
                    authenticode["sha256Thumbprints"] = thumbprints
                }
            }
            normalized["inno"] = [
                "silentArgs": arguments,
                "inheritInstallDirectory": inheritDirectory,
                "logFileName": logFileName,
                "relaunchAfterInstall": relaunch,
                "requiresElevation": elevation,
                "authenticode": authenticode,
            ]
        }
        if let rawDMG = json["macosDmg"] {
            let metadata = try runtimeDictionary(rawDMG)
            normalized["macosDmg"] = [
                "appBundleName": try runtimeString(metadata, "appBundleName"),
                "verifyPrimarySignature": try runtimeOptionalBool(
                    metadata["verifyPrimarySignature"],
                    default: true
                ),
            ]
        }
        if let rawPKG = json["macosPkg"] {
            let metadata = try runtimeDictionary(rawPKG)
            let rawLaunchMode = try runtimeOptionalString(
                metadata["launchMode"],
                default: "installerApp"
            )
            pkgWireLaunchMode = rawLaunchMode
            normalized["macosPkg"] = [
                "launchMode": rawLaunchMode == "installerApp"
                    ? "privilegedInstallerTool"
                    : rawLaunchMode,
                "expectedPackageIds": try runtimeStringList(
                    metadata["expectedPackageIds"],
                    key: "expectedPackageIds",
                    default: []
                ),
                "relaunchAfterInstall": try runtimeOptionalBool(
                    metadata["relaunchAfterInstall"],
                    default: false
                ),
            ]
        }

        if strategy == "pkgInstaller", artifactKind != "pkgInstaller" {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "PKG strategy requires a PKG artifact."
            )
        }
        if strategy == "innoInstaller",
           (platform != "windows" || artifactKind != "innoInstaller")
        {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Inno strategy requires a Windows installer artifact."
            )
        }
        if artifactKind == "dmg" {
            guard platform == "macos",
                  strategy == "wholeBundleReplace",
                  let metadata = normalized["macosDmg"] as? [String: Any],
                  let appName = metadata["appBundleName"] as? String,
                  appName.hasSuffix(".app"),
                  !appName.contains("/")
            else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Invalid macOS DMG install metadata."
                )
            }
        }
        if artifactKind == "pkgInstaller" {
            guard platform == "macos",
                  strategy == "pkgInstaller",
                  let metadata = normalized["macosPkg"] as? [String: Any],
                  metadata["launchMode"] as? String == "privilegedInstallerTool",
                  let packageIds = metadata["expectedPackageIds"] as? [String],
                  !packageIds.isEmpty
            else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Invalid macOS PKG install metadata."
                )
            }
        }
        if artifactKind == "innoInstaller" {
            let innoMetadata = normalized["inno"] as? [String: Any]
            let authenticode = innoMetadata?["authenticode"]
                as? [String: Any]
            let thumbprints =
                (authenticode?["sha256Thumbprints"] as? [String]) ?? []
            guard platform == "windows",
                  strategy == "innoInstaller",
                  let metadata = innoMetadata,
                  let arguments = metadata["silentArgs"] as? [String],
                  !arguments.isEmpty,
                  arguments.contains("/VERYSILENT") || arguments.contains("/SILENT"),
                  let logFileName = metadata["logFileName"] as? String,
                  !logFileName.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  !logFileName.contains("/"),
                  !logFileName.contains("\\"),
                  let elevation = metadata["requiresElevation"] as? String,
                  ["auto", "always", "never"].contains(elevation),
                  let authenticode,
                  let required = authenticode["required"] as? Bool,
                  !required || !thumbprints.isEmpty,
                  thumbprints.allSatisfy({
                      $0.range(
                          of: "^[0-9A-Fa-f]{64}$",
                          options: .regularExpression
                      ) != nil
                  })
            else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Invalid Windows Inno install metadata."
                )
            }
        }
        normalizedJSON = normalized
        if let pkgWireLaunchMode,
           var wirePKG = normalized["macosPkg"] as? [String: Any]
        {
            wirePKG["launchMode"] = pkgWireLaunchMode
            normalized["macosPkg"] = wirePKG
        }
        rawJSON = normalized
    }
}

public struct ReleaseSignature {
    public let algorithm: String
    public let publicKeyId: String
    public let value: String
}

public struct ReleaseDescriptor {
    public let schemaVersion: Int
    public let packageId: String
    public let appName: String
    public let version: String
    public let buildNumber: Int64?
    public let platform: String
    public let channel: String
    public let artifact: ReleaseArtifact
    public let install: ReleaseInstall
    public let signature: ReleaseSignature?
    public let minimumUpdaterVersion: String
    public let minimumOS: [String: String]
    public let deltaArtifacts: [[String: Any]]
    public let generatedAt: Date
    public let rawJSON: [String: Any]

    public init(jsonData: Data) throws {
        let json = try runtimeDictionary(
            JSONSerialization.jsonObject(with: jsonData)
        )
        guard try runtimeInt(json, "schemaVersion") == 3 else {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Release descriptor must use schema version 3."
            )
        }
        schemaVersion = 3
        packageId = try runtimeTrimmedString(json, "packageId")
        appName = try runtimeString(json, "appName")
        version = try runtimeTrimmedString(json, "version")
        _ = try DesktopVersion(version)
        buildNumber = try runtimeOptionalInt64(json["buildNumber"])
        if let buildNumber, buildNumber < 0 {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Build number must not be negative."
            )
        }
        platform = try runtimeTrimmedString(json, "platform")
        channel = try json["channel"].map { _ in
            try runtimeTrimmedString(json, "channel")
        } ?? "stable"
        artifact = try ReleaseArtifact(
            json: runtimeDictionary(json["artifact"] as Any)
        )
        install = try ReleaseInstall(
            json: runtimeDictionary(json["install"] as Any),
            platform: platform,
            artifactKind: artifact.kind
        )
        if artifact.kind == "pkgInstaller", buildNumber == nil {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "PKG release descriptors require a build number."
            )
        }
        if let signatureJSON = json["signature"] {
            let value = try runtimeDictionary(signatureJSON)
            signature = ReleaseSignature(
                algorithm: try runtimeString(value, "algorithm"),
                publicKeyId: try runtimeString(value, "publicKeyId"),
                value: try runtimeStringAllowingEmpty(value, "value")
            )
        } else {
            signature = nil
        }
        minimumUpdaterVersion = try runtimeString(
            json,
            "minimumUpdaterVersion"
        )
        _ = try DesktopVersion(minimumUpdaterVersion)
        if let minimumOSJSON = json["minimumOS"] {
            let values = try runtimeDictionary(minimumOSJSON)
            var parsed: [String: String] = [:]
            for (key, value) in values {
                let normalizedKey = key.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard let rawVersion = value as? String else {
                    throw RuntimeError.outcome(
                        .invalidDescriptor,
                        message: "Invalid minimum OS policy."
                    )
                }
                let version = rawVersion.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !normalizedKey.isEmpty, !version.isEmpty
                else {
                    throw RuntimeError.outcome(
                        .invalidDescriptor,
                        message: "Invalid minimum OS policy."
                    )
                }
                parsed[normalizedKey] = version
            }
            minimumOS = parsed
        } else {
            minimumOS = [:]
        }
        if let deltaJSON = json["deltaArtifacts"] {
            guard let values = deltaJSON as? [Any] else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Delta artifacts must be a list."
                )
            }
            deltaArtifacts = try values.map {
                let delta = try runtimeDictionary($0)
                let fromVersion = try runtimeString(delta, "fromVersion")
                guard try runtimeString(delta, "kind") == "bsdiff",
                      let url = URL(
                          string: try runtimeString(delta, "url")
                      ),
                      url.scheme?.isEmpty == false,
                      try runtimeString(delta, "sha256").range(
                          of: "^[0-9a-f]{64}$",
                          options: .regularExpression
                      ) != nil,
                      let length = try runtimeOptionalInt64(delta["length"]),
                      length >= 0,
                      !fromVersion.isEmpty
                else {
                    throw RuntimeError.outcome(
                        .invalidDescriptor,
                        message: "Invalid delta artifact metadata."
                    )
                }
                return [
                    "fromVersion": fromVersion,
                    "kind": try runtimeString(delta, "kind"),
                    "url": url.absoluteString,
                    "sha256": try runtimeString(delta, "sha256"),
                    "length": length,
                ]
            }
        } else {
            deltaArtifacts = []
        }
        guard let generated = RuntimeISO8601.date(
            try runtimeString(json, "generatedAt")
        ) else {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Invalid descriptor generation time."
            )
        }
        generatedAt = generated
        var normalized: [String: Any] = [
            "schemaVersion": schemaVersion,
            "packageId": packageId,
            "appName": appName,
            "version": version,
            "platform": platform,
            "channel": channel,
            "artifact": artifact.rawJSON,
            "install": install.rawJSON,
            "minimumUpdaterVersion": minimumUpdaterVersion,
            "generatedAt": RuntimeISO8601.string(generatedAt),
        ]
        if let buildNumber {
            normalized["buildNumber"] = buildNumber
        }
        if let signature {
            normalized["signature"] = [
                "algorithm": signature.algorithm,
                "publicKeyId": signature.publicKeyId,
                "value": signature.value,
            ]
        }
        if !minimumOS.isEmpty {
            normalized["minimumOS"] = minimumOS
        }
        if !deltaArtifacts.isEmpty {
            normalized["deltaArtifacts"] = deltaArtifacts
        }
        rawJSON = normalized
    }

    public func canonicalSignatureBytes() throws -> Data {
        var canonical: [String: Any] = [
            "schemaVersion": schemaVersion,
            "packageId": packageId,
            "appName": appName,
            "version": version,
            "platform": platform,
            "channel": channel,
            "artifact": artifact.rawJSON,
            "install": install.rawJSON,
            "minimumUpdaterVersion": minimumUpdaterVersion,
            "generatedAt": RuntimeISO8601.string(generatedAt),
        ]
        if let buildNumber {
            canonical["buildNumber"] = buildNumber
        }
        if let signature {
            canonical["signature"] = [
                "algorithm": signature.algorithm,
                "publicKeyId": signature.publicKeyId,
                "value": "",
            ]
        }
        if !minimumOS.isEmpty {
            canonical["minimumOS"] = minimumOS
        }
        if !deltaArtifacts.isEmpty {
            canonical["deltaArtifacts"] = deltaArtifacts
        }
        return try JSONSerialization.data(
            withJSONObject: canonical,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public func bindingOutcome(
        indexItem: ReleaseIndexItem,
        expectedPackageId: String
    ) -> RuntimeOutcome? {
        if packageId != expectedPackageId {
            return .packageIdentityMismatch
        }
        if version != indexItem.version ||
            buildNumber != indexItem.buildNumber ||
            platform != indexItem.platform ||
            channel != indexItem.channel
        {
            return .invalidDescriptor
        }
        return nil
    }
}

private func runtimeOptionalBool(
    _ value: Any?,
    default defaultValue: Bool
) throws -> Bool {
    guard let value else { return defaultValue }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected boolean install metadata."
        )
    }
    return number.boolValue
}

private func runtimeOptionalString(
    _ value: Any?,
    default defaultValue: String
) throws -> String {
    guard let value else { return defaultValue }
    guard let string = value as? String else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected string install metadata."
        )
    }
    return string
}

private func runtimeStringList(
    _ value: Any?,
    key: String,
    default defaultValue: [String]? = nil
) throws -> [String] {
    guard let value else {
        if let defaultValue { return defaultValue }
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected list \(key)."
        )
    }
    guard let values = value as? [Any] else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected list \(key)."
        )
    }
    guard values.allSatisfy({ $0 is String }) else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected string entries in list \(key)."
        )
    }
    return values.compactMap { $0 as? String }
}

private func runtimeStringAllowingEmpty(
    _ source: [String: Any],
    _ key: String
) throws -> String {
    guard let value = source[key] as? String else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected string \(key)."
        )
    }
    return value
}
