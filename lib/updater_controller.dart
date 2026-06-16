import "dart:async";

import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/core/update_diagnostics.dart";
import "package:desktop_updater/src/core/update_diagnostics_recorder.dart";
import "package:desktop_updater/src/core/update_preferences.dart";
import "package:desktop_updater/src/core/update_recovery.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/src/core/update_telemetry.dart";
import "package:desktop_updater/src/current_version.dart";
import "package:desktop_updater/src/localization.dart";
import "package:desktop_updater/src/manual_update_check_result.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter/material.dart";

export "package:desktop_updater/src/core/update_client.dart"
    show MinimumOSSupportChecker;
export "package:desktop_updater/src/core/update_diagnostics.dart";
export "package:desktop_updater/src/core/update_diagnostics_recorder.dart";
export "package:desktop_updater/src/core/update_preferences.dart";
export "package:desktop_updater/src/core/update_recovery.dart";
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
    this.installationIdentity,
    this.preferences,
    this.recoveryStore,
    this.diagnosticsLogPath,
    this.telemetry,
    this.isMinimumOSSupported,
    UpdateDiagnosticsRecorder? diagnosticsRecorder,
    Future<void> Function(UpdateProblemReport report)? onProblemReport,
    FutureOr<void> Function(UpdateCleanupReport report)? onCleanupReport,
    bool skipInitialVersionCheck = false,
  })  : _skipInitialVersionCheck = skipInitialVersionCheck,
        _diagnosticsRecorder =
            diagnosticsRecorder ?? UpdateDiagnosticsRecorder(channel: channel),
        _onProblemReport = onProblemReport,
        _onCleanupReport = onCleanupReport {
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

  /// Stable app-owned identity used for deterministic staged rollouts.
  final String? installationIdentity;

  /// Optional app-owned persistence adapter for skipped versions.
  final UpdatePreferences? preferences;

  /// Optional app-owned persistence adapter for pending install recovery.
  final UpdateRecoveryStore? recoveryStore;

  /// Optional app-owned native helper diagnostics log path.
  final String? diagnosticsLogPath;

  /// Optional app-owned telemetry callback.
  final DesktopUpdaterTelemetry? telemetry;

  final UpdateDiagnosticsRecorder _diagnosticsRecorder;
  final Future<void> Function(UpdateProblemReport report)? _onProblemReport;
  final FutureOr<void> Function(UpdateCleanupReport report)? _onCleanupReport;

  /// In-memory diagnostics recorder used to build failure reports.
  UpdateDiagnosticsRecorder get diagnosticsRecorder => _diagnosticsRecorder;

  /// Most recent install scheduling or cleanup report emitted by this
  /// controller.
  UpdateCleanupReport? get lastCleanupReport => _lastCleanupReport;

  /// Whether the app supplied an explicit problem-report callback.
  bool get canReportProblem => _onProblemReport != null;

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
  String? _currentAppVersion;
  UpdateCleanupReport? _lastCleanupReport;

  /// Invokes the app-owned problem-report callback when one was supplied.
  Future<void> reportProblem(UpdateProblemReport report) async {
    final callback = _onProblemReport;
    if (callback == null) {
      return;
    }
    await callback(report);
  }

  /// Sets the app archive URL and starts the initial update check when enabled.
  void init(Uri url) {
    _appArchiveUrl = url;
    if (_skipInitialVersionCheck) {
      notifyListeners();
      return;
    }

    unawaited(_recoverThenCheckVersionQuietly());
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

    _diagnosticsRecorder
      ..clear()
      ..record(
        stage: UpdateDiagnosticStage.check,
        level: UpdateDiagnosticLevel.info,
        message: "Checking for updates from $archiveUrl",
      );
    _lastCleanupReport = null;
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
      _currentAppVersion = _formatVersionInfo(currentVersion);

      final client = UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: currentVersion,
        channel: channel,
        installationIdentity: installationIdentity,
        telemetry: telemetry,
        isMinimumOSSupported: isMinimumOSSupported,
      );
      final result = await client.checkForUpdate();
      if (result == null) {
        _client = null;
        _activeDescriptor = null;
        _stagingPath = null;
        _skipUpdate = false;
        _diagnosticsRecorder.record(
          stage: UpdateDiagnosticStage.check,
          level: UpdateDiagnosticLevel.info,
          message: "No update is available.",
        );
        _state = const UpdateIdle();
        notifyListeners();
        return;
      }

      if (!result.item.mandatory && await _isSkipped(result.descriptor)) {
        _client = null;
        _activeDescriptor = null;
        _stagingPath = null;
        _skipUpdate = true;
        _diagnosticsRecorder.record(
          stage: UpdateDiagnosticStage.policy,
          level: UpdateDiagnosticLevel.info,
          message: "Update ${result.descriptor.version} is skipped.",
        );
        _state = const UpdateIdle();
        notifyListeners();
        return;
      }

      _skipUpdate = false;
      _client = client;
      _activeDescriptor = result.descriptor;
      _stagingPath = null;
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.descriptor,
        level: UpdateDiagnosticLevel.info,
        message: "Update selected: ${result.descriptor.version} "
            "(${result.descriptor.platform}/${result.descriptor.channel}).",
      );
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
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.check,
        level: UpdateDiagnosticLevel.error,
        message: "Update check failed.",
        error: error,
      );
      _state = UpdateFailed(error, report: _buildProblemReport(error));
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

  Future<void> _recoverThenCheckVersionQuietly() async {
    await recoverPendingInstall();
    if (_state is UpdateFailed) {
      return;
    }
    await _checkVersionQuietly();
  }

  /// Checks for updates for an explicit user action and returns a typed result.
  Future<ManualUpdateCheckResult> checkForUpdates() async {
    try {
      await checkVersion();
    } on Object catch (error, stackTrace) {
      _state = UpdateFailed(
        error,
        report: _reportFromStateOrBuild(error),
      );
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
    _diagnosticsRecorder.record(
      stage: UpdateDiagnosticStage.download,
      level: UpdateDiagnosticLevel.info,
      message: "Downloading update artifact from ${descriptor.artifact.url}",
    );
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
      _diagnosticsRecorder
        ..record(
          stage: UpdateDiagnosticStage.verify,
          level: UpdateDiagnosticLevel.info,
          message: "Update artifact verified.",
        )
        ..record(
          stage: UpdateDiagnosticStage.stage,
          level: UpdateDiagnosticLevel.info,
          message: "Update staged at ${result.stagingPath}",
        );
      _state = UpdateReadyToInstall(stagingPath: result.stagingPath);
      notifyListeners();
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.download,
        level: UpdateDiagnosticLevel.error,
        message: "Download failed.",
        error: error,
      );
      _state = UpdateFailed(
        error,
        report: _buildProblemReport(error, updateVersion: descriptor.version),
      );
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
    _diagnosticsRecorder.record(
      stage: UpdateDiagnosticStage.install,
      level: UpdateDiagnosticLevel.info,
      message: "Install handoff started for $stagingPath",
    );
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
      await _writePendingRecoveryMarker(stagingPath);
      await DesktopUpdaterPlatform.instance.installUpdate(
        stagingPath: stagingPath,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
        diagnosticsLogPath: diagnosticsLogPath,
      );
      final cleanupReport = _buildCleanupReport(
        stagingPath: stagingPath,
        cleanupAttempted: false,
      );
      _recordCleanupReport(cleanupReport);
      _state = UpdateInstalling(cleanupReport: cleanupReport);
      notifyListeners();
    } on Object catch (error) {
      await _clearPendingRecoveryMarker();
      _recordCleanupReport(
        _buildCleanupReport(
          stagingPath: stagingPath,
          cleanupAttempted: false,
          cleanupSucceeded: false,
          errorText: error.toString(),
        ),
      );
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.error,
        message: "Install failed.",
        error: error,
      );
      _state = UpdateFailed(
        error,
        report: _buildProblemReport(
          error,
          updateVersion: _activeDescriptor?.version,
          stagingPath: stagingPath,
        ),
      );
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

  /// Recovers a pending native install marker from the app-owned store.
  Future<void> recoverPendingInstall() async {
    final store = recoveryStore;
    if (store == null) {
      return;
    }

    final UpdateInstallRecoveryMarker? marker;
    try {
      marker = await store.readPendingInstall(channel: channel);
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.warning,
        message: "Recovery marker read failed.",
        error: error,
      );
      notifyListeners();
      return;
    }

    if (marker == null) {
      return;
    }

    _diagnosticsRecorder
      ..clear()
      ..record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.warning,
        message: "Pending install marker found for "
            "${marker.updateVersion ?? "unknown update"}.",
      );

    final DesktopVersionInfo? currentVersion;
    try {
      currentVersion = await currentVersionInfo();
    } on Object catch (error) {
      _failRecoveredInstall(
        marker,
        StateError("Could not verify completed install after relaunch."),
        message: "Could not verify completed install after relaunch.",
        appVersion: marker.appVersion,
        error: error,
      );
      return;
    }

    if (currentVersion == null) {
      _failRecoveredInstall(
        marker,
        StateError("Could not verify completed install after relaunch."),
        message: "Could not verify completed install after relaunch.",
        appVersion: marker.appVersion,
      );
      return;
    }

    final currentAppVersion = _formatVersionInfo(currentVersion);
    _currentAppVersion = currentAppVersion ?? marker.appVersion;
    if (_matchesRecoveredTarget(currentVersion, marker)) {
      await _clearPendingRecoveryMarker();
      _state = const UpdateIdle();
      notifyListeners();
      return;
    }

    _failRecoveredInstall(
      marker,
      StateError("Pending install did not complete after relaunch."),
      message: "Pending install did not complete after relaunch.",
      appVersion: _currentAppVersion,
    );
  }

  Future<void> _writePendingRecoveryMarker(String stagingPath) async {
    final store = recoveryStore;
    if (store == null) {
      return;
    }

    final marker = UpdateInstallRecoveryMarker(
      createdAt: DateTime.now(),
      packageVersion: _diagnosticsRecorder.packageVersion,
      platform: _diagnosticsRecorder.platform,
      channel: channel,
      appVersion: _currentAppVersion,
      updateVersion: _activeDescriptor?.version,
      updateBuildNumber: _activeDescriptor?.buildNumber,
      stagingPath: stagingPath,
      diagnosticsText: _buildProblemReport(
        StateError("Install handoff pending."),
        updateVersion: _activeDescriptor?.version,
        stagingPath: stagingPath,
      ).toPlainText(),
    );

    try {
      await store.writePendingInstall(marker);
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.warning,
        message: "Recovery marker write failed.",
        error: error,
      );
    }
  }

  Future<void> _clearPendingRecoveryMarker() async {
    final store = recoveryStore;
    if (store == null) {
      return;
    }

    try {
      await store.clearPendingInstall(channel: channel);
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.warning,
        message: "Recovery marker clear failed.",
        error: error,
      );
    }
  }

  void _failRecoveredInstall(
    UpdateInstallRecoveryMarker marker,
    Object failure, {
    required String message,
    String? appVersion,
    Object? error,
  }) {
    _diagnosticsRecorder.record(
      stage: UpdateDiagnosticStage.install,
      level: UpdateDiagnosticLevel.error,
      message: message,
      error: error ?? failure,
    );
    _state = UpdateFailed(
      failure,
      report: _diagnosticsRecorder.buildReport(
        appVersion: appVersion ?? marker.appVersion,
        updateVersion: marker.updateVersion,
        stagingPath: marker.stagingPath,
        failure: failure,
      ),
    );
    notifyListeners();
  }

  UpdateCleanupReport _buildCleanupReport({
    required String stagingPath,
    required bool cleanupAttempted,
    bool? cleanupSucceeded,
    bool? backupRestoredByNativeHelper,
    String? errorText,
  }) {
    return UpdateCleanupReport(
      stagingPath: stagingPath,
      descriptorVersion: _activeDescriptor?.version,
      cleanupAttempted: cleanupAttempted,
      cleanupSucceeded: cleanupSucceeded,
      backupRestoredByNativeHelper: backupRestoredByNativeHelper,
      errorText: errorText,
    );
  }

  void _recordCleanupReport(UpdateCleanupReport report) {
    _lastCleanupReport = report;
    final callback = _onCleanupReport;
    if (callback == null) {
      return;
    }

    unawaited(
      Future<void>.sync(() => callback(report)).catchError((Object _) {}),
    );
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

  UpdateProblemReport _reportFromStateOrBuild(Object error) {
    final currentState = state;
    if (currentState is UpdateFailed && currentState.report != null) {
      return currentState.report!;
    }
    return _buildProblemReport(error);
  }

  UpdateProblemReport _buildProblemReport(
    Object error, {
    String? updateVersion,
    String? stagingPath,
  }) {
    return _diagnosticsRecorder.buildReport(
      appVersion: _currentAppVersion,
      updateVersion: updateVersion ?? _activeDescriptor?.version,
      stagingPath: stagingPath ?? _stagingPath,
      failure: error,
    );
  }
}

bool _matchesRecoveredTarget(
  DesktopVersionInfo currentVersion,
  UpdateInstallRecoveryMarker marker,
) {
  final targetVersion = marker.updateVersion;
  final targetBuildNumber = marker.updateBuildNumber;
  final hasTargetVersion = targetVersion != null && targetVersion.isNotEmpty;
  final versionMatches = hasTargetVersion
      ? currentVersion.versionName == targetVersion ||
          currentVersion.rawVersion == targetVersion
      : null;
  final buildMatches = targetBuildNumber == null
      ? null
      : currentVersion.buildNumber == targetBuildNumber;

  if (versionMatches != null && buildMatches != null) {
    return versionMatches && buildMatches;
  }
  return versionMatches ?? buildMatches ?? false;
}

String? _formatVersionInfo(DesktopVersionInfo version) {
  final versionName = version.versionName;
  final buildNumber = version.buildNumber;
  if (versionName != null && buildNumber != null) {
    return "$versionName+$buildNumber";
  }
  if (version.rawVersion != null && version.rawVersion!.isNotEmpty) {
    return version.rawVersion;
  }
  if (versionName != null && versionName.isNotEmpty) {
    return versionName;
  }
  return buildNumber?.toString();
}
