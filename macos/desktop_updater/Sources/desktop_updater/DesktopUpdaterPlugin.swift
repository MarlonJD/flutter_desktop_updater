import Cocoa
import FlutterMacOS

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
            if let stagingPath {
                let values: URLResourceValues
                do {
                    values = try URL(fileURLWithPath: stagingPath)
                        .resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                } catch {
                    result(
                        FlutterError(
                            code: "InstallError",
                            message: "Staged macOS update directory does not exist.",
                            details: stagingPath
                        )
                    )
                    return
                }
                if values.isSymbolicLink == true {
                    result(
                        FlutterError(
                            code: "InstallError",
                            message: "Staged macOS update must be a real .app directory, not a symlink.",
                            details: stagingPath
                        )
                    )
                    return
                }
                if values.isDirectory != true {
                    result(
                        FlutterError(
                            code: "InstallError",
                            message: "Staged macOS update directory does not exist.",
                            details: stagingPath
                        )
                    )
                    return
                }
            }

            let scriptURL = try writeHelperScript(
                stagingPath: stagingPath,
                allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
                diagnosticsLogPath: diagnosticsLogPath
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            try process.run()

            result(nil)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            result(
                FlutterError(
                    code: "InstallError",
                    message: "Unable to schedule update installation.",
                    details: error.localizedDescription
                )
            )
        }
    }

    private func writeHelperScript(
        stagingPath: String?,
        allowUnsignedMacOSUpdates: Bool,
        diagnosticsLogPath: String?
    ) throws -> URL {
        let bundlePath = Bundle.main.bundlePath
        let helperName = "desktop_updater_\(UUID().uuidString).sh"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(helperName)
        let allowUnsignedValue = allowUnsignedMacOSUpdates ? "1" : ""
        #if DEBUG
            let smokeGateBypassAssignment = "ALLOW_UNSIGNED_MACOS=\"${DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS:-\(allowUnsignedValue)}\""
        #else
            let smokeGateBypassAssignment = "ALLOW_UNSIGNED_MACOS=\"\(allowUnsignedValue)\""
        #endif

        var script = """
        #!/bin/sh
        set -eu

        PID="\(ProcessInfo.processInfo.processIdentifier)"
        STAGING=\(shellQuote(stagingPath ?? ""))
        BUNDLE=\(shellQuote(bundlePath))
        DIAGNOSTICS_LOG=\(shellQuote(diagnosticsLogPath ?? ""))
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

        """

        script += """
        if [ -n "$STAGING" ]; then
          log_event "staging path validation"
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

          MANIFEST="$(dirname "$STAGING")/.desktop_updater_release_manifest.json"
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
            if /bin/rm -rf "$BACKUP" && /bin/rm -rf "$(dirname "$MANIFEST")"; then
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

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
