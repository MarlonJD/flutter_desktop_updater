import Foundation

public enum SupportPolicyStatus: String, Sendable {
    case supported
    case warning
    case blocked
}

public struct ReleaseSupportPolicy {
    public let minimumSupportedVersion: DesktopVersion
    public let enforcedAfter: Date

    public init(json: [String: Any]) throws {
        minimumSupportedVersion = try DesktopVersion(
            runtimeString(json, "minimumSupportedVersion")
        )
        let value = try runtimeString(json, "enforcedAfter")
        guard let date = RuntimeISO8601.date(value) else {
            throw RuntimeError.outcome(
                .invalidDescriptor,
                message: "Invalid support policy deadline."
            )
        }
        enforcedAfter = date
    }

    public func applies(to currentVersion: DesktopVersion) -> Bool {
        return currentVersion < minimumSupportedVersion
    }

    public func isEnforced(
        currentVersion: DesktopVersion,
        now: Date
    ) -> Bool {
        return applies(to: currentVersion) && now >= enforcedAfter
    }

    public func status(
        currentVersion: DesktopVersion,
        now: Date
    ) -> SupportPolicyStatus {
        guard applies(to: currentVersion) else { return .supported }
        return now >= enforcedAfter ? .blocked : .warning
    }
}

public enum UpdatePolicy {
    public static func descriptorOutcome(
        descriptor: ReleaseDescriptor,
        currentUpdaterVersion: DesktopVersion,
        platform: String,
        minimumOSSupported: (String, String) -> Bool
    ) throws -> RuntimeOutcome? {
        if currentUpdaterVersion < (try DesktopVersion(
            descriptor.minimumUpdaterVersion
        )) {
            return .unsupportedMinimumUpdater
        }
        if let minimumOS = descriptor.minimumOS[platform],
           !minimumOSSupported(platform, minimumOS)
        {
            return .unsupportedMinimumOS
        }
        return .updateAvailable
    }
}

enum RuntimeISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    static func date(_ value: String) -> Date? {
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}
