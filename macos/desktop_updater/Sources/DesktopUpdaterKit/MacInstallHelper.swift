import Foundation

public struct MacInstallHelper {
    public init() {}

    public func scheduleInstallAndRelaunch(_ request: MacInstallRequest) throws {
        try validateStagingPath(request.stagingPath)
        let scriptURL = try writeHelperScript(for: request)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw error
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
        let allowUnsignedValue = request.allowUnsignedUpdates ? "1" : ""
        #if DEBUG
            let smokeGateBypassAssignment = "ALLOW_UNSIGNED_MACOS=\"${DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS:-\(allowUnsignedValue)}\""
        #else
            let smokeGateBypassAssignment = "ALLOW_UNSIGNED_MACOS=\"\(allowUnsignedValue)\""
        #endif

        return """
        #!/bin/sh
        set -eu

        PID="\(request.currentProcessIdentifier)"
        STAGING=\(shellQuote(request.stagingPath ?? ""))
        BUNDLE=\(shellQuote(request.bundlePath))
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

        if [ -n "$STAGING" ]; then
          log_event "staging path validation"
          MANIFEST="$STAGING/.desktop_updater_release_manifest.json"
          if [ -f "$MANIFEST" ] && \
             /usr/bin/grep -q '"strategy"[[:space:]]*:[[:space:]]*"pkgInstaller"' "$MANIFEST" && \
             /usr/bin/grep -q '"launchMode"[[:space:]]*:[[:space:]]*"installerApp"' "$MANIFEST"; then
            log_event "pkg manifest loaded"
            PKG="$STAGING/installer.pkg"
            if [ ! -f "$PKG" ]; then
              echo "Staged macOS PKG installer is missing." >&2
              exit 1
            fi
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
    }

    private func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct MacInstallHelperError: LocalizedError {
    let message: String
    let path: String

    var errorDescription: String? {
        return message
    }
}
