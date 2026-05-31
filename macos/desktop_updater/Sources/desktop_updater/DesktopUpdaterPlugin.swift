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
            scheduleInstallAndRelaunch(stagingPath: nil, removedFiles: [], result: result)
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
            scheduleInstallAndRelaunch(
                stagingPath: stagingPath,
                removedFiles: removedFiles,
                result: result
            )
        case "getExecutablePath":
            result(Bundle.main.executablePath)
        case "getCurrentVersion":
            result(Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func scheduleInstallAndRelaunch(
        stagingPath: String?,
        removedFiles _: [String],
        result: @escaping FlutterResult
    ) {
        do {
            if let stagingPath, !FileManager.default.fileExists(atPath: stagingPath) {
                result(
                    FlutterError(
                        code: "InstallError",
                        message: "Staged update directory does not exist.",
                        details: stagingPath
                    )
                )
                return
            }

            let scriptURL = try writeHelperScript(stagingPath: stagingPath)

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

    private func writeHelperScript(stagingPath: String?) throws -> URL {
        let bundlePath = Bundle.main.bundlePath
        let helperName = "desktop_updater_\(UUID().uuidString).sh"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(helperName)

        var script = """
        #!/bin/sh
        set -eu

        PID="\(ProcessInfo.processInfo.processIdentifier)"
        STAGING=\(shellQuote(stagingPath ?? ""))
        BUNDLE=\(shellQuote(bundlePath))
        SKIP_RELAUNCH="${DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH:-}"

        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.5
        done

        """

        script += """
        if [ -n "$STAGING" ]; then
          case "$STAGING" in
            *.app) ;;
            *)
              echo "Staged macOS update must be a complete .app bundle." >&2
              exit 1
              ;;
          esac

          MANIFEST="$(dirname "$STAGING")/.desktop_updater_release_manifest.json"
          if [ ! -f "$MANIFEST" ]; then
            echo "Staged update manifest is missing." >&2
            exit 1
          fi

          EXPECTED_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$BUNDLE/Contents/Info.plist")"
          EXPECTED_TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$BUNDLE" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
          if [ -z "$EXPECTED_TEAM_ID" ]; then
            echo "Installed app TeamIdentifier could not be read." >&2
            exit 1
          fi

          /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING"
          /usr/sbin/spctl --assess --type execute --verbose=2 "$STAGING"
          /usr/bin/xcrun stapler validate "$STAGING"

          ACTUAL_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$STAGING/Contents/Info.plist")"
          if [ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
            echo "CFBundleIdentifier mismatch: expected $EXPECTED_BUNDLE_ID, got $ACTUAL_BUNDLE_ID" >&2
            exit 1
          fi

          ACTUAL_TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$STAGING" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
          if [ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
            echo "TeamIdentifier mismatch: expected $EXPECTED_TEAM_ID, got $ACTUAL_TEAM_ID" >&2
            exit 1
          fi

          TARGET_PARENT="$(dirname "$BUNDLE")"
          TARGET_NAME="$(basename "$BUNDLE")"
          BACKUP="$TARGET_PARENT/.$TARGET_NAME.desktop_updater_backup.$$"

          /bin/mv "$BUNDLE" "$BACKUP"
          if /bin/mv "$STAGING" "$BUNDLE"; then
            /bin/rm -rf "$BACKUP"
            /bin/rm -rf "$(dirname "$MANIFEST")"
          else
            /bin/mv "$BACKUP" "$BUNDLE"
            exit 1
          fi
        fi

        if [ "$SKIP_RELAUNCH" != "1" ]; then
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
