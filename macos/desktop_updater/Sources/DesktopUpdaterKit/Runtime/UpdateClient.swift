import Foundation

public struct RuntimeUpdateCheck {
    public let outcome: RuntimeOutcome
    public let selectedItem: ReleaseIndexItem?
    public let descriptor: ReleaseDescriptor?
    public let supportPolicyStatus: SupportPolicyStatus
    public let message: String
    let clientID: UUID
    let generation: UInt64

    init(
        outcome: RuntimeOutcome,
        selectedItem: ReleaseIndexItem? = nil,
        descriptor: ReleaseDescriptor? = nil,
        supportPolicyStatus: SupportPolicyStatus = .supported,
        message: String = "",
        clientID: UUID,
        generation: UInt64
    ) {
        self.outcome = outcome
        self.selectedItem = selectedItem
        self.descriptor = descriptor
        self.supportPolicyStatus = supportPolicyStatus
        self.message = message
        self.clientID = clientID
        self.generation = generation
    }
}

public struct RuntimeStagedUpdate {
    public let descriptor: ReleaseDescriptor
    public let stagedPath: URL
    public let stageRoot: URL
    public let stageProvenanceSHA256: String
    public let provenanceEntries: [StageProvenanceEntry]
    public let artifactPath: URL
    let clientID: UUID
    let generation: UInt64

    init(
        descriptor: ReleaseDescriptor,
        stagedPath: URL,
        stageRoot: URL,
        stageProvenanceSHA256: String,
        provenanceEntries: [StageProvenanceEntry],
        artifactPath: URL,
        clientID: UUID,
        generation: UInt64
    ) {
        self.descriptor = descriptor
        self.stagedPath = stagedPath
        self.stageRoot = stageRoot
        self.stageProvenanceSHA256 = stageProvenanceSHA256
        self.provenanceEntries = provenanceEntries
        self.artifactPath = artifactPath
        self.clientID = clientID
        self.generation = generation
    }
}

private struct RuntimeCheckLease {
    let generation: UInt64
    let installInProgress: Bool
}

private struct RuntimeStageLease {
    let generation: UInt64
    let attempt: UInt64
}

private struct RuntimeInstallHandoff {
    let token: UInt64
    let generation: UInt64
    let stageAttempt: UInt64
    let staged: RuntimeStagedUpdate
}

private final class UpdateClientLifecycleState {
    let clientID = UUID()

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stageAttempt: UInt64 = 0
    private var activeStagedUpdate: RuntimeStagedUpdate?
    private var activeStagedAttempt: UInt64 = 0
    private var installInProgress = false
    private var nextHandoffToken: UInt64 = 0
    private var activeHandoffToken: UInt64 = 0
    private var schedulingConfirmed = false

    func beginCheck() -> RuntimeCheckLease {
        withLock {
            incrementNonzero(&generation)
            incrementNonzero(&stageAttempt)
            activeStagedUpdate = nil
            activeStagedAttempt = 0
            guard !installInProgress else {
                return RuntimeCheckLease(
                    generation: generation,
                    installInProgress: true
                )
            }
            return RuntimeCheckLease(
                generation: generation,
                installInProgress: false
            )
        }
    }

    func beginStage(
        _ check: RuntimeUpdateCheck
    ) -> Result<RuntimeStageLease, RuntimeError> {
        withLock {
            incrementNonzero(&stageAttempt)
            activeStagedUpdate = nil
            activeStagedAttempt = 0
            guard !installInProgress else {
                return .failure(.outcome(
                    .installHandoffFailure,
                    message: "An install helper handoff is already in progress."
                ))
            }
            guard check.clientID == clientID,
                  check.generation == generation
            else {
                return .failure(.outcome(
                    .invalidDescriptor,
                    message: "Update check does not belong to this client generation."
                ))
            }
            return .success(RuntimeStageLease(
                generation: generation,
                attempt: stageAttempt
            ))
        }
    }

    func stageIsCurrent(_ lease: RuntimeStageLease) -> Bool {
        withLock {
            !installInProgress &&
                lease.generation == generation &&
                lease.attempt == stageAttempt
        }
    }

    func publishStage(
        _ staged: RuntimeStagedUpdate,
        lease: RuntimeStageLease
    ) -> Bool {
        withLock {
            guard !installInProgress,
                  staged.clientID == clientID,
                  staged.generation == generation,
                  lease.generation == generation,
                  lease.attempt == stageAttempt
            else { return false }
            activeStagedUpdate = staged
            activeStagedAttempt = lease.attempt
            return true
        }
    }

    func beginInstall(
        _ staged: RuntimeStagedUpdate
    ) -> Result<RuntimeInstallHandoff, RuntimeError> {
        withLock {
            guard !installInProgress,
                  let active = activeStagedUpdate,
                  staged.clientID == clientID,
                  staged.generation == generation,
                  active.clientID == staged.clientID,
                  active.generation == staged.generation,
                  active.stagedPath == staged.stagedPath,
                  active.stageRoot == staged.stageRoot,
                  active.stageProvenanceSHA256 == staged.stageProvenanceSHA256,
                  active.artifactPath == staged.artifactPath,
                  activeStagedAttempt == stageAttempt
            else {
                return .failure(.outcome(
                    .installHandoffFailure,
                    message: "No client-bound staged update is ready for helper handoff."
                ))
            }
            incrementNonzero(&nextHandoffToken)
            installInProgress = true
            activeHandoffToken = nextHandoffToken
            schedulingConfirmed = false
            activeStagedUpdate = nil
            let handoff = RuntimeInstallHandoff(
                token: activeHandoffToken,
                generation: generation,
                stageAttempt: stageAttempt,
                staged: active
            )
            activeStagedAttempt = 0
            return .success(handoff)
        }
    }

    func rollback(_ handoff: RuntimeInstallHandoff) -> Bool {
        withLock {
            guard installInProgress,
                  !schedulingConfirmed,
                  handoff.token == activeHandoffToken
            else { return false }
            let canRestore = handoff.generation == generation &&
                handoff.stageAttempt == stageAttempt
            installInProgress = false
            activeHandoffToken = 0
            if canRestore {
                activeStagedUpdate = handoff.staged
                activeStagedAttempt = handoff.stageAttempt
            }
            return canRestore
        }
    }

    func confirm(_ handoff: RuntimeInstallHandoff) -> Bool {
        withLock {
            guard installInProgress,
                  !schedulingConfirmed,
                  handoff.token == activeHandoffToken
            else { return false }
            schedulingConfirmed = true
            return true
        }
    }

    private func incrementNonzero(_ value: inout UInt64) {
        value &+= 1
        if value == 0 {
            value &+= 1
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class RuntimeSchedulingRollbackGuard {
    private let state: UpdateClientLifecycleState
    private let handoff: RuntimeInstallHandoff
    private var active = true

    init(
        state: UpdateClientLifecycleState,
        handoff: RuntimeInstallHandoff
    ) {
        self.state = state
        self.handoff = handoff
    }

    deinit {
        if active {
            _ = state.rollback(handoff)
        }
    }

    func confirm() -> Bool {
        guard active, state.confirm(handoff) else { return false }
        active = false
        return true
    }

    func rollback() {
        guard active else { return }
        _ = state.rollback(handoff)
        active = false
    }
}

public final class UpdateClient {
    public let configuration: RuntimeConfiguration
    public private(set) var diagnostics = RuntimeDiagnosticsRecorder()
    public private(set) var supportPolicyStatus: SupportPolicyStatus = .supported

    private let transport: RuntimeUpdateTransport
    private let stager: MacArtifactStager
    private let lifecycle = UpdateClientLifecycleState()
    private let diagnosticsLock = NSLock()
    private let installScheduler: (
        RuntimeStagedUpdate,
        String?,
        Bool
    ) throws -> Void

    public init(
        configuration: RuntimeConfiguration,
        transport: RuntimeUpdateTransport = FoundationUpdateTransport(),
        stager: MacArtifactStager = MacArtifactStager()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.stager = stager
        installScheduler = { staged, diagnosticsLogPath, allowUnsigned in
            try stager.installAndRelaunch(
                staged: staged,
                diagnosticsLogPath: diagnosticsLogPath,
                allowUnsignedUpdates: allowUnsigned
            )
        }
    }

    init(
        configuration: RuntimeConfiguration,
        transport: RuntimeUpdateTransport,
        stager: MacArtifactStager,
        installScheduler: @escaping (
            RuntimeStagedUpdate,
            String?,
            Bool
        ) throws -> Void
    ) {
        self.configuration = configuration
        self.transport = transport
        self.stager = stager
        self.installScheduler = installScheduler
    }

    public func checkForUpdate() async -> RuntimeUpdateCheck {
        let checkLease = lifecycle.beginCheck()
        let checkGeneration = checkLease.generation
        guard !checkLease.installInProgress else {
            return failure(
                .installHandoffFailure,
                "An install helper handoff is already in progress.",
                generation: checkGeneration
            )
        }
        record(.check, .info, "Checking for a native update.")
        let indexData: Data
        do {
            indexData = try await transport.downloadMetadata(
                from: configuration.appArchiveUrl,
                configuration: configuration
            )
        } catch {
            return mappedFailure(
                error,
                fallback: .downloadFailure,
                generation: checkGeneration
            )
        }
        let index: ReleaseIndex
        do {
            index = try ReleaseIndex(jsonData: indexData)
        } catch {
            return mappedFailure(
                error,
                fallback: .invalidDescriptor,
                generation: checkGeneration
            )
        }
        if configuration.requireIndexSignature || index.signature != nil {
            do {
                guard try ArtifactVerifier.verifyIndexSignature(
                    index,
                    pinnedPublicKeysById: configuration.pinnedPublicKeysById
                ) else {
                    return failure(
                        .signatureFailure,
                        "App archive Ed25519 signature is invalid.",
                        generation: checkGeneration
                    )
                }
            } catch {
                return failure(
                    .signatureFailure,
                    "App archive Ed25519 signature is invalid.",
                    generation: checkGeneration
                )
            }
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
                    supportPolicyStatus: supportPolicyStatus,
                    clientID: lifecycle.clientID,
                    generation: checkGeneration
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
                    supportPolicyStatus: supportPolicyStatus,
                    clientID: lifecycle.clientID,
                    generation: checkGeneration
                )
            }
            let descriptorData: Data
            do {
                descriptorData = try await transport.downloadMetadata(
                    from: selected.release,
                    configuration: configuration
                )
            } catch {
                return mappedFailure(
                    error,
                    fallback: .downloadFailure,
                    generation: checkGeneration
                )
            }
            let descriptor: ReleaseDescriptor
            do {
                descriptor = try ReleaseDescriptor(jsonData: descriptorData)
            } catch {
                return mappedFailure(
                    error,
                    fallback: .invalidDescriptor,
                    generation: checkGeneration
                )
            }
            guard descriptor.packageId == configuration.expectedPackageId else {
                return failure(
                    .packageIdentityMismatch,
                    "Descriptor package identity does not match.",
                    selectedItem: selected,
                    generation: checkGeneration
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
                    selectedItem: selected,
                    generation: checkGeneration
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
                        selectedItem: selected,
                        generation: checkGeneration
                    )
                }
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
                    descriptor: descriptor,
                    generation: checkGeneration
                )
            }
            if selected.freshInstall != nil {
                record(.policy, .warning, "Selected release requires a fresh install.")
                return RuntimeUpdateCheck(
                    outcome: .freshInstallRequired,
                    selectedItem: selected,
                    descriptor: descriptor,
                    supportPolicyStatus: supportPolicyStatus,
                    clientID: lifecycle.clientID,
                    generation: checkGeneration
                )
            }
            guard supportedArtifactKinds().contains(descriptor.artifact.kind) else {
                return failure(
                    .unsupportedArtifactKind,
                    "Artifact kind is not supported on this platform.",
                    selectedItem: selected,
                    descriptor: descriptor,
                    generation: checkGeneration
                )
            }
            record(.descriptor, .info, "Verified selected native release descriptor.")
            return RuntimeUpdateCheck(
                outcome: .updateAvailable,
                selectedItem: selected,
                descriptor: descriptor,
                supportPolicyStatus: supportPolicyStatus,
                clientID: lifecycle.clientID,
                generation: checkGeneration
            )
        } catch {
            return mappedFailure(
                error,
                fallback: .invalidDescriptor,
                generation: checkGeneration
            )
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
        let stageLease: RuntimeStageLease
        switch lifecycle.beginStage(check) {
        case let .success(lease):
            stageLease = lease
        case let .failure(error):
            return .failure(error)
        }
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
        do {
            try FileManager.default.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true
            )
            let downloadStage = try StageProvenance.createOwnedStage(
                parent: downloadDirectory
            )
            defer { try? FileManager.default.removeItem(at: downloadStage) }
            let artifactPath = downloadStage.appendingPathComponent(artifactName)
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
            guard lifecycle.stageIsCurrent(stageLease) else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "Update check became stale while downloading."
                )
            }
            record(.verify, .info, "Artifact length and SHA-256 are verified.")
            let stagedArtifact: RuntimeStagedArtifact
            switch descriptor.artifact.kind {
            case "zip":
                stagedArtifact = try stager.stageZip(
                    archive: artifactPath,
                    stagingRoot: stagingRoot,
                    descriptor: descriptor,
                    expectedPackageId: configuration.expectedPackageId,
                    expectedTeamIdentifier: expectedTeamIdentifier,
                    allowUnsignedUpdates: allowUnsignedUpdates,
                    limits: RuntimeArchiveLimits(configuration: configuration)
                )
            case "dmg":
                stagedArtifact = try stager.stageDMG(
                    dmg: artifactPath,
                    stagingRoot: stagingRoot,
                    descriptor: descriptor,
                    expectedPackageId: configuration.expectedPackageId,
                    expectedTeamIdentifier: expectedTeamIdentifier,
                    allowUnsignedUpdates: allowUnsignedUpdates
                )
            case "pkgInstaller":
                stagedArtifact = try stager.stagePKG(
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
            let retainedArtifactPath: URL
            switch descriptor.artifact.kind {
            case "zip":
                retainedArtifactPath = stagedArtifact.stageRoot
                    .appendingPathComponent(".desktop_updater_artifact.zip")
            case "pkgInstaller":
                retainedArtifactPath = stagedArtifact.stageRoot
                    .appendingPathComponent("installer.pkg")
            default:
                retainedArtifactPath = stagedArtifact.stagedPath
            }
            record(.stage, .info, "Verified native artifact is staged.")
            let staged = RuntimeStagedUpdate(
                descriptor: descriptor,
                stagedPath: stagedArtifact.stagedPath,
                stageRoot: stagedArtifact.stageRoot,
                stageProvenanceSHA256:
                    stagedArtifact.provenance.markerSHA256,
                provenanceEntries: stagedArtifact.provenance.marker.entries,
                artifactPath: retainedArtifactPath,
                clientID: lifecycle.clientID,
                generation: stageLease.generation
            )
            guard lifecycle.publishStage(staged, lease: stageLease) else {
                throw RuntimeError.outcome(
                    .invalidDescriptor,
                    message: "A newer staging attempt invalidated this update."
                )
            }
            return .success(staged)
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
        allowUnsignedUpdates: Bool = false
    ) throws {
        do {
            _ = try StageProvenance.verify(
                stageRoot: staged.stageRoot,
                expectedMarkerSHA256: staged.stageProvenanceSHA256
            )
        } catch {
            let failure = RuntimeError.outcome(
                .installHandoffFailure,
                message: "Stage provenance validation failed: \(error)"
            )
            record(.install, .error, "macOS helper handoff failed.", failure)
            throw failure
        }
        let handoff: RuntimeInstallHandoff
        switch lifecycle.beginInstall(staged) {
        case let .success(value):
            handoff = value
        case let .failure(error):
            record(.install, .error, "macOS helper handoff failed.", error)
            throw error
        }
        let rollbackGuard = RuntimeSchedulingRollbackGuard(
            state: lifecycle,
            handoff: handoff
        )
        do {
            record(.install, .info, "Handing staged update to the macOS helper.")
            try installScheduler(
                handoff.staged,
                diagnosticsLogPath,
                allowUnsignedUpdates
            )
            guard rollbackGuard.confirm() else {
                throw RuntimeError.outcome(
                    .installHandoffFailure,
                    message: "macOS helper handoff confirmation failed."
                )
            }
        } catch {
            rollbackGuard.rollback()
            let failure = mappedInstallFailure(error)
            record(.install, .error, "macOS helper handoff failed.", failure)
            throw failure
        }
    }

    private func mappedInstallFailure(_ error: Error) -> RuntimeError {
        if let runtimeError = error as? RuntimeError {
            return runtimeError
        }
        if let clientError = error as? MacInstallClientError,
           clientError == .privilegedHelperApprovalRequired
        {
            return .diagnostic(
                .installHandoffFailure,
                RuntimeDiagnostic(
                    code: .privilegedHelperApprovalRequired,
                    message: "Administrator approval is required before the privileged macOS updater helper can run.",
                    remediationActions: [
                        .openMacOSBackgroundItemsSettings
                    ]
                )
            )
        }
        return .outcome(
            .installHandoffFailure,
            message: "macOS helper handoff failed: \(error)"
        )
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
        fallback: RuntimeOutcome,
        generation: UInt64
    ) -> RuntimeUpdateCheck {
        if case let RuntimeError.outcome(outcome, message) = error {
            return failure(outcome, message, generation: generation)
        }
        if case let RuntimeError.diagnostic(outcome, diagnostic) = error {
            return failure(
                outcome,
                diagnostic.message,
                generation: generation
            )
        }
        if case let RuntimeError.invalidConfiguration(message) = error {
            return failure(.invalidDescriptor, message, generation: generation)
        }
        return failure(
            fallback,
            String(describing: error),
            generation: generation
        )
    }

    private func failure(
        _ outcome: RuntimeOutcome,
        _ message: String,
        selectedItem: ReleaseIndexItem? = nil,
        descriptor: ReleaseDescriptor? = nil,
        generation: UInt64
    ) -> RuntimeUpdateCheck {
        record(.check, .error, message)
        return RuntimeUpdateCheck(
            outcome: outcome,
            selectedItem: selectedItem,
            descriptor: descriptor,
            supportPolicyStatus: supportPolicyStatus,
            message: message,
            clientID: lifecycle.clientID,
            generation: generation
        )
    }

    private func record(
        _ stage: RuntimeDiagnosticStage,
        _ level: RuntimeDiagnosticLevel,
        _ message: String,
        _ error: Error? = nil
    ) {
        diagnosticsLock.lock()
        diagnostics.record(
            RuntimeDiagnosticEntry(
                timestamp: RuntimeClientTimestamp.string(),
                stage: stage,
                level: level,
                message: message,
                errorDescription: error.map(String.init(describing:))
            )
        )
        diagnosticsLock.unlock()
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
