import Foundation

public struct RuntimeUpdateCheck {
    public let outcome: RuntimeOutcome
    public let selectedItem: ReleaseIndexItem?
    public let descriptor: ReleaseDescriptor?
    public let supportPolicyStatus: SupportPolicyStatus
    public let message: String

    public init(
        outcome: RuntimeOutcome,
        selectedItem: ReleaseIndexItem? = nil,
        descriptor: ReleaseDescriptor? = nil,
        supportPolicyStatus: SupportPolicyStatus = .supported,
        message: String = ""
    ) {
        self.outcome = outcome
        self.selectedItem = selectedItem
        self.descriptor = descriptor
        self.supportPolicyStatus = supportPolicyStatus
        self.message = message
    }
}

public struct RuntimeStagedUpdate {
    public let descriptor: ReleaseDescriptor
    public let stagedPath: URL
    public let artifactPath: URL

    public init(
        descriptor: ReleaseDescriptor,
        stagedPath: URL,
        artifactPath: URL
    ) {
        self.descriptor = descriptor
        self.stagedPath = stagedPath
        self.artifactPath = artifactPath
    }
}

public final class UpdateClient {
    public let configuration: RuntimeConfiguration
    public private(set) var diagnostics = RuntimeDiagnosticsRecorder()
    public private(set) var supportPolicyStatus: SupportPolicyStatus = .supported

    private let transport: RuntimeUpdateTransport
    private let stager: MacArtifactStager

    public init(
        configuration: RuntimeConfiguration,
        transport: RuntimeUpdateTransport = FoundationUpdateTransport(),
        stager: MacArtifactStager = MacArtifactStager()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.stager = stager
    }

    public func checkForUpdate() async -> RuntimeUpdateCheck {
        record(.check, .info, "Checking for a native update.")
        let indexData: Data
        do {
            indexData = try await transport.downloadMetadata(
                from: configuration.appArchiveUrl,
                configuration: configuration
            )
        } catch {
            return mappedFailure(error, fallback: .downloadFailure)
        }
        let index: ReleaseIndex
        do {
            index = try ReleaseIndex(jsonData: indexData)
        } catch {
            return mappedFailure(error, fallback: .invalidDescriptor)
        }
        do {
            let currentVersion = try DesktopVersion(
                configuration.currentVersion,
                buildNumber: configuration.currentBuildNumber
            )
            supportPolicyStatus = index.supportPolicy?.status(
                currentVersion: currentVersion,
                now: Date()
            ) ?? .supported
            if supportPolicyStatus != .supported {
                record(
                    .policy,
                    supportPolicyStatus == .blocked ? .error : .warning,
                    "Native support policy is \(supportPolicyStatus.rawValue)."
                )
            }
            let newerItems = try index.items.filter { item in
                guard item.platform == configuration.platform,
                      item.channel == configuration.channel
                else { return false }
                return try DesktopVersion(
                    item.version,
                    buildNumber: positiveBuildNumber(item.buildNumber)
                ) > currentVersion
            }
            guard !newerItems.isEmpty else {
                record(.check, .info, "No newer native release is available.")
                return RuntimeUpdateCheck(
                    outcome: .noUpdate,
                    supportPolicyStatus: supportPolicyStatus
                )
            }
            guard let selected = try selectReleaseIndexItem(
                index: index,
                platform: configuration.platform,
                channel: configuration.channel,
                currentVersion: currentVersion,
                installationIdentity: configuration.installationIdentity
            ) else {
                record(.policy, .info, "Installation is outside the rollout cohort.")
                return RuntimeUpdateCheck(
                    outcome: .rolloutIneligible,
                    supportPolicyStatus: supportPolicyStatus
                )
            }
            if selected.freshInstall != nil {
                record(.policy, .warning, "Selected release requires a fresh install.")
                return RuntimeUpdateCheck(
                    outcome: .freshInstallRequired,
                    selectedItem: selected,
                    supportPolicyStatus: supportPolicyStatus
                )
            }

            let descriptorData: Data
            do {
                descriptorData = try await transport.downloadMetadata(
                    from: selected.release,
                    configuration: configuration
                )
            } catch {
                return mappedFailure(error, fallback: .downloadFailure)
            }
            let descriptor: ReleaseDescriptor
            do {
                descriptor = try ReleaseDescriptor(jsonData: descriptorData)
            } catch {
                return mappedFailure(error, fallback: .invalidDescriptor)
            }
            guard descriptor.packageId == configuration.expectedPackageId else {
                return failure(
                    .packageIdentityMismatch,
                    "Descriptor package identity does not match.",
                    selectedItem: selected
                )
            }
            guard descriptor.version == selected.version,
                  descriptor.buildNumber == selected.buildNumber,
                  descriptor.platform == selected.platform,
                  descriptor.channel == selected.channel
            else {
                return failure(
                    .invalidDescriptor,
                    "Descriptor does not match its selected index item.",
                    selectedItem: selected
                )
            }
            if configuration.requireDescriptorSignature ||
                descriptor.signature != nil
            {
                guard try ArtifactVerifier.verifyDescriptorSignature(
                    descriptor,
                    pinnedPublicKeysById: configuration.pinnedPublicKeysById
                ) else {
                    return failure(
                        .signatureFailure,
                        "Descriptor Ed25519 signature is invalid.",
                        selectedItem: selected
                    )
                }
            }
            guard supportedArtifactKinds().contains(descriptor.artifact.kind) else {
                return failure(
                    .unsupportedArtifactKind,
                    "Artifact kind is not supported on this platform.",
                    selectedItem: selected,
                    descriptor: descriptor
                )
            }
            let policy = try UpdatePolicy.descriptorOutcome(
                descriptor: descriptor,
                currentUpdaterVersion: DesktopVersion(
                    configuration.currentUpdaterVersion
                ),
                platform: configuration.platform,
                minimumOSSupported: configuration.minimumOSResolver
            ) ?? .updateAvailable
            guard policy == .updateAvailable else {
                return failure(
                    policy,
                    "Selected descriptor is not installable on this host.",
                    selectedItem: selected,
                    descriptor: descriptor
                )
            }
            record(.descriptor, .info, "Verified selected native release descriptor.")
            return RuntimeUpdateCheck(
                outcome: .updateAvailable,
                selectedItem: selected,
                descriptor: descriptor,
                supportPolicyStatus: supportPolicyStatus
            )
        } catch {
            return mappedFailure(error, fallback: .invalidDescriptor)
        }
    }

    public func downloadVerifyAndStage(
        _ check: RuntimeUpdateCheck,
        downloadDirectory: URL,
        stagingRoot: URL,
        expectedTeamIdentifier: String,
        allowUnsignedUpdates: Bool = false,
        progress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async -> Result<RuntimeStagedUpdate, RuntimeError> {
        guard check.outcome == .updateAvailable,
              let descriptor = check.descriptor
        else {
            return .failure(.outcome(
                check.outcome,
                message: "No verified update is ready to download."
            ))
        }
        let artifactName = descriptor.artifact.url.lastPathComponent
        guard !artifactName.isEmpty, artifactName != ".", artifactName != ".." else {
            return .failure(.outcome(
                .invalidDescriptor,
                message: "Artifact URL does not contain a safe file name."
            ))
        }
        let artifactPath = downloadDirectory.appendingPathComponent(artifactName)
        do {
            try FileManager.default.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true
            )
            record(.download, .info, "Downloading verified native artifact.")
            try await transport.downloadArtifact(
                RuntimeArtifactDownload(
                    url: descriptor.artifact.url,
                    destination: artifactPath,
                    expectedLength: descriptor.artifact.length,
                    expectedSHA256: descriptor.artifact.sha256
                ),
                configuration: configuration,
                progress: progress
            )
            record(.verify, .info, "Artifact length and SHA-256 are verified.")
            let stagedPath: URL
            switch descriptor.artifact.kind {
            case "zip":
                stagedPath = try stager.stageZip(
                    archive: artifactPath,
                    stagingRoot: stagingRoot,
                    descriptor: descriptor,
                    expectedPackageId: configuration.expectedPackageId,
                    expectedTeamIdentifier: expectedTeamIdentifier,
                    allowUnsignedUpdates: allowUnsignedUpdates,
                    limits: RuntimeArchiveLimits(configuration: configuration)
                )
            case "dmg":
                stagedPath = try stager.stageDMG(
                    dmg: artifactPath,
                    stagingRoot: stagingRoot,
                    descriptor: descriptor,
                    expectedPackageId: configuration.expectedPackageId,
                    expectedTeamIdentifier: expectedTeamIdentifier,
                    allowUnsignedUpdates: allowUnsignedUpdates
                )
            case "pkgInstaller":
                stagedPath = try stager.stagePKG(
                    pkg: artifactPath,
                    stagingRoot: stagingRoot,
                    descriptor: descriptor,
                    expectedPackageId: configuration.expectedPackageId
                )
            default:
                throw RuntimeError.outcome(
                    .unsupportedArtifactKind,
                    message: "Artifact kind is not supported on macOS."
                )
            }
            record(.stage, .info, "Verified native artifact is staged.")
            return .success(RuntimeStagedUpdate(
                descriptor: descriptor,
                stagedPath: stagedPath,
                artifactPath: artifactPath
            ))
        } catch let runtimeError as RuntimeError {
            record(.stage, .error, "Native artifact staging failed.", runtimeError)
            return .failure(runtimeError)
        } catch {
            let runtimeError = RuntimeError.outcome(
                .stagingFailure,
                message: "Native artifact staging failed: \(error)"
            )
            record(.stage, .error, "Native artifact staging failed.", runtimeError)
            return .failure(runtimeError)
        }
    }

    public func installAndRelaunch(
        _ staged: RuntimeStagedUpdate,
        diagnosticsLogPath: String?,
        bundlePath: String,
        allowUnsignedUpdates: Bool = false
    ) throws {
        do {
            record(.install, .info, "Handing staged update to the macOS helper.")
            try stager.installAndRelaunch(
                stagedPath: staged.stagedPath,
                diagnosticsLogPath: diagnosticsLogPath,
                bundlePath: bundlePath,
                allowUnsignedUpdates: allowUnsignedUpdates
            )
        } catch {
            record(.install, .error, "macOS helper handoff failed.", error)
            throw RuntimeError.outcome(
                .installHandoffFailure,
                message: "macOS helper handoff failed: \(error)"
            )
        }
    }

    private func supportedArtifactKinds() -> Set<String> {
        configuration.platform == "macos"
            ? ["zip", "dmg", "pkgInstaller"]
            : []
    }

    private func positiveBuildNumber(_ value: Int64?) -> Int64? {
        value.flatMap { $0 > 0 ? $0 : nil }
    }

    private func mappedFailure(
        _ error: Error,
        fallback: RuntimeOutcome
    ) -> RuntimeUpdateCheck {
        if case let RuntimeError.outcome(outcome, message) = error {
            return failure(outcome, message)
        }
        if case let RuntimeError.invalidConfiguration(message) = error {
            return failure(.invalidDescriptor, message)
        }
        return failure(fallback, String(describing: error))
    }

    private func failure(
        _ outcome: RuntimeOutcome,
        _ message: String,
        selectedItem: ReleaseIndexItem? = nil,
        descriptor: ReleaseDescriptor? = nil
    ) -> RuntimeUpdateCheck {
        record(.check, .error, message)
        return RuntimeUpdateCheck(
            outcome: outcome,
            selectedItem: selectedItem,
            descriptor: descriptor,
            supportPolicyStatus: supportPolicyStatus,
            message: message
        )
    }

    private func record(
        _ stage: RuntimeDiagnosticStage,
        _ level: RuntimeDiagnosticLevel,
        _ message: String,
        _ error: Error? = nil
    ) {
        diagnostics.record(RuntimeDiagnosticEntry(
            timestamp: RuntimeClientTimestamp.string(),
            stage: stage,
            level: level,
            message: message,
            errorDescription: error.map(String.init(describing:))
        ))
    }
}

private enum RuntimeClientTimestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string() -> String {
        formatter.string(from: Date())
    }
}
