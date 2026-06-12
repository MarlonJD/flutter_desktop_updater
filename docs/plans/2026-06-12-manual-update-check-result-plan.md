# Manual Update Check Result Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in manual update-check result API so apps can show "up to date", "update available", or "check failed" feedback with their own UI, while keeping automatic startup checks quiet.

**Architecture:** Keep `DesktopUpdaterController.checkVersion()` compatible and state-driven, then add a typed `checkForUpdates()` wrapper that returns a public result object for explicit user actions such as "Check for Updates...". Add a small optional dialog helper for callers who want stock Material feedback, but document custom UI as the preferred integration path for branded apps.

**Tech Stack:** Dart sealed classes, Flutter `ChangeNotifier`, existing `UpdateState` and `ReleaseDescriptor` models, Material dialogs, Flutter widget tests, and `flutter test --no-pub`.

---

## Non-Negotiable Constraints

- Do not create, switch, rename, delete, or otherwise operate on branches during implementation unless the user explicitly asks for that branch action in the same execution turn.
- Do not post GitHub comments or review feedback through any Codex/GitHub connector identity.
- Do not change automatic startup behavior: startup checks may show available-update UI through existing widgets, but must not show an "up to date" dialog.
- Keep `checkVersion()` source-compatible and behavior-compatible for existing users.
- Keep the new "up to date" UI opt-in and manual-action-oriented.
- Keep package public names clear of the existing internal `UpdateCheckResult` class in `lib/src/core/update_client.dart`.
- Use `flutter test --no-pub` for validation to avoid `example/pubspec.lock` churn.

## File Structure

- Create: `lib/src/manual_update_check_result.dart`
  - Public typed result for manual checks.
  - Avoids name collision with internal `UpdateCheckResult`.
- Modify: `lib/desktop_updater.dart`
  - Export the new public result API.
- Modify: `lib/updater_controller.dart`
  - Add `checkForUpdates()` without changing `checkVersion()`.
  - Map current controller state to typed manual result values.
- Modify: `lib/src/localization.dart`
  - Add optional copy for up-to-date, failed-check, and OK button feedback.
- Modify: `lib/widget/update_dialog.dart`
  - Add an opt-in helper for presenting manual check results.
  - Do not make `UpdateDialogListener` show up-to-date dialogs.
- Modify: `README.md`
  - Document manual "Check for Updates..." integration and custom UI switch usage.
- Modify: `example/lib/app.dart`
  - Add a small manual check button in the example app.
- Modify: `test/updater_controller_test.dart`
  - Test result mapping for up-to-date, available, and failed checks.
- Modify: `test/update_dialog_listener_test.dart`
  - Test optional dialog helper behavior without regressing duplicate-dialog guard behavior.

## Public API Shape

Create `lib/src/manual_update_check_result.dart`:

```dart
import "package:desktop_updater/src/core/release_descriptor.dart";

sealed class ManualUpdateCheckResult {
  const ManualUpdateCheckResult();
}

final class ManualUpdateCheckUpToDate extends ManualUpdateCheckResult {
  const ManualUpdateCheckUpToDate();
}

final class ManualUpdateCheckAvailable extends ManualUpdateCheckResult {
  const ManualUpdateCheckAvailable({
    required this.descriptor,
    required this.mandatory,
  });

  final ReleaseDescriptor descriptor;
  final bool mandatory;
}

final class ManualUpdateCheckFailed extends ManualUpdateCheckResult {
  const ManualUpdateCheckFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
```

Add this export to `lib/desktop_updater.dart`:

```dart
export "package:desktop_updater/src/manual_update_check_result.dart";
```

Add this method to `DesktopUpdaterController`:

```dart
Future<ManualUpdateCheckResult> checkForUpdates() async {
  try {
    await checkVersion();
  } catch (error, stackTrace) {
    _state = UpdateFailed(error);
    notifyListeners();
    return ManualUpdateCheckFailed(error, stackTrace);
  }

  final currentState = state;
  if (currentState is UpdateAvailable) {
    return ManualUpdateCheckAvailable(
      descriptor: currentState.descriptor,
      mandatory: currentState.mandatory,
    );
  }

  if (currentState is UpdateFailed) {
    return ManualUpdateCheckFailed(
      currentState.error,
      StackTrace.current,
    );
  }

  return const ManualUpdateCheckUpToDate();
}
```

This preserves existing `checkVersion()` semantics. Existing code that awaits `checkVersion()` still throws on failures. New manual UI code can call `checkForUpdates()` and render a result without handling thrown exceptions in the common case.

## Task 0: Confirm Starting State

**Files:**
- Read: `lib/updater_controller.dart`
- Read: `lib/widget/update_dialog.dart`
- Read: `lib/src/core/update_client.dart`
- Read: `README.md`
- Read: `test/updater_controller_test.dart`
- Read: `test/update_dialog_listener_test.dart`

- [ ] **Step 0.1: Inspect working tree**

Run:

```sh
git status --short
```

Expected: record any pre-existing changed files. Do not revert unrelated user work.

- [ ] **Step 0.2: Re-read existing manual check API**

Run:

```sh
sed -n '1,360p' lib/updater_controller.dart
```

Expected: `checkVersion()` still returns `Future<void>`, `init()` still calls `checkVersion()` unless `skipInitialVersionCheck` is true, and `UpdateAvailable` is the typed state for available updates.

- [ ] **Step 0.3: Re-read existing dialog guard**

Run:

```sh
sed -n '1,180p' lib/widget/update_dialog.dart
```

Expected: `UpdateDialogListener` uses `_dialogRequest` and `_shouldShowDialog()` only returns true for `controller.needUpdate && !controller.skipUpdate && !controller.isDownloading`.

## Task 1: Add Public Manual Check Result Types

**Files:**
- Create: `lib/src/manual_update_check_result.dart`
- Modify: `lib/desktop_updater.dart`

- [ ] **Step 1.1: Write the result type file**

Create `lib/src/manual_update_check_result.dart` with:

```dart
import "package:desktop_updater/src/core/release_descriptor.dart";

/// Result returned by an explicit user-triggered update check.
///
/// Automatic startup checks should continue to use controller state and should
/// not show an "up to date" confirmation by default.
sealed class ManualUpdateCheckResult {
  const ManualUpdateCheckResult();
}

/// No newer release is available for the current app, platform, and channel.
final class ManualUpdateCheckUpToDate extends ManualUpdateCheckResult {
  const ManualUpdateCheckUpToDate();
}

/// A newer release is available and the controller state has been updated.
final class ManualUpdateCheckAvailable extends ManualUpdateCheckResult {
  const ManualUpdateCheckAvailable({
    required this.descriptor,
    required this.mandatory,
  });

  final ReleaseDescriptor descriptor;
  final bool mandatory;
}

/// The update check failed before a final available or up-to-date result.
final class ManualUpdateCheckFailed extends ManualUpdateCheckResult {
  const ManualUpdateCheckFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
```

- [ ] **Step 1.2: Export the public result type**

In `lib/desktop_updater.dart`, add this export beside the existing core exports:

```dart
export "package:desktop_updater/src/manual_update_check_result.dart";
```

- [ ] **Step 1.3: Format changed files**

Run:

```sh
dart format lib/src/manual_update_check_result.dart lib/desktop_updater.dart
```

Expected: formatter exits with code 0.

## Task 2: Add `DesktopUpdaterController.checkForUpdates()`

**Files:**
- Modify: `lib/updater_controller.dart`
- Test: `test/updater_controller_test.dart`

- [ ] **Step 2.1: Write result mapping tests first**

Append these tests to `test/updater_controller_test.dart`:

```dart
  test("checkForUpdates returns up to date when checkVersion leaves idle state", () async {
    final controller = _ManualCheckTestController(
      onCheckVersion: (controller) {
        controller.setStateForTest(const UpdateIdle());
      },
    );

    final result = await controller.checkForUpdates();

    expect(result, isA<ManualUpdateCheckUpToDate>());
  });

  test("checkForUpdates returns available when checkVersion sets available state", () async {
    final descriptor = _testDescriptor();
    final controller = _ManualCheckTestController(
      onCheckVersion: (controller) {
        controller.setStateForTest(
          UpdateAvailable(descriptor: descriptor, mandatory: true),
        );
      },
    );

    final result = await controller.checkForUpdates();

    expect(result, isA<ManualUpdateCheckAvailable>());
    final available = result as ManualUpdateCheckAvailable;
    expect(available.descriptor, descriptor);
    expect(available.mandatory, isTrue);
  });

  test("checkForUpdates returns failed when checkVersion throws", () async {
    final error = StateError("network down");
    final controller = _ManualCheckTestController(
      onCheckVersion: (_) {
        throw error;
      },
    );

    final result = await controller.checkForUpdates();

    expect(result, isA<ManualUpdateCheckFailed>());
    expect((result as ManualUpdateCheckFailed).error, same(error));
    expect(controller.state, isA<UpdateFailed>());
  });
```

Add these imports at the top of the same test file:

```dart
import "package:desktop_updater/desktop_updater.dart";
```

Add these helpers below the existing tests:

```dart
class _ManualCheckTestController extends DesktopUpdaterController {
  _ManualCheckTestController({required this.onCheckVersion})
      : super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
        );

  final FutureOr<void> Function(_ManualCheckTestController controller)
      onCheckVersion;

  UpdateState? _stateOverride;

  @override
  UpdateState get state => _stateOverride ?? super.state;

  void setStateForTest(UpdateState value) {
    _stateOverride = value;
  }

  @override
  Future<void> checkVersion() async {
    await onCheckVersion(this);
  }
}

ReleaseDescriptor _testDescriptor() {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example.app",
    version: "2.0.1",
    buildNumber: 201,
    platform: "macos",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://example.com/Example.zip"),
      sha256:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      length: 1024,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 12),
  );
}
```

Also add the Dart async import:

```dart
import "dart:async";
```

- [ ] **Step 2.2: Run the failing controller tests**

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart
```

Expected: fail because `checkForUpdates`, `ManualUpdateCheckResult`, and helper result classes are not implemented or exported yet.

- [ ] **Step 2.3: Import result types in controller**

Add this import to `lib/updater_controller.dart`:

```dart
import "package:desktop_updater/src/manual_update_check_result.dart";
```

- [ ] **Step 2.4: Add `checkForUpdates()` implementation**

Add this method to `DesktopUpdaterController` immediately after `checkVersion()`:

```dart
  Future<ManualUpdateCheckResult> checkForUpdates() async {
    try {
      await checkVersion();
    } catch (error, stackTrace) {
      _state = UpdateFailed(error);
      notifyListeners();
      return ManualUpdateCheckFailed(error, stackTrace);
    }

    final currentState = state;
    if (currentState is UpdateAvailable) {
      return ManualUpdateCheckAvailable(
        descriptor: currentState.descriptor,
        mandatory: currentState.mandatory,
      );
    }

    if (currentState is UpdateFailed) {
      return ManualUpdateCheckFailed(
        currentState.error,
        StackTrace.current,
      );
    }

    return const ManualUpdateCheckUpToDate();
  }
```

- [ ] **Step 2.5: Format controller and tests**

Run:

```sh
dart format lib/updater_controller.dart test/updater_controller_test.dart
```

Expected: formatter exits with code 0.

- [ ] **Step 2.6: Run controller tests**

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart
```

Expected: all tests in `test/updater_controller_test.dart` pass.

## Task 3: Add Optional Manual Result Dialog Helper

**Files:**
- Modify: `lib/src/localization.dart`
- Modify: `lib/widget/update_dialog.dart`
- Test: `test/update_dialog_listener_test.dart`

- [ ] **Step 3.1: Extend localization copy**

Add these parameters to `DesktopUpdateLocalization`:

```dart
    this.upToDateTitleText,
    this.upToDateText,
    this.updateCheckFailedTitleText,
    this.updateCheckFailedText,
    this.okText,
```

Add these fields to the class:

```dart
  /// Default: "Application is up to date"
  final String? upToDateTitleText;

  /// Default: "{} is the latest available version."
  final String? upToDateText;

  /// Default: "Could not check for updates"
  final String? updateCheckFailedTitleText;

  /// Default: "Please try again later."
  final String? updateCheckFailedText;

  /// Default: "OK"
  final String? okText;
```

- [ ] **Step 3.2: Write dialog helper widget tests first**

Append these tests to `test/update_dialog_listener_test.dart`:

```dart
  testWidgets("manual up-to-date result helper shows one confirmation dialog", (
    tester,
  ) async {
    final controller = _TestDesktopUpdaterController();

    await tester.pumpWidget(_buildManualResultApp(
      controller: controller,
      result: const ManualUpdateCheckUpToDate(),
    ));

    await tester.tap(find.text("Show result"));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text("Application is up to date"), findsOneWidget);
    expect(find.text("Test App 2.0.0 is the latest available version."), findsOneWidget);
  });

  testWidgets("manual failed result helper shows retry-later dialog", (
    tester,
  ) async {
    final controller = _TestDesktopUpdaterController();

    await tester.pumpWidget(_buildManualResultApp(
      controller: controller,
      result: ManualUpdateCheckFailed(
        StateError("network down"),
        StackTrace.current,
      ),
    ));

    await tester.tap(find.text("Show result"));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text("Could not check for updates"), findsOneWidget);
    expect(find.text("Please try again later."), findsOneWidget);
  });

  testWidgets("manual available result helper stays quiet by default", (
    tester,
  ) async {
    final controller = _TestDesktopUpdaterController();

    await tester.pumpWidget(_buildManualResultApp(
      controller: controller,
      result: ManualUpdateCheckAvailable(
        descriptor: _testDescriptor(),
        mandatory: false,
      ),
    ));

    await tester.tap(find.text("Show result"));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });
```

Add this import to the same test file:

```dart
import "package:desktop_updater/desktop_updater.dart";
```

Add this helper below `_buildTestApp`:

```dart
Widget _buildManualResultApp({
  required _TestDesktopUpdaterController controller,
  required ManualUpdateCheckResult result,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) {
          return TextButton(
            onPressed: () {
              showManualUpdateCheckResultDialog(
                context,
                controller: controller,
                result: result,
              );
            },
            child: const Text("Show result"),
          );
        },
      ),
    ),
  );
}
```

Add this descriptor helper below `_buildManualResultApp`:

```dart
ReleaseDescriptor _testDescriptor() {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example.app",
    version: "2.0.1",
    buildNumber: 201,
    platform: "macos",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://example.com/Example.zip"),
      sha256:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      length: 1024,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 12),
  );
}
```

- [ ] **Step 3.3: Run failing dialog tests**

Run:

```sh
flutter test --no-pub test/update_dialog_listener_test.dart
```

Expected: fail because `showManualUpdateCheckResultDialog()` and new localization fields are not implemented.

- [ ] **Step 3.4: Add dialog helper import**

Add this import to `lib/widget/update_dialog.dart`:

```dart
import "package:desktop_updater/src/manual_update_check_result.dart";
```

- [ ] **Step 3.5: Add opt-in helper to `update_dialog.dart`**

Add this function after `showUpdateDialog`:

```dart
Future<void> showManualUpdateCheckResultDialog(
  BuildContext context, {
  required DesktopUpdaterController controller,
  required ManualUpdateCheckResult result,
  bool showAvailableUpdate = false,
  Color? backgroundColor,
  Color? iconColor,
  Color? shadowColor,
  Color? textColor,
  Color? buttonTextColor,
}) async {
  switch (result) {
    case ManualUpdateCheckAvailable():
      if (!showAvailableUpdate) {
        return;
      }
      await showUpdateDialog<void>(
        context,
        controller: controller,
        backgroundColor: backgroundColor,
        iconColor: iconColor,
        shadowColor: shadowColor,
      );
    case ManualUpdateCheckUpToDate():
      await showDialog<void>(
        context: context,
        builder: (context) {
          final localization = controller.getLocalization;
          final appName = controller.appName ?? "This application";
          final appVersion = controller.appVersion ?? "";
          final versionLabel = appVersion.isEmpty
              ? appName
              : "$appName $appVersion";

          return AlertDialog(
            backgroundColor: backgroundColor,
            iconColor: iconColor,
            shadowColor: shadowColor,
            title: Text(
              localization?.upToDateTitleText ??
                  "Application is up to date",
              style: TextStyle(color: textColor),
            ),
            content: Text(
              getLocalizedString(
                    localization?.upToDateText,
                    [versionLabel],
                  ) ??
                  "$versionLabel is the latest available version.",
              style: TextStyle(color: textColor),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  localization?.okText ?? "OK",
                  style: TextStyle(color: buttonTextColor),
                ),
              ),
            ],
          );
        },
      );
    case ManualUpdateCheckFailed():
      await showDialog<void>(
        context: context,
        builder: (context) {
          final localization = controller.getLocalization;

          return AlertDialog(
            backgroundColor: backgroundColor,
            iconColor: iconColor,
            shadowColor: shadowColor,
            title: Text(
              localization?.updateCheckFailedTitleText ??
                  "Could not check for updates",
              style: TextStyle(color: textColor),
            ),
            content: Text(
              localization?.updateCheckFailedText ??
                  "Please try again later.",
              style: TextStyle(color: textColor),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  localization?.okText ?? "OK",
                  style: TextStyle(color: buttonTextColor),
                ),
              ),
            ],
          );
        },
      );
  }
}
```

- [ ] **Step 3.6: Keep `UpdateDialogListener` unchanged**

Verify the listener still only calls `showDialog` from `_tryShowDialog()` and still uses:

```dart
return controller.needUpdate &&
    !controller.skipUpdate &&
    !controller.isDownloading;
```

Expected: no up-to-date behavior is added to `UpdateDialogListener`.

- [ ] **Step 3.7: Format localization, dialog, and tests**

Run:

```sh
dart format lib/src/localization.dart lib/widget/update_dialog.dart test/update_dialog_listener_test.dart
```

Expected: formatter exits with code 0.

- [ ] **Step 3.8: Run dialog tests**

Run:

```sh
flutter test --no-pub test/update_dialog_listener_test.dart
```

Expected: all tests in `test/update_dialog_listener_test.dart` pass, including existing duplicate-dialog guard tests.

## Task 4: Document Manual Integration And Custom UI

**Files:**
- Modify: `README.md`
- Modify: `example/lib/app.dart`

- [ ] **Step 4.1: Add README manual check section**

Add this section after the existing `skipInitialVersionCheck` example:

````markdown
### Manual "Check for Updates..." feedback

Automatic startup checks stay quiet when no update is available. For a user-triggered menu item or button, call `checkForUpdates()` and decide how your app should present the result:

```dart
final result = await controller.checkForUpdates();

switch (result) {
  case ManualUpdateCheckAvailable():
    // Existing update widgets can show the download flow from controller state.
    break;
  case ManualUpdateCheckUpToDate():
    // Show a native app dialog, snackbar, settings-row message, or custom widget.
    break;
  case ManualUpdateCheckFailed(:final error):
    // Log the error and show retry guidance that matches your app.
    break;
}
```

If you want the package's stock Material feedback for manual checks, use the optional helper:

```dart
final result = await controller.checkForUpdates();
await showManualUpdateCheckResultDialog(
  context,
  controller: controller,
  result: result,
);
```

The helper does not show an available-update dialog by default, because apps often already mount `UpdateDialogListener`, `DesktopUpdateWidget`, or a custom update surface. Pass `showAvailableUpdate: true` only when the manual check action owns the whole update presentation.
````

- [ ] **Step 4.2: Add example manual check state**

In `example/lib/app.dart`, add this field to `_HomePageState`:

```dart
  bool _checkingForUpdates = false;
```

Add this method above `build`:

```dart
  Future<void> _checkForUpdatesManually() async {
    if (_checkingForUpdates) {
      return;
    }

    setState(() {
      _checkingForUpdates = true;
    });

    try {
      final result = await _desktopUpdaterController.checkForUpdates();
      if (!mounted) {
        return;
      }
      await showManualUpdateCheckResultDialog(
        context,
        controller: _desktopUpdaterController,
        result: result,
      );
    } finally {
      if (mounted) {
        setState(() {
          _checkingForUpdates = false;
        });
      }
    }
  }
```

- [ ] **Step 4.3: Add example button**

Inside the example `Column`, under the platform text, add:

```dart
                FilledButton.icon(
                  onPressed: _checkingForUpdates
                      ? null
                      : _checkForUpdatesManually,
                  icon: _checkingForUpdates
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update),
                  label: Text(
                    _checkingForUpdates
                        ? "Checking..."
                        : "Check for updates",
                  ),
                ),
```

- [ ] **Step 4.4: Format docs-related code**

Run:

```sh
dart format example/lib/app.dart
```

Expected: formatter exits with code 0.

## Task 5: Full Validation

**Files:**
- Read: `lib/src/manual_update_check_result.dart`
- Read: `lib/updater_controller.dart`
- Read: `lib/widget/update_dialog.dart`
- Read: `README.md`
- Read: `example/lib/app.dart`

- [ ] **Step 5.1: Run targeted tests**

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart test/update_dialog_listener_test.dart
```

Expected: both targeted test files pass.

- [ ] **Step 5.2: Run broader package tests**

Run:

```sh
flutter test --no-pub
```

Expected: package tests pass without modifying `example/pubspec.lock`.

- [ ] **Step 5.3: Run targeted analyzer**

Run:

```sh
dart analyze lib test/updater_controller_test.dart test/update_dialog_listener_test.dart example/lib/app.dart
```

Expected: no new analyzer errors from the changed files.

- [ ] **Step 5.4: Inspect final diff**

Run:

```sh
git diff -- lib/src/manual_update_check_result.dart lib/desktop_updater.dart lib/updater_controller.dart lib/src/localization.dart lib/widget/update_dialog.dart README.md example/lib/app.dart test/updater_controller_test.dart test/update_dialog_listener_test.dart
```

Expected:
- New API is opt-in.
- `checkVersion()` remains public and compatible.
- `UpdateDialogListener` still does not show up-to-date dialogs.
- README tells app owners to choose custom UI unless they want the stock helper.
- No generated lockfile, build output, or unrelated file changes are included.

## Self-Review Notes

- The plan covers API, controller mapping, optional UI helper, docs, example usage, and tests.
- The plan deliberately avoids native AppKit/Win32/Linux menu integration because this package is a Flutter plugin and should expose a cross-platform result surface first.
- The new public type is named `ManualUpdateCheckResult` to avoid colliding with the existing internal `UpdateCheckResult`.
- Automatic no-update popup behavior is explicitly excluded.
