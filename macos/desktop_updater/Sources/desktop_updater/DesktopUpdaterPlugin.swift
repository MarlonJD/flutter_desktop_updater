import Cocoa
import FlutterMacOS
#if canImport(DesktopUpdaterKit)
import DesktopUpdaterKit
#endif

public class DesktopUpdaterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
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
            scheduleInstallAndRelaunch(
                stagingPath: nil,
                removedFiles: [],
                diagnosticsLogPath: nil,
                result: result
            )
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
            scheduleInstallAndRelaunch(
                stagingPath: stagingPath,
                removedFiles: removedFiles,
                allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
                diagnosticsLogPath: diagnosticsLogPath,
                result: result
            )
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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func scheduleInstallAndRelaunch(
        stagingPath: String?,
        removedFiles _: [String],
        allowUnsignedMacOSUpdates: Bool = false,
        diagnosticsLogPath: String? = nil,
        result: @escaping FlutterResult
    ) {
        do {
            let request = MacInstallRequest(
                stagingPath: stagingPath,
                allowUnsignedUpdates: allowUnsignedMacOSUpdates,
                diagnosticsLogPath: diagnosticsLogPath,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                bundlePath: Bundle.main.bundlePath
            )
            try MacInstallHelper().scheduleInstallAndRelaunch(request)

            result(nil)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
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

            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(
                at: destinationURL,
                configuration: configuration
            ) { _, error in
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
