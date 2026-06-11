# macOS Cloudflare Hosted Update E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the macOS production updater through the real hosted zip-first contract: `app-archive.json` points to `release.json`, and `release.json` points to one Developer ID signed, notarized, stapled zip artifact served over HTTPS by Cloudflare Tunnel.

**Architecture:** Keep the native macOS replacement flow unchanged. Add example-app smoke hooks so the example can run the controller-driven hosted flow from an injected URL, then publish a temporary local artifact directory through Cloudflare Tunnel and run the smoke against the public HTTPS URL. The final acceptance gate must include check, download, SHA-256 verification, safe staging, macOS codesign/Gatekeeper/stapler gates, whole `.app` replacement, and relaunch.

**Tech Stack:** Flutter macOS, Dart, `DesktopUpdaterController`, `desktop_updater:package`, `desktop_updater:verify`, `codesign`, `notarytool`, `stapler`, `spctl`, Cloudflare Tunnel, local static HTTP server.

---

## File Structure

- Modify: `example/lib/app.dart`
  - Read `DESKTOP_UPDATER_APP_ARCHIVE_URL` for the example controller URL.
  - Add `DESKTOP_UPDATER_HOSTED_SMOKE=1` automation that calls `checkVersion()`, `downloadUpdate()`, and `restartApp()`.
  - Write state markers to `DESKTOP_UPDATER_HOSTED_SMOKE_MARKER`.
- Modify: `example/tool/updater_smoke.dart`
  - Keep direct staging smoke behavior unchanged.
  - Optionally share helper functions with the new hosted smoke tool if doing so removes duplication.
- Create: `example/tool/hosted_update_smoke.dart`
  - Launch a signed app with `DESKTOP_UPDATER_APP_ARCHIVE_URL`.
  - Wait for hosted smoke markers and installed sentinel.
  - Support `--production-gates`, `--relaunch`, `--app`, and `--app-archive-url`.
- Create: `test/example_hosted_smoke_config_test.dart`
  - Lock the environment variable names and hosted marker sequence.
- No branch operation is allowed. Commit only after explicit user approval.

---

### Task 1: Add Example App Hosted Smoke Hooks

**Files:**
- Modify: `example/lib/app.dart`
- Test: `test/example_hosted_smoke_config_test.dart`

- [ ] **Step 1: Add the failing smoke configuration test**

Create `test/example_hosted_smoke_config_test.dart`:

```dart
import "dart:io";

import "package:test/test.dart";

void main() {
  test("example app exposes hosted update smoke environment hooks", () {
    final source = File("example/lib/app.dart").readAsStringSync();

    expect(source, contains("DESKTOP_UPDATER_APP_ARCHIVE_URL"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE_MARKER"));
    expect(source, contains("_runHostedSmokeTestCommand"));
    expect(source, contains("checkVersion()"));
    expect(source, contains("downloadUpdate()"));
    expect(source, contains("restartApp()"));
  });
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
flutter test --no-pub test/example_hosted_smoke_config_test.dart
```

Expected: fail because the example app does not yet expose hosted smoke hooks.

- [ ] **Step 3: Implement the hosted URL override and smoke flow**

In `example/lib/app.dart`, add these helpers below `_desktopUpdaterPlugin`:

```dart
  static const _defaultAppArchiveUrl =
      "https://www.yoursite.com/app-archive.json";

  bool get _hostedSmokeEnabled =>
      Platform.environment["DESKTOP_UPDATER_HOSTED_SMOKE"] == "1";

  Uri _configuredAppArchiveUrl() {
    final value = Platform.environment["DESKTOP_UPDATER_APP_ARCHIVE_URL"];
    return Uri.parse(
      value == null || value.trim().isEmpty
          ? _defaultAppArchiveUrl
          : value.trim(),
    );
  }
```

Change controller construction to:

```dart
    _desktopUpdaterController = DesktopUpdaterController(
      appArchiveUrl: _configuredAppArchiveUrl(),
      skipInitialVersionCheck: _hostedSmokeEnabled,
      localization: const DesktopUpdateLocalization(
```

Keep the existing direct staging smoke call and add:

```dart
    unawaited(_runSmokeTestCommand());
    unawaited(_runHostedSmokeTestCommand());
```

Add this method next to `_runSmokeTestCommand`:

```dart
  Future<void> _runHostedSmokeTestCommand() async {
    if (!_hostedSmokeEnabled) {
      return;
    }

    final markerPath =
        Platform.environment["DESKTOP_UPDATER_HOSTED_SMOKE_MARKER"];

    try {
      await _writeSmokeMarker(markerPath, "checking");
      await _desktopUpdaterController.checkVersion();

      if (!_desktopUpdaterController.needUpdate) {
        await _writeSmokeMarker(markerPath, "no-update");
        return;
      }

      await _writeSmokeMarker(markerPath, "downloading");
      await _desktopUpdaterController.downloadUpdate();

      await _writeSmokeMarker(markerPath, "installing");
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _desktopUpdaterController.restartApp();
    } catch (error) {
      await _writeSmokeMarker(markerPath, "failed: $error");
      rethrow;
    }
  }
```

- [ ] **Step 4: Verify the test passes**

Run:

```bash
flutter test --no-pub test/example_hosted_smoke_config_test.dart
```

Expected: pass.

---

### Task 2: Add Hosted Update Smoke Tool

**Files:**
- Create: `example/tool/hosted_update_smoke.dart`
- Test: `test/example_hosted_smoke_tool_test.dart`

- [ ] **Step 1: Add the failing tool test**

Create `test/example_hosted_smoke_tool_test.dart`:

```dart
import "dart:io";

import "package:test/test.dart";

void main() {
  test("hosted update smoke tool launches app with hosted env contract", () {
    final source =
        File("example/tool/hosted_update_smoke.dart").readAsStringSync();

    expect(source, contains("--app-archive-url"));
    expect(source, contains("DESKTOP_UPDATER_APP_ARCHIVE_URL"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE_MARKER"));
    expect(source, contains("checking"));
    expect(source, contains("downloading"));
    expect(source, contains("installing"));
  });
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
flutter test --no-pub test/example_hosted_smoke_tool_test.dart
```

Expected: fail because the tool does not exist.

- [ ] **Step 3: Implement the tool**

Create `example/tool/hosted_update_smoke.dart`:

```dart
import "dart:async";
import "dart:io";

Future<void> main(List<String> args) async {
  final relaunch = args.contains("--relaunch");
  final appPath = _absolutePath(_argValue(args, "--app") ?? _defaultAppPath());
  final appArchiveUrl = _argValue(args, "--app-archive-url");

  if (appPath == null || appArchiveUrl == null || appArchiveUrl.trim().isEmpty) {
    _usage();
    exit(64);
  }

  final executablePath = _executablePath(appPath);
  final installedSentinel = File(
    Platform.isMacOS && appPath.endsWith(".app")
        ? _joinAll([
            appPath,
            "Contents",
            "Resources",
            "desktop_updater_smoke.txt",
          ])
        : _join(File(appPath).parent.path, "desktop_updater_smoke.txt"),
  );

  if (!File(executablePath).existsSync()) {
    stderr.writeln("Executable not found: $executablePath");
    exit(66);
  }
  if (installedSentinel.existsSync()) {
    stderr.writeln(
      "Installed app already contains ${installedSentinel.path}; use a clean installed app.",
    );
    exit(65);
  }

  final tempRoot = await Directory.systemTemp.createTemp(
    "desktop_updater_hosted_smoke_",
  );
  final markerPath = _join(tempRoot.path, "marker.txt");

  stdout
    ..writeln("Launching $executablePath")
    ..writeln("Using app archive $appArchiveUrl");

  final process = await Process.start(
    executablePath,
    const [],
    environment: {
      "DESKTOP_UPDATER_APP_ARCHIVE_URL": appArchiveUrl,
      "DESKTOP_UPDATER_HOSTED_SMOKE": "1",
      "DESKTOP_UPDATER_HOSTED_SMOKE_MARKER": markerPath,
      if (!relaunch) "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1",
    },
    mode: ProcessStartMode.normal,
    workingDirectory: File(executablePath).parent.path,
  );

  process.stdout.listen(stdout.add);
  process.stderr.listen(stderr.add);

  await _waitForFileText(markerPath, "checking", const Duration(seconds: 15));
  await _waitForFileText(markerPath, "downloading", const Duration(seconds: 30));
  await _waitForFileText(markerPath, "installing", const Duration(seconds: 60));

  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 45),
    onTimeout: () {
      process.kill();
      throw TimeoutException("App did not exit after scheduling update.");
    },
  );
  stdout.writeln("Initial app process exited with code $exitCode");

  await _waitFor(
    installedSentinel.existsSync,
    const Duration(seconds: 60),
    "Timed out waiting for hosted update sentinel at ${installedSentinel.path}",
  );

  stdout
    ..writeln("Hosted smoke update installed: ${installedSentinel.path}")
    ..writeln(
      relaunch
          ? "Relaunch was enabled; close the relaunched example app manually."
          : "Relaunch was skipped for test cleanup. Pass --relaunch to test it.",
    );
}

String? _defaultAppPath() {
  if (Platform.isMacOS) {
    return _joinAll([
      "build",
      "macos",
      "Build",
      "Products",
      "Release",
      "desktop_updater_example.app",
    ]);
  }
  return null;
}

String _executablePath(String appPath) {
  if (Platform.isMacOS && appPath.endsWith(".app")) {
    return _joinAll([appPath, "Contents", "MacOS", "desktop_updater_example"]);
  }
  return appPath;
}

Future<void> _waitForFileText(
  String filePath,
  String expected,
  Duration timeout,
) async {
  await _waitFor(
    () =>
        File(filePath).existsSync() &&
        File(filePath).readAsStringSync().trim() == expected,
    timeout,
    "Timed out waiting for hosted smoke marker '$expected'.",
  );
}

Future<void> _waitFor(
  bool Function() condition,
  Duration timeout,
  String timeoutMessage,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException(timeoutMessage);
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

String? _absolutePath(String? path) {
  if (path == null) {
    return null;
  }
  return File(path).absolute.path;
}

String _join(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) {
    return "$left$right";
  }
  return "$left${Platform.pathSeparator}$right";
}

String _joinAll(List<String> parts) {
  return parts.reduce(_join);
}

void _usage() {
  stderr.writeln(
    "Usage: dart run tool/hosted_update_smoke.dart --app <path> "
    "--app-archive-url <https-url> [--relaunch]\n",
  );
}
```

- [ ] **Step 4: Verify tool test passes**

Run:

```bash
flutter test --no-pub test/example_hosted_smoke_tool_test.dart
```

Expected: pass.

---

### Task 3: Prepare Hosted macOS Production Artifacts

**Files:**
- No repository file changes unless automation is added after approval.
- Artifact root: `/private/tmp/desktop_updater_hosted_e2e.<suffix>`

- [ ] **Step 1: Build current installed app**

Run from `example/`:

```bash
flutter build macos --release --build-name 0.1.5 --build-number 6
```

Expected: `build/macos/Build/Products/Release/desktop_updater_example.app`.

- [ ] **Step 2: Copy installed and update app bundles**

Run:

```bash
ROOT="$(mktemp -d /private/tmp/desktop_updater_hosted_e2e.XXXXXX)"
mkdir -p "$ROOT/installed" "$ROOT/update" "$ROOT/web"
/usr/bin/ditto build/macos/Build/Products/Release/desktop_updater_example.app "$ROOT/installed/desktop_updater_example.app"
flutter build macos --release --build-name 0.1.6 --build-number 7
/usr/bin/ditto build/macos/Build/Products/Release/desktop_updater_example.app "$ROOT/update/desktop_updater_example.app"
mkdir -p "$ROOT/update/desktop_updater_example.app/Contents/Resources"
printf '%s\n' 'desktop_updater hosted production smoke' > "$ROOT/update/desktop_updater_example.app/Contents/Resources/desktop_updater_smoke.txt"
```

Expected: update app contains the sentinel before signing.

- [ ] **Step 3: Sign both apps with Developer ID**

Run:

```bash
IDENTITY="Developer ID Application: Burak Karahan (UPK4SC93AN)"
ENTITLEMENTS="/Users/marlonjd/Developer/library/flutter_desktop_updater/example/macos/Runner/Release.entitlements"
for APP in "$ROOT/installed/desktop_updater_example.app" "$ROOT/update/desktop_updater_example.app"; do
  /usr/bin/codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/App.framework"
  /usr/bin/codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/FlutterMacOS.framework"
  /usr/bin/codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
  /usr/bin/codesign -dvvv --entitlements :- "$APP"
done
```

Expected: `Authority=Developer ID Application: Burak Karahan (UPK4SC93AN)`, `TeamIdentifier=UPK4SC93AN`, runtime flag, sandbox false, no `get-task-allow`.

- [ ] **Step 4: Notarize and staple**

Run:

```bash
/usr/bin/ditto -c -k --keepParent "$ROOT/installed/desktop_updater_example.app" "$ROOT/installed.zip"
/usr/bin/ditto -c -k --keepParent "$ROOT/update/desktop_updater_example.app" "$ROOT/update.zip"
xcrun notarytool submit "$ROOT/installed.zip" --keychain-profile desktop-updater-notary --wait --output-format json
xcrun notarytool submit "$ROOT/update.zip" --keychain-profile desktop-updater-notary --wait --output-format json
xcrun stapler staple "$ROOT/installed/desktop_updater_example.app"
xcrun stapler staple "$ROOT/update/desktop_updater_example.app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$ROOT/installed/desktop_updater_example.app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$ROOT/update/desktop_updater_example.app"
```

Expected: notarization `Accepted`, stapler success, and `source=Notarized Developer ID`.

- [ ] **Step 5: Package update zip and write release index**

The public URL is not known until Cloudflare Tunnel starts. Use a placeholder first, then rewrite the artifact URL after tunnel creation.

Run:

```bash
cd /Users/marlonjd/Developer/library/flutter_desktop_updater
dart run desktop_updater:package \
  --input "$ROOT/update/desktop_updater_example.app" \
  --output "$ROOT/web" \
  --package-id net.monolib.updater \
  --app-name desktop_updater_example.app \
  --version 0.1.6 \
  --build-number 7 \
  --platform macos \
  --channel stable \
  --install-strategy wholeBundleReplace \
  --artifact-url https://example.invalid/desktop_updater_example.app.zip
```

Expected: `$ROOT/web/release.json` and one zip artifact.

---

### Task 4: Serve Through Cloudflare Tunnel and Run Hosted Smoke

**Files:**
- No repository file changes.

- [ ] **Step 1: Start a local static server**

Run in a separate terminal:

```bash
python3 -m http.server 8787 --directory "$ROOT/web"
```

Expected: `Serving HTTP on :: port 8787`.

- [ ] **Step 2: Start Cloudflare Tunnel**

Run in another terminal:

```bash
cloudflared tunnel --url http://127.0.0.1:8787
```

Expected: a public `https://...trycloudflare.com` URL. Store it:

```bash
PUBLIC="https://the-url-from-cloudflared.trycloudflare.com"
```

- [ ] **Step 3: Rewrite release URLs for the tunnel**

Run:

```bash
ZIP_NAME="$(basename "$(ls "$ROOT"/web/*.zip | head -n 1)")"
dart run desktop_updater:package \
  --input "$ROOT/update/desktop_updater_example.app" \
  --output "$ROOT/web" \
  --package-id net.monolib.updater \
  --app-name desktop_updater_example.app \
  --version 0.1.6 \
  --build-number 7 \
  --platform macos \
  --channel stable \
  --install-strategy wholeBundleReplace \
  --artifact-url "$PUBLIC/$ZIP_NAME"
cat > "$ROOT/web/app-archive.json" <<EOF
{
  "schemaVersion": 3,
  "appName": "Desktop Updater",
  "items": [
    {
      "platform": "macos",
      "channel": "stable",
      "version": "0.1.6",
      "minimumVersion": "0.1.5",
      "buildNumber": 7,
      "mandatory": false,
      "release": "$PUBLIC/release.json"
    }
  ]
}
EOF
```

Expected: `app-archive.json` points to the tunnel `release.json`; `release.json` points to the tunnel zip URL.

- [ ] **Step 4: Verify hosted JSON and artifact**

Run:

```bash
curl -fsS "$PUBLIC/app-archive.json"
curl -fsS "$PUBLIC/release.json"
dart run desktop_updater:verify --release "$ROOT/web/release.json"
```

Expected: both `curl` commands print JSON, and verify prints `release.json verified`.

- [ ] **Step 5: Run hosted production smoke without relaunch**

Run:

```bash
cd /Users/marlonjd/Developer/library/flutter_desktop_updater/example
dart run tool/hosted_update_smoke.dart \
  --app "$ROOT/installed/desktop_updater_example.app" \
  --app-archive-url "$PUBLIC/app-archive.json"
```

Expected: markers reach `checking`, `downloading`, `installing`; app exits; sentinel appears in the installed app.

- [ ] **Step 6: Run hosted production smoke with relaunch**

Prepare a clean installed app again, staple it, then run:

```bash
mkdir -p "$ROOT/relaunch-installed"
/usr/bin/ditto -x -k "$ROOT/installed.zip" "$ROOT/relaunch-installed"
xcrun stapler staple "$ROOT/relaunch-installed/desktop_updater_example.app"
dart run tool/hosted_update_smoke.dart \
  --relaunch \
  --app "$ROOT/relaunch-installed/desktop_updater_example.app" \
  --app-archive-url "$PUBLIC/app-archive.json"
```

Expected: update installs, the app relaunches, and the relaunched process uses the replaced notarized app.

---

### Task 5: Verification and Handoff

- [ ] **Step 1: Run local package verification**

Run:

```bash
dart format --set-exit-if-changed .
flutter test --no-pub
flutter analyze --no-fatal-infos
dart pub publish --dry-run
```

Expected: format clean, tests pass, analyzer exits 0, dry-run exits 0.

- [ ] **Step 2: Summarize evidence**

Record these values in the final response:

```text
Developer ID identity:
Notary submission IDs:
Cloudflare public URL:
release.json SHA-256:
zip artifact name:
codesign result:
spctl result:
stapler result:
hosted smoke result:
hosted relaunch result:
```

- [ ] **Step 3: Commit only after approval**

If the user explicitly approves a commit, stage only the hosted smoke changes and tests:

```bash
git add example/lib/app.dart example/tool/hosted_update_smoke.dart test/example_hosted_smoke_config_test.dart test/example_hosted_smoke_tool_test.dart
git commit -m "test: add macos hosted update smoke"
git push origin main
```

Expected: no untracked plan files are accidentally committed unless the user explicitly asks for plan docs to be included.
