import Foundation

struct MacInstallTarget: Sendable {
    let processIdentifier: Int32
    let bundleURL: URL
}

typealias MacInstallTargetResolver = @Sendable () -> MacInstallTarget

#if !SWIFT_PACKAGE
public struct InstallReservationResponseV1: Equatable {
    public let protocolVersion: Int
    public let transactionID: String
    public let readyToken: String
    public let journalSHA256: String
    public let helperEndpointIdentitySHA256: String
    public let expiresAtUnixMilliseconds: Int64

    public init(
        protocolVersion: Int,
        transactionID: String,
        readyToken: String,
        journalSHA256: String,
        helperEndpointIdentitySHA256: String,
        expiresAtUnixMilliseconds: Int64
    ) {
        self.protocolVersion = protocolVersion
        self.transactionID = transactionID
        self.readyToken = readyToken
        self.journalSHA256 = journalSHA256
        self.helperEndpointIdentitySHA256 =
            helperEndpointIdentitySHA256
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
    }
}

private enum HelperProtocolValidation {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character)
        }
    }

    static func isTransactionID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func isReadyToken(_ value: String) -> Bool {
        value.count >= 43 && value.count <= 128 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}

public enum InstallTransactionState: Int {
    case unknown = 0
    case prepared = 1
    case commitAccepted = 2
    case completed = 3
    case cancelled = 4
    case expired = 5
    case rolledBack = 6
    case manualActionRequired = 7
}

public enum InstallTransactionResultCode: Int {
    case none = 0
    case accepted = 1
    case succeeded = 2
    case rejected = 3
    case endpointUnavailable = 4
    case authenticationFailed = 5
    case invalidResponse = 6
    case recoveryRequired = 7
}

public struct InstallTransactionStatus {
    public let transactionID: String
    public let state: InstallTransactionState
    public let resultCode: InstallTransactionResultCode
    public let detail: String
    public let responseDigestSHA256: String
    public let helperEndpointIdentitySHA256: String

    public init(
        transactionID: String,
        state: InstallTransactionState,
        resultCode: InstallTransactionResultCode,
        detail: String,
        responseDigestSHA256: String,
        helperEndpointIdentitySHA256: String
    ) {
        self.transactionID = transactionID
        self.state = state
        self.resultCode = resultCode
        self.detail = detail
        self.responseDigestSHA256 = responseDigestSHA256
        self.helperEndpointIdentitySHA256 = helperEndpointIdentitySHA256
    }
}

public final class MacInstallReservation {
    public let transactionID: String
    public let readyToken: String
    public let responseDigestSHA256: String
    public let helperEndpointIdentitySHA256: String
    public let expiresAtUnixMilliseconds: Int64

    private let lock = NSLock()
    private var active = true
    private let abandon: () -> Void

    init(
        response: InstallReservationResponseV1,
        abandon: @escaping () -> Void
    ) {
        transactionID = response.transactionID
        readyToken = response.readyToken
        responseDigestSHA256 = response.journalSHA256
        helperEndpointIdentitySHA256 =
            response.helperEndpointIdentitySHA256
        expiresAtUnixMilliseconds = response.expiresAtUnixMilliseconds
        self.abandon = abandon
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func release() {
        lock.lock()
        active = false
        lock.unlock()
    }

    deinit {
        lock.lock()
        let shouldAbandon = active
        active = false
        lock.unlock()
        if shouldAbandon {
            abandon()
        }
    }
}
#endif

public enum MacInstallClientError: Error, Equatable {
    case endpointUnavailable
    case invalidTransactionID
    case invalidReservationResponse
    case inactiveReservation
}

protocol MacInstallHelperTransport: AnyObject {
    func prepareInstall(
        request: Data,
        transactionID: String
    ) throws -> InstallReservationResponseV1

    func commitAfterExit(
        transactionID: String,
        readyToken: String
    ) throws -> InstallTransactionStatus

    func cancelReservation(
        transactionID: String,
        readyToken: String
    ) throws -> InstallTransactionStatus

    func queryTransaction(
        transactionID: String
    ) throws -> InstallTransactionStatus

    func recoverPendingInstall(
        transactionID: String
    ) throws -> InstallTransactionStatus
}

private final class PackagedMacInstallHelperTransport:
    MacInstallHelperTransport
{
    func prepareInstall(
        request _: Data,
        transactionID _: String
    ) throws -> InstallReservationResponseV1 {
        throw MacInstallClientError.endpointUnavailable
    }

    func commitAfterExit(
        transactionID _: String,
        readyToken _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }

    func cancelReservation(
        transactionID _: String,
        readyToken _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }

    func queryTransaction(
        transactionID _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }

    func recoverPendingInstall(
        transactionID _: String
    ) throws -> InstallTransactionStatus {
        throw MacInstallClientError.endpointUnavailable
    }
}

public struct MacInstallHelper {
    private let targetResolver: MacInstallTargetResolver
    private let transport: MacInstallHelperTransport

    public init() {
        targetResolver = {
            MacInstallTarget(
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                bundleURL: Bundle.main.bundleURL
            )
        }
        transport = PackagedMacInstallHelperTransport()
    }

    init(targetResolver: @escaping MacInstallTargetResolver) {
        self.targetResolver = targetResolver
        transport = PackagedMacInstallHelperTransport()
    }

    init(
        targetResolver: @escaping MacInstallTargetResolver,
        transport: MacInstallHelperTransport
    ) {
        self.targetResolver = targetResolver
        self.transport = transport
    }

    public func scheduleInstallAndRelaunch(_ request: MacInstallRequest) throws {
        let reservation = try prepareInstall(request)
        _ = try commitAfterExit(reservation)
    }

    public func prepareInstall(
        _ request: MacInstallRequest
    ) throws -> MacInstallReservation {
        try validateCompleteHandoff(request)
        let target = targetResolver()
        let transactionID = UUID().uuidString.lowercased()
        let requestData = try request.helperRequestData(
            transactionID: transactionID,
            processIdentifier: target.processIdentifier,
            bundleURL: target.bundleURL
        )
        let response = try transport.prepareInstall(
            request: requestData,
            transactionID: transactionID
        )
        guard response.protocolVersion == 1,
              response.transactionID == transactionID,
              HelperProtocolValidation.isReadyToken(response.readyToken),
              HelperProtocolValidation.isSHA256(response.journalSHA256),
              HelperProtocolValidation.isSHA256(
                  response.helperEndpointIdentitySHA256
              ),
              response.expiresAtUnixMilliseconds > 0 else {
            throw MacInstallClientError.invalidReservationResponse
        }
        let cancellationTransport = transport
        return MacInstallReservation(response: response) {
            _ = try? cancellationTransport.cancelReservation(
                transactionID: response.transactionID,
                readyToken: response.readyToken
            )
        }
    }

    public func commitAfterExit(
        _ reservation: MacInstallReservation
    ) throws -> InstallTransactionStatus {
        guard reservation.isActive else {
            throw MacInstallClientError.inactiveReservation
        }
        let status = try transport.commitAfterExit(
            transactionID: reservation.transactionID,
            readyToken: reservation.readyToken
        )
        try validate(
            status,
            transactionID: reservation.transactionID,
            reservation: reservation
        )
        guard status.state == .commitAccepted ||
            status.state == .completed else {
            throw MacInstallClientError.invalidReservationResponse
        }
        reservation.release()
        return status
    }

    public func cancelReservation(
        _ reservation: MacInstallReservation
    ) throws -> InstallTransactionStatus {
        guard reservation.isActive else {
            throw MacInstallClientError.inactiveReservation
        }
        let status = try transport.cancelReservation(
            transactionID: reservation.transactionID,
            readyToken: reservation.readyToken
        )
        try validate(
            status,
            transactionID: reservation.transactionID,
            reservation: reservation
        )
        guard status.state == .cancelled else {
            throw MacInstallClientError.invalidReservationResponse
        }
        reservation.release()
        return status
    }

    public func queryTransaction(
        _ transactionID: String
    ) throws -> InstallTransactionStatus {
        try validateTransactionID(transactionID)
        let status = try transport.queryTransaction(
            transactionID: transactionID
        )
        try validate(status, transactionID: transactionID)
        return status
    }

    public func recoverPendingInstall(
        _ transactionID: String
    ) throws -> InstallTransactionStatus {
        try validateTransactionID(transactionID)
        let status = try transport.recoverPendingInstall(
            transactionID: transactionID
        )
        try validate(status, transactionID: transactionID)
        return status
    }

    private func validateTransactionID(_ value: String) throws {
        guard HelperProtocolValidation.isTransactionID(value) else {
            throw MacInstallClientError.invalidTransactionID
        }
    }

    private func validate(
        _ status: InstallTransactionStatus,
        transactionID: String,
        reservation: MacInstallReservation? = nil
    ) throws {
        guard status.transactionID == transactionID,
              HelperProtocolValidation.isSHA256(
                  status.responseDigestSHA256
              ),
              HelperProtocolValidation.isSHA256(
                  status.helperEndpointIdentitySHA256
              ),
              reservation?.responseDigestSHA256
                  == status.responseDigestSHA256 || reservation == nil,
              reservation?.helperEndpointIdentitySHA256
                  == status.helperEndpointIdentitySHA256 || reservation == nil
        else {
            throw MacInstallClientError.invalidReservationResponse
        }
    }

    func validateCompleteHandoff(_ request: MacInstallRequest) throws {
        guard let stagingPath = request.stagingPath else { return }
        guard let root = request.stageRoot,
              !root.isEmpty,
              let expectedProvenance = request.expectedProvenanceSHA256,
              expectedProvenance.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              let artifactKind = request.artifactKind,
              !artifactKind.isEmpty,
              let expectedArtifact = request.expectedArtifactSHA256,
              expectedArtifact.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil
        else {
            throw MacInstallHelperError(
                message: "Verified stage provenance is required before scheduling.",
                path: stagingPath
            )
        }
        try validateStagingPath(stagingPath)

        let stageRoot = URL(fileURLWithPath: root).standardizedFileURL
        let staged = URL(fileURLWithPath: stagingPath).standardizedFileURL
        guard staged == stageRoot ||
            staged.deletingLastPathComponent() == stageRoot
        else {
            throw MacInstallHelperError(
                message: "Staged update is not owned by its verified stage root.",
                path: stagingPath
            )
        }
        let marker = try StageProvenance.verify(
            stageRoot: stageRoot,
            expectedMarkerSHA256: expectedProvenance
        )
        guard marker.artifactSha256 == expectedArtifact,
              marker.entries == request.provenanceEntries
        else {
            throw MacInstallHelperError(
                message: "Verified stage provenance does not match the helper request.",
                path: stagingPath
            )
        }
    }

    func validateStagingPath(_ stagingPath: String?) throws {
        guard let stagingPath else {
            return
        }
        let values: URLResourceValues
        do {
            values = try URL(fileURLWithPath: stagingPath)
                .resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        } catch {
            throw MacInstallHelperError(
                message: "Staged macOS update directory does not exist.",
                path: stagingPath
            )
        }
        if values.isSymbolicLink == true {
            throw MacInstallHelperError(
                message: "Staged macOS update must be a real .app directory, not a symlink.",
                path: stagingPath
            )
        }
        if values.isDirectory != true {
            throw MacInstallHelperError(
                message: "Staged macOS update directory does not exist.",
                path: stagingPath
            )
        }
    }

    func writeHelperScript(
        for request: MacInstallRequest,
        nonce: UUID = UUID()
    ) throws -> URL {
        let helperName = "desktop_updater_\(nonce.uuidString).command"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(helperName)
        let script = makeHelperScript(for: request)
        var created = false
        do {
            try Data(script.utf8).write(
                to: scriptURL,
                options: .withoutOverwriting
            )
            created = true
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            if created {
                try? FileManager.default.removeItem(at: scriptURL)
            }
            throw error
        }
        return scriptURL
    }

    func makeHelperScript(for request: MacInstallRequest) -> String {
        let installTarget = targetResolver()
        let allowUnsignedValue = request.allowUnsignedUpdates ? "1" : ""
        #if DEBUG
            let smokeGateBypassAssignment = "ALLOW_UNSIGNED_MACOS=\"${DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS:-\(allowUnsignedValue)}\""
        #else
            let smokeGateBypassAssignment = "ALLOW_UNSIGNED_MACOS=\"\(allowUnsignedValue)\""
        #endif
        let stageRoot = request.stageRoot ?? {
            guard let staging = request.stagingPath else { return "" }
            let url = URL(fileURLWithPath: staging)
            return url.pathExtension.lowercased() == "app"
                ? url.deletingLastPathComponent().path
                : url.path
        }()
        let provenanceChecks = inventoryValidationCommands(
            request.provenanceEntries
        )
        let expectedPackageIDs = shellArray(request.expectedPackageIDs)
        let stageNonce = URL(fileURLWithPath: stageRoot)
            .lastPathComponent
            .replacingOccurrences(of: updaterOwnedStagePrefix, with: "")

        return """
        #!/bin/sh
        set -eu

        PID="\(installTarget.processIdentifier)"
        STAGING=\(shellQuote(request.stagingPath ?? ""))
        STAGE_ROOT=\(shellQuote(stageRoot))
        STAGE_NONCE=\(shellQuote(stageNonce))
        expected_provenance_sha256=\(shellQuote(request.expectedProvenanceSHA256 ?? ""))
        ARTIFACT_KIND=\(shellQuote(request.artifactKind ?? ""))
        PKG_LAUNCH_MODE='installerApp' # verified descriptor launchMode
        EXPECTED_ARTIFACT_SHA256=\(shellQuote(request.expectedArtifactSHA256 ?? ""))
        EXPECTED_PACKAGE_IDS=\(expectedPackageIDs)
        EXPECTED_PROVENANCE_ENTRY_COUNT='\(request.provenanceEntries.count)'
        BUNDLE=\(shellQuote(installTarget.bundleURL.path))
        DIAGNOSTICS_LOG=\(shellQuote(request.diagnosticsLogPath ?? ""))
        SKIP_RELAUNCH="${DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH:-}"
        \(smokeGateBypassAssignment)

        log_event() {
          [ -n "$DIAGNOSTICS_LOG" ] || return 0
          printf '{"timestamp":"%s","event":"%s"}\\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$DIAGNOSTICS_LOG" 2>/dev/null || true
        }

        log_event "helper scheduled"
        log_event "waiting for parent process"
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.5
        done
        log_event "parent process exited"

        verify_stage_provenance() {
          log_event "stage provenance validation"
          MARKER="$STAGE_ROOT/\(stageProvenanceFileName)"
          if [ -z "$expected_provenance_sha256" ] || [ ! -f "$MARKER" ] || [ -L "$MARKER" ]; then
            log_event "stage provenance validation failure"
            return 1
          fi
          ACTUAL_PROVENANCE_SHA256="$(/usr/bin/shasum -a 256 "$MARKER" | /usr/bin/awk '{print $1}')"
          if [ "$ACTUAL_PROVENANCE_SHA256" != "$expected_provenance_sha256" ]; then
            log_event "stage provenance validation failure"
            return 1
          fi
        \(provenanceChecks)
          ACTUAL_PROVENANCE_ENTRY_COUNT="$(/usr/bin/find "$STAGE_ROOT" -mindepth 1 ! -path "$MARKER" -exec /usr/bin/printf x \\; | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
          if [ "$ACTUAL_PROVENANCE_ENTRY_COUNT" != "$EXPECTED_PROVENANCE_ENTRY_COUNT" ]; then
            log_event "stage provenance validation failure"
            return 1
          fi
          log_event "stage provenance validation success"
        }

        cleanup_owned_stage() {
          OWNED_STAGE="$1"
          OWNED_NAME="$(/usr/bin/basename "$OWNED_STAGE")"
          case "$OWNED_NAME" in
            "\(updaterOwnedStagePrefix)$STAGE_NONCE") ;;
            *) return 1 ;;
          esac
          [ -n "$STAGE_NONCE" ] || return 1
          [ -f "$OWNED_STAGE/\(stageProvenanceFileName)" ] || return 1
          /usr/bin/grep -q "\\\"nonce\\\":\\\"$STAGE_NONCE\\\"" "$OWNED_STAGE/\(stageProvenanceFileName)" || return 1
          /bin/rm -rf "$OWNED_STAGE"
        }

        if [ -n "$STAGING" ]; then
          log_event "staging path validation"
          if ! verify_stage_provenance; then
            echo "Staged update provenance validation failed." >&2
            exit 1
          fi
          MANIFEST="$STAGE_ROOT/.desktop_updater_release_manifest.json"
          if [ "$ARTIFACT_KIND" = "pkgInstaller" ] && [ "$PKG_LAUNCH_MODE" = "installerApp" ]; then
            log_event "pkg manifest loaded"
            PKG="$STAGING/installer.pkg"
            if [ ! -f "$PKG" ]; then
              echo "Staged macOS PKG installer is missing." >&2
              exit 1
            fi
            ACTUAL_ARTIFACT_SHA256="$(/usr/bin/shasum -a 256 "$PKG" | /usr/bin/awk '{print $1}')"
            if [ -z "$EXPECTED_ARTIFACT_SHA256" ] || [ "$ACTUAL_ARTIFACT_SHA256" != "$EXPECTED_ARTIFACT_SHA256" ]; then
              log_event "stage provenance validation failure"
              exit 1
            fi
            /usr/sbin/pkgutil --check-signature "$PKG"
            /usr/sbin/spctl --assess --type install "$PKG"
            /usr/bin/xcrun stapler validate "$PKG"
            PKG_WORK="$(/usr/bin/mktemp -d -t desktop_updater_pkg)"
            EXPANDED_PKG="$PKG_WORK/expanded"
            /usr/sbin/pkgutil --expand-full "$PKG" "$EXPANDED_PKG"
            /usr/bin/printf '%s\n' "$EXPECTED_PACKAGE_IDS" | while IFS= read -r EXPECTED_PACKAGE_ID; do
              [ -n "$EXPECTED_PACKAGE_ID" ] || continue
              if ! /usr/bin/grep -R -q "identifier=\\\"$EXPECTED_PACKAGE_ID\\\"" "$EXPANDED_PKG"; then
                /bin/rm -rf "$PKG_WORK"
                echo "Staged macOS PKG package identity mismatch." >&2
                exit 1
              fi
            done
            /bin/rm -rf "$PKG_WORK"
            log_event "pkg installer open"
            if /usr/bin/open "$PKG"; then
              log_event "pkg installer opened"
              rm -f "$0"
              exit 0
            fi
            log_event "pkg installer open failure"
            exit 1
          fi

          case "$STAGING" in
            *.app) ;;
            *)
              echo "Staged macOS update must be a complete .app bundle." >&2
              exit 1
              ;;
          esac
          if [ -L "$STAGING" ]; then
            echo "Staged macOS update must be a real .app directory, not a symlink." >&2
            exit 1
          fi
          if [ ! -d "$STAGING" ]; then
            echo "Staged macOS update directory does not exist." >&2
            exit 1
          fi

          MANIFEST="$STAGE_ROOT/.desktop_updater_release_manifest.json"
          if [ ! -f "$MANIFEST" ]; then
            echo "Staged update manifest is missing." >&2
            exit 1
          fi

          EXPECTED_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$BUNDLE/Contents/Info.plist")"
          ACTUAL_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$STAGING/Contents/Info.plist")"
          if [ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
            echo "CFBundleIdentifier mismatch: expected $EXPECTED_BUNDLE_ID, got $ACTUAL_BUNDLE_ID" >&2
            exit 1
          fi

          if [ "$ALLOW_UNSIGNED_MACOS" != "1" ]; then
            log_event "package identity checks"
            EXPECTED_TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$BUNDLE" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
            if [ -z "$EXPECTED_TEAM_ID" ]; then
              echo "Installed app TeamIdentifier could not be read." >&2
              exit 1
            fi

            /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING"
            /usr/sbin/spctl --assess --type execute --verbose=2 "$STAGING"
            /usr/bin/xcrun stapler validate "$STAGING"

            ACTUAL_TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$STAGING" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
            if [ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
              echo "TeamIdentifier mismatch: expected $EXPECTED_TEAM_ID, got $ACTUAL_TEAM_ID" >&2
              exit 1
            fi
          else
            echo "Skipping macOS signing gates because allowUnsignedMacOSUpdates or the debug smoke bypass is enabled." >&2
          fi

          TARGET_PARENT="$(dirname "$BUNDLE")"
          TARGET_NAME="$(basename "$BUNDLE")"
          BACKUP="$TARGET_PARENT/.$TARGET_NAME.desktop_updater_backup.$$"

          log_event "backup start"
          if /bin/mv "$BUNDLE" "$BACKUP"; then
            log_event "backup success"
          else
            log_event "backup failure"
            exit 1
          fi
          log_event "move start"
          if /bin/mv "$STAGING" "$BUNDLE"; then
            log_event "move success"
            log_event "cleanup start"
            if /bin/rm -rf "$BACKUP" && cleanup_owned_stage "$STAGE_ROOT"; then
              log_event "cleanup success"
            else
              log_event "cleanup failure"
            fi
          else
            log_event "move failure"
            log_event "rollback start"
            if /bin/rm -rf "$BUNDLE" && /bin/mv "$BACKUP" "$BUNDLE"; then
              log_event "rollback success"
            else
              log_event "rollback failure"
            fi
            exit 1
          fi
        fi

        if [ "$SKIP_RELAUNCH" != "1" ]; then
          log_event "relaunch attempt"
          open -n "$BUNDLE"
        fi
        rm -f "$0"
        """
    }

    private func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellArray(_ values: [String]) -> String {
        shellQuote(values.joined(separator: "\n"))
    }

    private func inventoryValidationCommands(
        _ entries: [StageProvenanceEntry]
    ) -> String {
        entries.map { entry in
            let candidate = "  candidate=\"$STAGE_ROOT/\"" +
                shellQuote(entry.path) + "\n"
            switch entry.kind {
            case "directory":
                return candidate + "  [ -d \"$candidate\" ] && [ ! -L \"$candidate\" ] || { log_event \"stage provenance validation failure\"; return 1; }"
            case "symlink":
                return candidate + "  [ -L \"$candidate\" ] && [ \"$(/usr/bin/readlink \"$candidate\")\" = \(shellQuote(entry.target ?? "")) ] || { log_event \"stage provenance validation failure\"; return 1; }"
            default:
                return candidate + "  [ -f \"$candidate\" ] && [ ! -L \"$candidate\" ] && [ \"$(/usr/bin/stat -f %z \"$candidate\")\" = \(entry.length) ] && [ \"$(/usr/bin/shasum -a 256 \"$candidate\" | /usr/bin/awk '{print $1}')\" = \(shellQuote(entry.sha256 ?? "")) ] || { log_event \"stage provenance validation failure\"; return 1; }"
            }
        }.joined(separator: "\n")
    }
}

struct MacInstallHelperError: LocalizedError {
    let message: String
    let path: String

    var errorDescription: String? {
        return message
    }
}
