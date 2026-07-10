import Foundation

public typealias RuntimeMinimumOSResolver = (
    _ platform: String,
    _ minimumOS: String
) -> Bool

public typealias RuntimeRequestHeadersProvider = (
    _ url: URL
) -> [String: String]

public enum RuntimeOutcome: String, CaseIterable, Sendable {
    case noUpdate
    case updateAvailable
    case freshInstallRequired
    case unsupportedMinimumUpdater
    case unsupportedMinimumOS
    case rolloutIneligible
    case unsupportedArtifactKind
    case invalidDescriptor
    case signatureFailure
    case packageIdentityMismatch
    case downloadFailure
    case artifactIntegrityFailure
    case unsafeArchive
    case stagingFailure
    case installHandoffFailure
}

public enum RuntimeError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case outcome(RuntimeOutcome, message: String)
}

extension RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            return message
        case let .outcome(outcome, message):
            return "\(outcome.rawValue): \(message)"
        }
    }
}

public struct RuntimeConfiguration {
    public let appArchiveUrl: URL
    public let expectedPackageId: String
    public let currentVersion: String
    public let currentBuildNumber: Int64?
    public let currentUpdaterVersion: String
    public let platform: String
    public let channel: String
    public let installationIdentity: String?
    public let requireDescriptorSignature: Bool
    public let pinnedPublicKeysById: [String: Data]
    public let minimumOSResolver: RuntimeMinimumOSResolver
    public let requestHeadersProvider: RuntimeRequestHeadersProvider
    public let downloadTimeout: TimeInterval
    public let maximumMetadataBytes: Int64
    public let maximumArchiveEntries: Int64
    public let maximumUncompressedBytes: Int64
    public let maximumSingleEntryBytes: Int64

    public init(
        appArchiveUrl: URL,
        expectedPackageId: String,
        currentVersion: String,
        currentBuildNumber: Int64?,
        currentUpdaterVersion: String,
        platform: String,
        channel: String = "stable",
        installationIdentity: String? = nil,
        requireDescriptorSignature: Bool = true,
        pinnedPublicKeysById: [String: Data],
        minimumOSResolver: @escaping RuntimeMinimumOSResolver = { _, _ in true },
        requestHeadersProvider: @escaping RuntimeRequestHeadersProvider = { _ in [:] },
        downloadTimeout: TimeInterval = 30,
        maximumMetadataBytes: Int64 = 4 * 1024 * 1024,
        maximumArchiveEntries: Int64 = 100_000,
        maximumUncompressedBytes: Int64 = 8 * 1024 * 1024 * 1024,
        maximumSingleEntryBytes: Int64 = 4 * 1024 * 1024 * 1024
    ) throws {
        guard appArchiveUrl.scheme?.isEmpty == false else {
            throw RuntimeError.invalidConfiguration(
                "appArchiveUrl must be absolute."
            )
        }
        for (name, value) in [
            ("expectedPackageId", expectedPackageId),
            ("currentVersion", currentVersion),
            ("currentUpdaterVersion", currentUpdaterVersion),
            ("platform", platform),
            ("channel", channel),
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RuntimeError.invalidConfiguration("\(name) must not be empty.")
        }
        if let currentBuildNumber, currentBuildNumber < 0 {
            throw RuntimeError.invalidConfiguration(
                "currentBuildNumber must not be negative."
            )
        }
        if requireDescriptorSignature && pinnedPublicKeysById.isEmpty {
            throw RuntimeError.invalidConfiguration(
                "At least one pinned public key is required."
            )
        }
        if pinnedPublicKeysById.contains(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                $0.value.count != 32
        }) {
            throw RuntimeError.invalidConfiguration(
                "Pinned Ed25519 keys require a non-empty ID and 32 bytes."
            )
        }
        guard downloadTimeout > 0 else {
            throw RuntimeError.invalidConfiguration(
                "downloadTimeout must be greater than zero."
            )
        }
        guard maximumMetadataBytes > 0,
              maximumArchiveEntries > 0,
              maximumUncompressedBytes > 0,
              maximumSingleEntryBytes > 0
        else {
            throw RuntimeError.invalidConfiguration(
                "Runtime safety limits must be greater than zero."
            )
        }

        self.appArchiveUrl = appArchiveUrl
        self.expectedPackageId = expectedPackageId
        self.currentVersion = currentVersion
        self.currentBuildNumber = currentBuildNumber
        self.currentUpdaterVersion = currentUpdaterVersion
        self.platform = platform
        self.channel = channel
        self.installationIdentity = installationIdentity
        self.requireDescriptorSignature = requireDescriptorSignature
        self.pinnedPublicKeysById = pinnedPublicKeysById
        self.minimumOSResolver = minimumOSResolver
        self.requestHeadersProvider = requestHeadersProvider
        self.downloadTimeout = downloadTimeout
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumArchiveEntries = maximumArchiveEntries
        self.maximumUncompressedBytes = maximumUncompressedBytes
        self.maximumSingleEntryBytes = maximumSingleEntryBytes
    }
}
