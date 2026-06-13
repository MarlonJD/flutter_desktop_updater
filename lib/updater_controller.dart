import "dart:async";

import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/core/update_preferences.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/src/core/update_telemetry.dart";
import "package:desktop_updater/src/current_version.dart";
import "package:desktop_updater/src/localization.dart";
import "package:desktop_updater/src/manual_update_check_result.dart";
import "package:flutter/material.dart";

export "package:desktop_updater/src/core/update_client.dart"
    show MinimumOSSupportChecker;
export "package:desktop_updater/src/core/update_preferences.dart";
export "package:desktop_updater/src/core/update_telemetry.dart";

/// Coordinates update checks, downloads, and install handoff for UI code.
///
/// The controller owns the high-level [UpdateState] used by the ready-made
/// widgets and by custom Flutter UI. Automatic startup checks run quietly and
/// report failures through [state]; explicit calls such as [checkVersion] keep
/// throwing so apps can handle user-triggered failures directly.
class DesktopUpdaterController extends ChangeNotifier {
  /// Creates a controller for a hosted zip-first app archive.
  ///
  /// When [appArchiveUrl] is provided and [skipInitialVersionCheck] is false,
  /// the controller starts an asynchronous update check during construction.
  DesktopUpdaterController({
    required Uri? appArchiveUrl,
    this.localization,
    this.allowUnsignedMacOSUpdates = false,
    this.channel = "stable",
    this.preferences,
    this.telemetry,
    this.isMinimumOSSupported,
    bool skipInitialVersionCheck = false,
  }) : _skipInitialVersionCheck = skipInitialVersionCheck {
    if (appArchiveUrl != null) {
      init(appArchiveUrl);
    }
  }

  final bool _skipInitialVersionCheck;

  /// Whether construction should avoid starting the first automatic check.
  bool get skipInitialVersionCheck => _skipInitialVersionCheck;

  /// Optional strings used by bundled update UI.
  DesktopUpdateLocalization? localization;

  /// Current localization values used by bundled update UI.
  DesktopUpdateLocalization? get getLocalization => localization;

  /// Release channel used for update selection and skip preferences.
  final String channel;

  /// Optional app-owned persistence adapter for skipped versions.
  final UpdatePreferences? preferences;

  /// Optional app-owned telemetry callback.
  final DesktopUpdaterTelemetry? telemetry;

  /// Optional app-owned minimum OS support policy.
  final MinimumOSSupportChecker? isMinimumOSSupported;

  /// Allows macOS Release installs to bypass native signing, Gatekeeper,
  /// stapler, and Team ID checks.
  ///
  /// Keep this false for public macOS distribution. When true, macOS still
  /// requires a complete `.app` bundle with the same bundle identifier.
  final bool allowUnsignedMacOSUpdates;

  Uri? _appArchiveUrl;

  /// Hosted `app-archive.json` URL used for update checks.
  Uri? get appArchiveUrl => _appArchiveUrl;

  /// Name of the app from the active release descriptor, when available.
  String? get appName => _activeDescriptor?.appName;

  /// Version from the active release descriptor, when available.
  String? get appVersion => _activeDescriptor?.version;

  bool _skipUpdate = false;
  String? _skippedVersionInMemory;

  /// Whether the user has skipped the currently offered update in this session.
  bool get skipUpdate => _skipUpdate;

  UpdateState _state = const UpdateIdle();

  /// Current update lifecycle state for UI rendering.
  UpdateState get state => _state;

  ReleaseDescriptor? _activeDescriptor;

  /// Descriptor selected by the latest successful update check, if any.
  ReleaseDescriptor? get activeDescriptor => _activeDescriptor;

  UpdateClient? _client;
  String? _stagingPath;

  /// Sets the app archive URL and starts the initial update check when enabled.
  void init(Uri url) {
    _appArchiveUrl = url;
    if (_skipInitialVersionCheck) {
      notifyListeners();
      return;
    }

    unawaited(_checkVersionQuietly());
    notifyListeners();
  }

  /// Marks the currently available update as skipped for this controller.
  Future<void> makeSkipUpdate() async {
    _skipUpdate = true;
    final version = _activeDescriptor?.version;
    if (version != null) {
      _skippedVersionInMemory = version;
      try {
        await preferences?.skipVersion(version: version, channel: channel);
      } on Object {
        // Keep the in-memory skip even when the app-owned store is unavailable.
      }
    }
    notifyListeners();
  }

  /// Checks for a newer release and updates [state].
  ///
  /// This is the strict low-level check: failures move [state] to
  /// [UpdateFailed] and are rethrown to the caller. Use [checkForUpdates] for
  /// user-triggered checks that should return a typed result instead.
  Future<void> checkVersion() async {
    final archiveUrl = _appArchiveUrl;
    if (archiveUrl == null) {
      throw StateError("App archive URL is not set.");
    }

    _state = const UpdateChecking();
    emitUpdateTelemetry(
      telemetry,
      UpdateTelemetryEvent.checkStarted(
        source: archiveUrl,
        channel: channel,
      ),
    );
    notifyListeners();

    try {
      final currentVersion = await currentVersionInfo();
      if (currentVersion == null) {
        throw StateError("Current app version is unavailable.");
      }

      final client = UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: currentVersion,
        channel: channel,
        telemetry: telemetry,
        isMinimumOSSupported: isMinimumOSSupported,
      );
      final result = await client.checkForUpdate();
      if (result == null) {
        _client = null;
        _activeDescriptor = null;
        _stagingPath = null;
        _skipUpdate = false;
        _state = const UpdateIdle();
        notifyListeners();
        return;
      }

      if (!result.item.mandatory && await _isSkipped(result.descriptor)) {
        _client = null;
        _activeDescriptor = null;
        _stagingPath = null;
        _skipUpdate = true;
        _state = const UpdateIdle();
        notifyListeners();
        return;
      }

      _skipUpdate = false;
      _client = client;
      _activeDescriptor = result.descriptor;
      _stagingPath = null;
      _state = UpdateAvailable(
        descriptor: result.descriptor,
        mandatory: result.item.mandatory,
      );
      emitUpdateTelemetry(
        telemetry,
        UpdateTelemetryEvent.updateSelected(
          version: result.descriptor.version,
          channel: result.descriptor.channel,
          platform: result.descriptor.platform,
          mandatory: result.item.mandatory,
        ),
      );
      notifyListeners();
    } catch (error) {
      _state = UpdateFailed(error);
      emitUpdateTelemetry(
        telemetry,
        UpdateTelemetryEvent.checkFailed(
          source: archiveUrl,
          channel: channel,
          error: error,
        ),
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _checkVersionQuietly() async {
    try {
      await checkVersion();
    } on Object {
      // checkVersion already moved the controller into UpdateFailed.
    }
  }

  /// Checks for updates for an explicit user action and returns a typed result.
  Future<ManualUpdateCheckResult> checkForUpdates() async {
    try {
      await checkVersion();
    } on Object catch (error, stackTrace) {
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

  /// Downloads, verifies, and stages the active release descriptor.
  ///
  /// A successful call moves [state] to [UpdateReadyToInstall]. Failures move
  /// [state] to [UpdateFailed] and are rethrown.
  Future<void> downloadUpdate() async {
    final descriptor = _activeDescriptor;
    final client = _client;
    if (descriptor == null || client == null) {
      throw StateError("No zip-first update is available.");
    }

    _stagingPath = null;
    _state = UpdateDownloading(
      receivedBytes: 0,
      totalBytes: descriptor.artifact.length,
    );
    emitUpdateTelemetry(
      telemetry,
      UpdateTelemetryEvent.downloadStarted(
        source: descriptor.artifact.url,
        version: descriptor.version,
        channel: descriptor.channel,
        platform: descriptor.platform,
      ),
    );
    notifyListeners();

    try {
      final result = await client.downloadVerifyAndStage(
        descriptor: descriptor,
        onProgress: (receivedBytes, totalBytes) {
          _state = UpdateDownloading(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes ?? descriptor.artifact.length,
          );
          notifyListeners();
        },
      );

      _stagingPath = result.stagingPath;
      _state = UpdateReadyToInstall(stagingPath: result.stagingPath);
      notifyListeners();
    } catch (error) {
      _state = UpdateFailed(error);
      emitUpdateTelemetry(
        telemetry,
        UpdateTelemetryEvent.downloadFailed(
          source: descriptor.artifact.url,
          version: descriptor.version,
          channel: descriptor.channel,
          platform: descriptor.platform,
          error: error,
        ),
      );
      notifyListeners();
      rethrow;
    }
  }

  /// Hands the staged update to the native installer or restart helper.
  Future<void> restartApp() async {
    final stagingPath = _stagingPath;
    if (stagingPath == null || stagingPath.isEmpty) {
      throw StateError("No downloaded update is ready to install.");
    }

    _state = const UpdateInstalling();
    emitUpdateTelemetry(
      telemetry,
      UpdateTelemetryEvent.installScheduled(
        stagingPath: stagingPath,
        version: _activeDescriptor?.version,
        channel: _activeDescriptor?.channel,
        platform: _activeDescriptor?.platform,
      ),
    );
    notifyListeners();

    try {
      await DesktopUpdaterPlatform.instance.installUpdate(
        stagingPath: stagingPath,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
      );
    } catch (error) {
      _state = UpdateFailed(error);
      emitUpdateTelemetry(
        telemetry,
        UpdateTelemetryEvent.installFailed(
          stagingPath: stagingPath,
          version: _activeDescriptor?.version,
          channel: _activeDescriptor?.channel,
          platform: _activeDescriptor?.platform,
          error: error,
        ),
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<bool> _isSkipped(ReleaseDescriptor descriptor) async {
    final skippedVersion = await _storedSkippedVersion();
    if (skippedVersion == null) {
      return _skipUpdate;
    }

    return skippedVersion == descriptor.version;
  }

  Future<String?> _storedSkippedVersion() async {
    final adapter = preferences;
    if (adapter == null) {
      return _skippedVersionInMemory;
    }

    try {
      return await adapter.skippedVersion(channel: channel);
    } on Object {
      return _skippedVersionInMemory;
    }
  }
}
