import Foundation

public struct DesktopVersion: Equatable, Comparable, Sendable {
    public let rawValue: String
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [PrereleaseIdentifier]
    public let buildNumber: Int64?

    public init(_ rawValue: String, buildNumber: Int64? = nil) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RuntimeError.invalidConfiguration("Version must not be empty.")
        }
        let versionAndBuild = trimmed.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let versionAndPrerelease = versionAndBuild[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let components = versionAndPrerelease[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0,
              minor >= 0,
              patch >= 0
        else {
            throw RuntimeError.invalidConfiguration(
                "Version must use semantic MAJOR.MINOR.PATCH syntax."
            )
        }
        let prerelease = versionAndPrerelease.count == 2
            ? try versionAndPrerelease[1].split(separator: ".").map {
                try PrereleaseIdentifier(String($0))
            }
            : []
        let metadataBuild = versionAndBuild.count == 2
            ? versionAndBuild[1]
                .split(separator: ".", omittingEmptySubsequences: false)
                .first
                .flatMap { Int64($0) }
            : nil
        if let buildNumber, buildNumber < 0 {
            throw RuntimeError.invalidConfiguration(
                "Build number must not be negative."
            )
        }

        self.rawValue = trimmed
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildNumber = buildNumber ?? metadataBuild
    }

    public static func < (left: DesktopVersion, right: DesktopVersion) -> Bool {
        if let leftBuild = left.buildNumber,
           let rightBuild = right.buildNumber
        {
            return leftBuild < rightBuild
        }
        if left.major != right.major { return left.major < right.major }
        if left.minor != right.minor { return left.minor < right.minor }
        if left.patch != right.patch { return left.patch < right.patch }
        if left.prerelease.isEmpty != right.prerelease.isEmpty {
            return !left.prerelease.isEmpty
        }
        for index in 0 ..< min(left.prerelease.count, right.prerelease.count) {
            if left.prerelease[index] != right.prerelease[index] {
                return left.prerelease[index] < right.prerelease[index]
            }
        }
        return left.prerelease.count < right.prerelease.count
    }
}

public enum PrereleaseIdentifier: Equatable, Comparable, Sendable {
    case numeric(Int)
    case text(String)

    init(_ value: String) throws {
        guard !value.isEmpty else {
            throw RuntimeError.invalidConfiguration(
                "Prerelease identifiers must not be empty."
            )
        }
        self = Int(value).map(PrereleaseIdentifier.numeric) ?? .text(value)
    }

    public static func < (
        left: PrereleaseIdentifier,
        right: PrereleaseIdentifier
    ) -> Bool {
        switch (left, right) {
        case let (.numeric(leftValue), .numeric(rightValue)):
            return leftValue < rightValue
        case (.numeric, .text):
            return true
        case (.text, .numeric):
            return false
        case let (.text(leftValue), .text(rightValue)):
            return leftValue < rightValue
        }
    }
}
