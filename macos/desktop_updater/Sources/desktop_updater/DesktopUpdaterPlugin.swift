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
        removedFiles: [String],
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

            let scriptURL = try writeHelperScript(
                stagingPath: stagingPath,
                removedFiles: removedFiles
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
        removedFiles: [String]
    ) throws -> URL {
        let bundlePath = Bundle.main.bundlePath
        let contentsPath = (bundlePath as NSString).appendingPathComponent("Contents")
        let helperName = "desktop_updater_\(UUID().uuidString).sh"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(helperName)

        var script = """
        #!/bin/sh
        set -eu

        PID="\(ProcessInfo.processInfo.processIdentifier)"
        STAGING=\(shellQuote(stagingPath ?? ""))
        TARGET=\(shellQuote(contentsPath))
        BUNDLE=\(shellQuote(bundlePath))
        SKIP_RELAUNCH="${DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH:-}"

        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.5
        done

        """

        if !removedFiles.isEmpty {
            script += """
            for rel in \(removedFiles.map(shellQuote).joined(separator: " ")); do
              case "$rel" in
                ""|/*|../*|*/../*|*/..|..)
                  continue
                  ;;
              esac
              rm -rf "$TARGET/$rel"
            done

            """
        }

        script += """
        if [ -n "$STAGING" ]; then
          if command -v ditto >/dev/null 2>&1; then
            ditto "$STAGING" "$TARGET"
          else
            cp -R "$STAGING"/. "$TARGET"/
          fi
          rm -rf "$STAGING"
        fi

        restore_execute_bits() {
          chmod +x "$TARGET/MacOS"/* 2>/dev/null || true

          if command -v file >/dev/null 2>&1; then
            find "$TARGET/Frameworks" -type f -exec sh -c '
              for candidate do
                if file "$candidate" 2>/dev/null | grep -q "Mach-O"; then
                  chmod +x "$candidate" 2>/dev/null || true
                fi
              done
            ' sh {} +

            find "$TARGET" -path "*/flutter_assets/assets/engine/*" -type f -exec sh -c '
              for candidate do
                if file "$candidate" 2>/dev/null | grep -q "Mach-O"; then
                  chmod +x "$candidate" 2>/dev/null || true
                fi
              done
            ' sh {} +
          else
            chmod +x "$TARGET"/Frameworks/*.framework/Versions/*/* 2>/dev/null || true
            chmod +x "$TARGET"/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/engine/macos/* 2>/dev/null || true
          fi
        }

        restore_execute_bits

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
