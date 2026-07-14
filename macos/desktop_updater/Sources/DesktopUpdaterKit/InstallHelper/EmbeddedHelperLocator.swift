import Foundation

public enum EmbeddedHelperLocatorError: Error, Equatable {
    case invalidServiceIdentifier
}

public struct EmbeddedHelperLocator {
    public static let oneShotRelativePath =
        "Contents/Helpers/DesktopUpdaterInstallHelper"
    public static let privilegedRelativeDirectory =
        "Contents/Helpers"
    public static let launchDaemonRelativeDirectory =
        "Contents/Library/LaunchDaemons"

    private let applicationBundleURL: URL

    public init(applicationBundleURL: URL) {
        self.applicationBundleURL = applicationBundleURL.standardizedFileURL
    }

    public var oneShotHelperURL: URL {
        applicationBundleURL.appendingPathComponent(
            Self.oneShotRelativePath,
            isDirectory: false
        )
    }

    public func privilegedHelperURL(
        serviceIdentifier: String
    ) throws -> URL {
        guard Self.isValidServiceIdentifier(serviceIdentifier) else {
            throw EmbeddedHelperLocatorError.invalidServiceIdentifier
        }
        return oneShotHelperURL
    }

    public func launchDaemonPlistURL(
        serviceIdentifier: String
    ) throws -> URL {
        guard Self.isValidServiceIdentifier(serviceIdentifier) else {
            throw EmbeddedHelperLocatorError.invalidServiceIdentifier
        }
        return applicationBundleURL
            .appendingPathComponent(
                Self.launchDaemonRelativeDirectory,
                isDirectory: true
            )
            .appendingPathComponent(
                "\(serviceIdentifier).plist",
                isDirectory: false
            )
    }

    private static func isValidServiceIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 128,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("..") else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
