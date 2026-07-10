import CryptoKit
import Foundation

public struct ReleaseIndex {
    public let schemaVersion: Int
    public let appName: String
    public let items: [ReleaseIndexItem]
    public let supportPolicy: ReleaseSupportPolicy?
    public let signature: ReleaseSignature?

    public init(jsonData: Data) throws {
        let json = try runtimeDictionary(
            JSONSerialization.jsonObject(with: jsonData)
        )
        guard try runtimeInt(json, "schemaVersion") == 3 else {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Release index must use schema version 3."
            )
        }
        schemaVersion = 3
        appName = try runtimeString(json, "appName")
        items = try runtimeArray(json, "items").map {
            try ReleaseIndexItem(json: runtimeDictionary($0))
        }
        supportPolicy = try json["supportPolicy"].map {
            try ReleaseSupportPolicy(json: runtimeDictionary($0))
        }
        signature = try json["signature"].map {
            let value = try runtimeDictionary($0)
            guard let algorithm = value["algorithm"] as? String,
                  let publicKeyId = value["publicKeyId"] as? String,
                  let signatureValue = value["value"] as? String
            else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Invalid app archive signature envelope."
                )
            }
            return ReleaseSignature(
                algorithm: algorithm,
                publicKeyId: publicKeyId,
                value: signatureValue
            )
        }
    }

    public func canonicalSignatureBytes() throws -> Data {
        var canonical: [String: Any] = [
            "schemaVersion": schemaVersion,
            "appName": appName,
            "items": items.map(\.canonicalJSON),
        ]
        if let supportPolicy {
            canonical["supportPolicy"] = [
                "minimumSupportedVersion":
                    supportPolicy.minimumSupportedVersion.rawValue,
                "enforcedAfter": RuntimeISO8601.string(
                    supportPolicy.enforcedAfter
                ),
            ]
        }
        if let signature {
            canonical["signature"] = [
                "algorithm": signature.algorithm,
                "publicKeyId": signature.publicKeyId,
                "value": "",
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: canonical,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

public struct ReleaseIndexItem {
    public let version: String
    public let buildNumber: Int64?
    public let platform: String
    public let channel: String
    public let mandatory: Bool
    public let release: URL
    public let freshInstall: ReleaseFreshInstall?
    public let rollout: ReleaseRollout?

    var canonicalJSON: [String: Any] {
        var result: [String: Any] = [
            "version": version,
            "platform": platform,
            "channel": channel,
            "mandatory": mandatory,
            "release": release.absoluteString,
        ]
        if let buildNumber {
            result["buildNumber"] = buildNumber
        }
        if let freshInstall {
            var fresh: [String: Any] = [
                "downloadUrl": freshInstall.downloadURL.absoluteString
            ]
            if let message = freshInstall.message {
                fresh["message"] = message
            }
            result["freshInstall"] = fresh
        }
        if let rollout {
            result["rollout"] = [
                "percentage": rollout.percentage,
                "salt": rollout.salt,
            ]
        }
        return result
    }

    public init(json: [String: Any]) throws {
        version = try runtimeTrimmedString(json, "version")
        buildNumber = try runtimeOptionalInt64(json["buildNumber"] ?? json["shortVersion"])
        platform = try runtimeTrimmedString(json, "platform")
        channel = try json["channel"].map { _ in
            try runtimeTrimmedString(json, "channel")
        } ?? "stable"
        mandatory = (json["mandatory"] as? Bool) ?? false
        release = try runtimeAbsoluteURL(json, "release")
        freshInstall = try json["freshInstall"].map {
            try ReleaseFreshInstall(json: runtimeDictionary($0))
        }
        rollout = try json["rollout"].map {
            try ReleaseRollout(json: runtimeDictionary($0))
        }
    }
}

public struct ReleaseFreshInstall {
    public let downloadURL: URL
    public let message: String?

    public init(json: [String: Any]) throws {
        downloadURL = try runtimeAbsoluteURL(json, "downloadUrl")
        message = json["message"] as? String
    }
}

public struct ReleaseRollout {
    public let percentage: Int
    public let salt: String

    public init(json: [String: Any]) throws {
        percentage = try runtimeInt(json, "percentage")
        salt = try runtimeString(json, "salt")
        guard (0 ... 100).contains(percentage), !salt.isEmpty else {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Invalid rollout policy."
            )
        }
    }

    public func includes(channel: String, identity: String?) -> Bool {
        if percentage == 100 { return true }
        guard percentage > 0,
              let identity = identity?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !identity.isEmpty
        else {
            return false
        }
        let digest = SHA256.hash(
            data: Data("\(salt)\n\(channel)\n\(identity)".utf8)
        )
        let value = digest.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) + UInt32($1)
        }
        return Int(value % 100) < percentage
    }
}

public func selectReleaseIndexItem(
    index: ReleaseIndex,
    platform: String,
    channel: String,
    currentVersion: DesktopVersion,
    installationIdentity: String?
) throws -> ReleaseIndexItem? {
    let candidates = try index.items.filter { item in
        guard item.platform == platform, item.channel == channel else {
            return false
        }
        if let rollout = item.rollout,
           !rollout.includes(channel: item.channel, identity: installationIdentity)
        {
            return false
        }
        return try DesktopVersion(
            item.version,
            buildNumber: item.buildNumber.flatMap { $0 > 0 ? $0 : nil }
        ) > currentVersion
    }
    return try candidates.max {
        try DesktopVersion(
            $0.version,
            buildNumber: $0.buildNumber.flatMap { $0 > 0 ? $0 : nil }
        ) < DesktopVersion(
            $1.version,
            buildNumber: $1.buildNumber.flatMap { $0 > 0 ? $0 : nil }
        )
    }
}

func runtimeDictionary(_ value: Any) throws -> [String: Any] {
    guard let result = value as? [String: Any] else {
        throw RuntimeError.outcome(.invalidDescriptor, message: "Expected JSON object.")
    }
    return result
}

func runtimeArray(_ source: [String: Any], _ key: String) throws -> [Any] {
    guard let result = source[key] as? [Any] else {
        throw RuntimeError.outcome(.invalidDescriptor, message: "Expected array \(key).")
    }
    return result
}

func runtimeString(_ source: [String: Any], _ key: String) throws -> String {
    guard let value = source[key] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw RuntimeError.outcome(.invalidDescriptor, message: "Expected string \(key).")
    }
    return value
}

func runtimeTrimmedString(
    _ source: [String: Any],
    _ key: String
) throws -> String {
    return try runtimeString(source, key).trimmingCharacters(
        in: .whitespacesAndNewlines
    )
}

func runtimeInt(_ source: [String: Any], _ key: String) throws -> Int {
    guard let value = try runtimeOptionalInt64(source[key]),
          let result = Int(exactly: value)
    else {
        throw RuntimeError.outcome(.invalidDescriptor, message: "Expected integer \(key).")
    }
    return result
}

func runtimeOptionalInt64(_ value: Any?) throws -> Int64? {
    guard let value else { return nil }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
        throw RuntimeError.outcome(.invalidDescriptor, message: "Expected integer.")
    }
    let result = number.int64Value
    guard NSNumber(value: result) == number else {
        throw RuntimeError.outcome(.invalidDescriptor, message: "Expected integer.")
    }
    return result
}

func runtimeAbsoluteURL(_ source: [String: Any], _ key: String) throws -> URL {
    let value = try runtimeString(source, key)
    guard let url = URL(string: value), url.scheme?.isEmpty == false else {
        throw RuntimeError.outcome(.invalidDescriptor, message: "Expected absolute URL \(key).")
    }
    return url
}
