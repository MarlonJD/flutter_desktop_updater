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
        rawJSON = json
    }
}

public struct ReleaseInstall {
    public let strategy: String
    public let rawJSON: [String: Any]

    init(json: [String: Any], platform: String, artifactKind: String) throws {
        strategy = try runtimeString(json, "strategy")
        rawJSON = json
        switch artifactKind {
        case "zip":
            break
        case "dmg":
            guard platform == "macos",
                  strategy == "wholeBundleReplace",
                  let metadata = json["macosDmg"] as? [String: Any],
                  let appName = metadata["appBundleName"] as? String,
                  appName.hasSuffix(".app")
            else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Invalid macOS DMG install metadata."
                )
            }
        case "pkgInstaller":
            guard platform == "macos",
                  strategy == "pkgInstaller",
                  let metadata = json["macosPkg"] as? [String: Any],
                  metadata["launchMode"] as? String == "installerApp",
                  let packageIds = metadata["expectedPackageIds"] as? [String],
                  !packageIds.isEmpty
            else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Invalid macOS PKG install metadata."
                )
            }
        case "innoInstaller":
            guard platform == "windows",
                  strategy == "innoInstaller",
                  let metadata = json["inno"] as? [String: Any],
                  let arguments = metadata["silentArgs"] as? [String],
                  !arguments.isEmpty,
                  metadata["authenticode"] is [String: Any]
            else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Invalid Windows Inno install metadata."
                )
            }
        default:
            throw RuntimeError.outcome(
                .unsupportedArtifactKind,
                message: "Unsupported artifact kind \(artifactKind)."
            )
        }
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
        packageId = try runtimeString(json, "packageId")
        appName = try runtimeString(json, "appName")
        version = try runtimeString(json, "version")
        _ = try DesktopVersion(version)
        buildNumber = try runtimeOptionalInt64(json["buildNumber"])
        if let buildNumber, buildNumber < 0 {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Build number must not be negative."
            )
        }
        platform = try runtimeString(json, "platform")
        channel = (json["channel"] as? String) ?? "stable"
        artifact = try ReleaseArtifact(
            json: runtimeDictionary(json["artifact"] as Any)
        )
        install = try ReleaseInstall(
            json: runtimeDictionary(json["install"] as Any),
            platform: platform,
            artifactKind: artifact.kind
        )
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
                guard !key.isEmpty,
                      let version = value as? String,
                      !version.isEmpty
                else {
                    throw RuntimeError.outcome(
                        .invalidDescriptor,
                        message: "Invalid minimum OS policy."
                    )
                }
                parsed[key] = version
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
            deltaArtifacts = try values.map(runtimeDictionary)
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
        rawJSON = json
    }

    public func canonicalSignatureBytes() throws -> Data {
        var canonical = rawJSON
        if var signature = canonical["signature"] as? [String: Any] {
            signature["value"] = ""
            canonical["signature"] = signature
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
