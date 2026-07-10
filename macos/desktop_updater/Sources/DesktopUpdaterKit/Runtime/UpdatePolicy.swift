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
        guard let dot = value.firstIndex(of: ".") else {
            return plain.date(from: value)
        }
        let fractionStart = value.index(after: dot)
        var fractionEnd = fractionStart
        while fractionEnd < value.endIndex,
              value[fractionEnd].isNumber
        {
            fractionEnd = value.index(after: fractionEnd)
        }
        let fraction = String(value[fractionStart ..< fractionEnd])
        guard !fraction.isEmpty else { return nil }
        let milliseconds = String(fraction.prefix(3)) +
            String(repeating: "0", count: max(0, 3 - fraction.count))
        let normalized = String(value[...dot]) + milliseconds +
            String(value[fractionEnd...])
        guard let base = fractional.date(from: normalized) else { return nil }
        let sixDigits = String(fraction.prefix(6)) +
            String(repeating: "0", count: max(0, 6 - fraction.count))
        guard let microseconds = Int(sixDigits) else { return nil }
        let remainingMicroseconds = microseconds % 1_000
        return base.addingTimeInterval(
            TimeInterval(remainingMicroseconds) / 1_000_000
        )
    }

    static func string(_ value: Date) -> String {
        var wholeSeconds = floor(value.timeIntervalSince1970)
        var microseconds = Int(
            ((value.timeIntervalSince1970 - wholeSeconds) * 1_000_000)
                .rounded()
        )
        if microseconds == 1_000_000 {
            wholeSeconds += 1
            microseconds = 0
        }
        let plainUTC = plain.string(
            from: Date(timeIntervalSince1970: wholeSeconds)
        )
        let base = String(plainUTC.dropLast())
        let milliseconds = microseconds / 1_000
        let remainingMicroseconds = microseconds % 1_000
        if remainingMicroseconds == 0 {
            return String(format: "%@.%03dZ", base, milliseconds)
        }
        return String(
            format: "%@.%03d%03dZ",
            base,
            milliseconds,
            remainingMicroseconds
        )
    }
}
