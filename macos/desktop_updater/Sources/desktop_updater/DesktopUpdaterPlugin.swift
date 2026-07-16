import Cocoa
import Darwin
import FlutterMacOS
import ServiceManagement
#if canImport(DesktopUpdaterKit)
import DesktopUpdaterKit
#endif

public class DesktopUpdaterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        guard MacApplicationRestarter
            .awaitRestartParentExitIfRequested() else {
            _exit(78)
        }
        let channel = FlutterMethodChannel(
            name: "desktop_updater",
            binaryMessenger: registrar.messenger
        )
        let instance = DesktopUpdaterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        case "restartApp":
            restartCurrentApplication(result: result)
        case "installUpdate":
            guard
                let arguments = call.arguments as? [String: Any],
                let stagingPath = arguments["stagingPath"] as? String,
                !stagingPath.isEmpty
            else {
                result(
                    FlutterError(
                        code: "InvalidArguments",
                        message: "installUpdate requires a stagingPath.",
                        details: nil
                    )
                )
                return
            }

            let removedFiles = arguments["removedFiles"] as? [String] ?? []
            let allowUnsignedMacOSUpdates =
                arguments["allowUnsignedMacOSUpdates"] as? Bool ?? false
            let diagnosticsLogPath = arguments["diagnosticsLogPath"] as? String
            let stageProvenanceSHA256 =
                arguments["stageProvenanceSha256"] as? String
            let transactionID: String?
            if let value = arguments["transactionId"] {
                guard let candidate = value as? String,
                      isCanonicalTransactionID(candidate) else {
                    result(
                        FlutterError(
                            code: "InvalidArguments",
                            message: "transactionId must be a canonical lowercase UUIDv4.",
                            details: nil
                        )
                    )
                    return
                }
                transactionID = candidate
            } else {
                transactionID = nil
            }
            handoffInstallAndRelaunch(
                stagingPath: stagingPath,
                removedFiles: removedFiles,
                allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
                diagnosticsLogPath: diagnosticsLogPath,
                stageProvenanceSHA256: stageProvenanceSHA256,
                transactionID: transactionID,
                result: result
            )
        case "queryInstallTransaction":
            queryInstallTransaction(call.arguments, result: result)
        case "recoverPendingInstallTransaction":
            recoverPendingInstallTransaction(call.arguments, result: result)
        case "getExecutablePath":
            result(Bundle.main.executablePath)
        case "getCurrentVersion":
            result(Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
        case "getCurrentVersionInfo":
            result([
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            ])
        case "checkMacOSInstallLocation":
            result(macOSInstallLocationStatus())
        case "moveMacOSAppToApplications":
            let arguments = call.arguments as? [String: Any]
            let replaceExisting = arguments?["replaceExisting"] as? Bool ?? false
            moveMacOSAppToApplications(
                replaceExisting: replaceExisting,
                result: result
            )
        case "openMacOSBackgroundItemsSettings":
            guard #available(macOS 13.0, *) else {
                result(
                    FlutterError(
                        code: "Unsupported",
                        message: "Background item settings require macOS 13 or later.",
                        details: nil
                    )
                )
                return
            }
            SMAppService.openSystemSettingsLoginItems()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func restartCurrentApplication(result: @escaping FlutterResult) {
        do {
            try MacApplicationRestarter()
                .scheduleCurrentApplicationRestart()
            result(nil)
            exit(EXIT_SUCCESS)
        } catch {
            result(
                FlutterError(
                    code: "RestartError",
                    message: "Unable to schedule application restart.",
                    details: error.localizedDescription
                )
            )
        }
    }

    private func handoffInstallAndRelaunch(
        stagingPath: String?,
        removedFiles _: [String],
        allowUnsignedMacOSUpdates: Bool = false,
        diagnosticsLogPath: String? = nil,
        stageProvenanceSHA256: String? = nil,
        transactionID: String? = nil,
        result: @escaping FlutterResult
    ) {
        do {
            var stageRoot: URL?
            var provenance: StageProvenanceState?
            var artifactKind: String?
            var expectedPackageIDs: [String] = []
            if let stagingPath {
                guard let expectedProvenanceSHA256 = stageProvenanceSHA256,
                      !expectedProvenanceSHA256.isEmpty
                else {
                    throw NSError(
                        domain: "desktop_updater.stage_provenance",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Verified stage provenance SHA-256 is required."]
                    )
                }
                let stagedURL = URL(fileURLWithPath: stagingPath)
                let root = stagedURL.pathExtension.lowercased() == "app"
                    ? stagedURL.deletingLastPathComponent()
                    : stagedURL
                let state = try StageProvenance.read(stageRoot: root)
                _ = try StageProvenance.verify(
                    stageRoot: root,
                    expectedMarkerSHA256: expectedProvenanceSHA256
                )
                let manifestURL = root.appendingPathComponent(
                    ".desktop_updater_release_manifest.json"
                )
                let manifest = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: manifestURL)
                ) as? [String: Any]
                artifactKind = (manifest?["artifact"] as? [String: Any])?["kind"]
                    as? String
                expectedPackageIDs = ((manifest?["install"]
                    as? [String: Any])?["macosPkg"] as? [String: Any])?[
                        "expectedPackageIds"
                    ] as? [String] ?? []
                stageRoot = root
                provenance = state
            }
            let request = MacInstallRequest(
                stagingPath: stagingPath,
                allowUnsignedUpdates: allowUnsignedMacOSUpdates,
                diagnosticsLogPath: diagnosticsLogPath,
                stageRoot: stageRoot?.path,
                expectedProvenanceSHA256: stageProvenanceSHA256,
                artifactKind: artifactKind,
                expectedArtifactSHA256: provenance?.marker.artifactSha256,
                expectedPackageIDs: expectedPackageIDs,
                provenanceEntries: provenance?.marker.entries ?? []
            )
            let helper = MacInstallHelper()
            let reservation: MacInstallReservation
            if let transactionID {
                reservation = try helper.prepareInstall(
                    request,
                    transactionID: transactionID
                )
            } else {
                reservation = try helper.prepareInstall(request)
            }
            let status = try helper.commitAfterExit(reservation)
            guard status.state == .commitAccepted || status.state == .completed,
                  status.resultCode == .accepted || status.resultCode == .succeeded,
                  status.responseDigestSHA256 == reservation.responseDigestSHA256,
                  status.helperEndpointIdentitySHA256 ==
                    reservation.helperEndpointIdentitySHA256
            else {
                throw MacInstallClientError.invalidReservationResponse
            }

            result(nil)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            if error as? MacInstallClientError ==
                .privilegedHelperApprovalRequired
            {
                result(
                    FlutterError(
                        code: "PrivilegedHelperApprovalRequired",
                        message: "Administrator approval is required before installing this update.",
                        details: [
                            "action": "openMacOSBackgroundItemsSettings",
                            "settingsPath": "System Settings > General > Login Items & Extensions",
                        ]
                    )
                )
                return
            }
            if (error as? MacInstallClientError) ==
                MacInstallClientError.installRecoveryRequired
            {
                result(
                    FlutterError(
                        code: "InstallError",
                        message: "Unable to confirm update installation handoff.",
                        details: [
                            "recoveryRequired": true,
                            "transactionId": transactionID ?? "",
                            "detail": error.localizedDescription,
                        ]
                    )
                )
                return
            }
            let validationMessages = [
                "Staged macOS update directory does not exist.",
                "Staged macOS update must be a real .app directory, not a symlink.",
            ]
            let message = validationMessages.contains(error.localizedDescription)
                ? error.localizedDescription
                : "Unable to schedule update installation."
            result(
                FlutterError(
                    code: "InstallError",
                    message: message,
                    details: validationMessages.contains(error.localizedDescription)
                        ? stagingPath
                        : error.localizedDescription
                )
            )
        }
    }

    private func queryInstallTransaction(
        _ arguments: Any?,
        result: @escaping FlutterResult
    ) {
        withTransactionID(arguments, result: result) { transactionID in
            try MacInstallHelper().queryTransaction(transactionID)
        }
    }

    private func recoverPendingInstallTransaction(
        _ arguments: Any?,
        result: @escaping FlutterResult
    ) {
        withTransactionID(arguments, result: result) { transactionID in
            try MacInstallHelper().recoverPendingInstall(transactionID)
        }
    }

    private func withTransactionID(
        _ arguments: Any?,
        result: @escaping FlutterResult,
        operation: (String) throws -> InstallTransactionStatus
    ) {
        guard let values = arguments as? [String: Any],
              let transactionID = values["transactionId"] as? String,
              !transactionID.isEmpty
        else {
            result(
                FlutterError(
                    code: "InvalidArguments",
                    message: "transactionId must be a string.",
                    details: nil
                )
            )
            return
        }
        do {
            result(transactionStatusMap(try operation(transactionID)))
        } catch {
            result(
                FlutterError(
                    code: "InstallError",
                    message: "Unable to query native install status.",
                    details: String(describing: error)
                )
            )
        }
    }

    private func isCanonicalTransactionID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private func transactionStatusMap(
        _ status: InstallTransactionStatus
    ) -> [String: Any] {
        return [
            "transactionId": status.transactionID,
            "state": transactionStateName(status.state),
            "resultCode": transactionResultName(status.resultCode),
            "detail": status.detail,
            "responseDigestSha256": status.responseDigestSHA256,
            "helperEndpointIdentitySha256":
                status.helperEndpointIdentitySHA256,
        ]
    }

    private func transactionStateName(
        _ state: InstallTransactionState
    ) -> String {
        switch state {
        case .unknown: return "unknown"
        case .prepared: return "prepared"
        case .commitAccepted: return "commitAccepted"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .expired: return "expired"
        case .rolledBack: return "rolledBack"
        case .manualActionRequired: return "manualActionRequired"
        }
    }

    private func transactionResultName(
        _ code: InstallTransactionResultCode
    ) -> String {
        switch code {
        case .none: return "none"
        case .accepted: return "accepted"
        case .succeeded: return "succeeded"
        case .rejected: return "rejected"
        case .endpointUnavailable: return "endpointUnavailable"
        case .authenticationFailed: return "authenticationFailed"
        case .invalidResponse: return "invalidResponse"
        case .recoveryRequired: return "recoveryRequired"
        }
    }

    private func macOSInstallLocationStatus() -> [String: Any] {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let targetURL = applicationsTargetURL(for: bundleURL)
        return [
            "kind": classifyInstallLocation(bundleURL),
            "bundlePath": bundleURL.path,
            "targetPath": targetURL.path,
        ]
    }

    private func classifyInstallLocation(_ bundleURL: URL) -> String {
        let bundlePath = bundleURL.standardizedFileURL.path
        if isPath(bundlePath, under: "/Applications") ||
            isPath(bundlePath, under: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
                .path) {
            return "installed"
        }
        if isPath(bundlePath, under: "/Volumes") {
            return "diskImage"
        }
        if let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first?.path, isPath(bundlePath, under: downloads) {
            return "downloads"
        }
        return "other"
    }

    private func moveMacOSAppToApplications(
        replaceExisting: Bool,
        result: @escaping FlutterResult
    ) {
        let sourceURL = Bundle.main.bundleURL.standardizedFileURL
        let destinationURL = applicationsTargetURL(for: sourceURL)
        let fileManager = FileManager.default

        do {
            if sourceURL.path == destinationURL.path {
                result(nil)
                return
            }

            let stagingURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).desktop_updater_move_staging_\(UUID().uuidString)")
            let backupURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).desktop_updater_move_backup_\(UUID().uuidString)")

            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                if !replaceExisting {
                    try? fileManager.removeItem(at: stagingURL)
                    result(
                        FlutterError(
                            code: "AlreadyExists",
                            message: "An app already exists at the Applications target.",
                            details: destinationURL.path
                        )
                    )
                    return
                }
                try fileManager.moveItem(at: destinationURL, to: backupURL)
            }

            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            } catch {
                restoreMoveBackup(
                    fileManager: fileManager,
                    backupURL: backupURL,
                    destinationURL: destinationURL
                )
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }

            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }

            if #available(macOS 10.15, *) {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(
                    at: destinationURL,
                    configuration: configuration
                ) { _, error in
                    self.completeCopiedAppLaunch(error: error, result: result)
                }
            } else {
                let launched = NSWorkspace.shared.launchApplication(
                    destinationURL.path
                )
                DispatchQueue.main.async {
                    if !launched {
                        result(
                            FlutterError(
                                code: "LaunchFailed",
                                message: "Unable to launch the copied app.",
                                details: destinationURL.path
                            )
                        )
                        return
                    }
                    result(nil)
                    NSApplication.shared.terminate(nil)
                }
            }
        } catch {
            result(
                FlutterError(
                    code: "MoveFailed",
                    message: "Unable to move the app to Applications.",
                    details: error.localizedDescription
                )
            )
        }
    }

    private func completeCopiedAppLaunch(
        error: Error?,
        result: @escaping FlutterResult
    ) {
        DispatchQueue.main.async {
            if let error {
                result(
                    FlutterError(
                        code: "LaunchFailed",
                        message: "Unable to launch the copied app.",
                        details: error.localizedDescription
                    )
                )
                return
            }
            result(nil)
            NSApplication.shared.terminate(nil)
        }
    }

    private func restoreMoveBackup(
        fileManager: FileManager,
        backupURL: URL,
        destinationURL: URL
    ) {
        if fileManager.fileExists(atPath: backupURL.path) &&
            !fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.moveItem(at: backupURL, to: destinationURL)
        }
    }

    private func applicationsTargetURL(for sourceURL: URL) -> URL {
        return URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(sourceURL.lastPathComponent)
    }

    private func isPath(_ path: String, under root: String) -> Bool {
        let normalizedRoot = URL(fileURLWithPath: root)
            .standardizedFileURL
            .path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootPath = "/" + normalizedRoot
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
