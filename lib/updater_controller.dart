import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_notes.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/core/update_diagnostics.dart";
import "package:desktop_updater/src/core/update_diagnostics_recorder.dart";
import "package:desktop_updater/src/core/update_preferences.dart";
import "package:desktop_updater/src/core/update_recovery.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/src/core/update_telemetry.dart";
import "package:desktop_updater/src/current_version.dart";
import "package:desktop_updater/src/io/http_update_transport.dart"
    show UpdateRequestHeadersProvider;
import "package:desktop_updater/src/io/release_notes_fetcher.dart";
import "package:desktop_updater/src/localization.dart";
import "package:desktop_updater/src/manual_update_check_result.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

export "package:desktop_updater/src/core/update_client.dart"
    show MinimumOSSupportChecker;
export "package:desktop_updater/src/core/update_diagnostics.dart";
export "package:desktop_updater/src/core/update_diagnostics_recorder.dart";
export "package:desktop_updater/src/core/update_preferences.dart";
export "package:desktop_updater/src/core/update_recovery.dart";
export "package:desktop_updater/src/core/update_telemetry.dart";
export "package:desktop_updater/src/io/http_update_transport.dart"
    show UpdateRequestHeadersProvider;

/// Loads release notes for the selected update descriptor.
typedef ReleaseNotesLoader = Future<ReleaseNotes> Function(
  ReleaseDescriptor descriptor,
);

/// Opens an external URL, such as a fresh installer download page.
typedef ExternalUrlLauncher = Future<void> Function(
  Uri url,
);

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
    DesktopUpdateLocalization? localization,
    this.allowUnsignedMacOSUpdates = false,
    this.channel = "stable",
    this.installationIdentity,
    this.preferences,
    this.recoveryStore,
    this.diagnosticsLogPath,
    this.telemetry,
    this.isMinimumOSSupported,
    this.requestHeadersProvider,
    UpdateDiagnosticsRecorder? diagnosticsRecorder,
    Future<void> Function(UpdateProblemReport report)? onProblemReport,
    FutureOr<void> Function(UpdateCleanupReport report)? onCleanupReport,
    bool skipInitialVersionCheck = false,
    ReleaseNotesLoader? releaseNotesLoader,
    Uri? releaseNotesUrl,
    ExternalUrlLauncher? externalUrlLauncher,
  })  : _localization = localization,
        _skipInitialVersionCheck = skipInitialVersionCheck,
        _diagnosticsRecorder =
            diagnosticsRecorder ?? UpdateDiagnosticsRecorder(channel: channel),
        _onProblemReport = onProblemReport,
        _onCleanupReport = onCleanupReport,
        _releaseNotesLoader = releaseNotesLoader,
        _releaseNotesUrl = releaseNotesUrl,
        _externalUrlLauncher =
            externalUrlLauncher ?? defaultExternalUrlLauncher,
        _releaseNotesFetcher = releaseNotesUrl == null
            ? null
            : ReleaseNotesFetcher(
                requestHeadersProvider: requestHeadersProvider,
              ) {
    if (appArchiveUrl != null) {
      init(appArchiveUrl);
    }
  }

  /// Creates a controller with injected collaborators for unit testing.
  ///
  /// Identical to the default constructor but accepts an optional
  /// [releaseNotesFetcher] so tests can substitute a fake HTTP layer without
  /// exposing that seam in the public API.
  @visibleForTesting
  DesktopUpdaterController.forTesting({
    required Uri? appArchiveUrl,
    DesktopUpdateLocalization? localization,
    this.allowUnsignedMacOSUpdates = false,
    this.channel = "stable",
    this.installationIdentity,
    this.preferences,
    this.recoveryStore,
    this.diagnosticsLogPath,
    this.telemetry,
    this.isMinimumOSSupported,
    this.requestHeadersProvider,
    UpdateDiagnosticsRecorder? diagnosticsRecorder,
    Future<void> Function(UpdateProblemReport report)? onProblemReport,
    FutureOr<void> Function(UpdateCleanupReport report)? onCleanupReport,
    bool skipInitialVersionCheck = false,
    ReleaseNotesLoader? releaseNotesLoader,
    Uri? releaseNotesUrl,
    ReleaseNotesFetcher? releaseNotesFetcher,
    ExternalUrlLauncher? externalUrlLauncher,
  })  : _localization = localization,
        _skipInitialVersionCheck = skipInitialVersionCheck,
        _diagnosticsRecorder =
            diagnosticsRecorder ?? UpdateDiagnosticsRecorder(channel: channel),
        _onProblemReport = onProblemReport,
        _onCleanupReport = onCleanupReport,
        _releaseNotesLoader = releaseNotesLoader,
        _releaseNotesUrl = releaseNotesUrl,
        _externalUrlLauncher =
            externalUrlLauncher ?? defaultExternalUrlLauncher,
        _releaseNotesFetcher = releaseNotesFetcher ??
            (releaseNotesUrl == null
                ? null
                : ReleaseNotesFetcher(
                    requestHeadersProvider: requestHeadersProvider,
                  )) {
    if (appArchiveUrl != null) {
      init(appArchiveUrl);
    }
  }

  final bool _skipInitialVersionCheck;

  /// Whether construction should avoid starting the first automatic check.
  bool get skipInitialVersionCheck => _skipInitialVersionCheck;

  DesktopUpdateLocalization? _localization;

  /// Optional strings used by bundled update UI.
  DesktopUpdateLocalization? get localization => _localization;

  /// Updates localization values used by bundled update UI.
  set localization(DesktopUpdateLocalization? value) {
    if (identical(_localization, value)) {
      return;
    }
    _localization = value;
    notifyListeners();
  }

  /// Current localization values used by bundled update UI.
  DesktopUpdateLocalization? get getLocalization => _localization;

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

  /// Optional URL for hosted release notes JSON.
  ///
  /// This is a convenience path for simple apps. Prefer the descriptor-aware
  /// release notes loader when notes should depend on the active descriptor,
  /// locale, account, or app environment.
  Uri? get releaseNotesUrl => _releaseNotesUrl;

  /// Whether release notes can be loaded for the selected update descriptor.
  bool get canLoadReleaseNotes {
    return activeDescriptor != null &&
        (_releaseNotesLoader != null || _releaseNotesUrl != null);
  }

  /// Current release notes loading state.
  ReleaseNotesState get releaseNotesState => _releaseNotesState;

  /// Optional app-owned minimum OS support policy.
  final MinimumOSSupportChecker? isMinimumOSSupported;

  /// Optional app-owned HTTP headers for update metadata and artifact requests.
  final UpdateRequestHeadersProvider? requestHeadersProvider;

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

  ReleaseFreshInstall? _activeFreshInstall;

  /// Fresh-install policy for the active update, when present.
  ReleaseFreshInstall? get activeFreshInstall => _activeFreshInstall;

  ReleaseSupportPolicy? _activeSupportPolicy;

  /// Support policy applying to the active update, when present.
  ReleaseSupportPolicy? get activeSupportPolicy => _activeSupportPolicy;

  UpdateClient? _client;
  String? _stagingPath;
  String? _currentAppVersion;
  UpdateCleanupReport? _lastCleanupReport;

  final ReleaseNotesLoader? _releaseNotesLoader;
  final Uri? _releaseNotesUrl;
  final ReleaseNotesFetcher? _releaseNotesFetcher;
  final ExternalUrlLauncher _externalUrlLauncher;
  ReleaseNotesState _releaseNotesState = const ReleaseNotesIdle();
  ReleaseNotes? _cachedReleaseNotes;
  String? _cachedReleaseNotesKey;

  /// Loads release notes for the active update descriptor.
  ///
  /// Returns a cached result for the same descriptor unless [forceRefresh] is
  /// true. Loading errors are stored in [releaseNotesState] and rethrown.
  Future<ReleaseNotes> loadReleaseNotes({bool forceRefresh = false}) async {
    final descriptor = activeDescriptor;
    if (descriptor == null) {
      throw StateError("No active update descriptor is available.");
    }
    if (_releaseNotesLoader == null && _releaseNotesUrl == null) {
      throw StateError("No release notes loader is configured.");
    }

    final cacheKey = _releaseNotesCacheKey(descriptor);
    final cached = _cachedReleaseNotes;
    if (!forceRefresh && cached != null && _cachedReleaseNotesKey == cacheKey) {
      return cached;
    }

    _releaseNotesState = const ReleaseNotesLoading();
    notifyListeners();

    try {
      final loader = _releaseNotesLoader;
      final notes = loader == null
          ? await _releaseNotesFetcher!.fetch(_releaseNotesUrl!)
          : await loader(descriptor);
      _cachedReleaseNotes = notes;
      _cachedReleaseNotesKey = cacheKey;
      _releaseNotesState = ReleaseNotesLoaded(notes);
      notifyListeners();
      return notes;
    } on Object catch (error) {
      _releaseNotesState = ReleaseNotesFailed(error);
      notifyListeners();
      rethrow;
    }
  }

  /// Fetches and returns the hosted release notes.
  ///
  /// Compatibility wrapper around [loadReleaseNotes].
  Future<ReleaseNotes> fetchReleaseNotes() => loadReleaseNotes();

  /// Invokes the app-owned problem-report callback when one was supplied.
  Future<void> reportProblem(UpdateProblemReport report) async {
    final callback = _onProblemReport;
    if (callback == null) {
      return;
    }
    await callback(report);
  }

  /// Opens the active fresh-install download URL.
  Future<void> openFreshInstallDownload() async {
    final freshInstall = activeFreshInstall;
    if (freshInstall == null) {
      throw StateError("No fresh-install download URL is available.");
    }
    await _externalUrlLauncher(freshInstall.downloadUrl);
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
    _clearReleaseNotesCache();
    _state = const UpdateChecking();
    emitUpdateTelemetry(
      telemetry,
      UpdateTelemetryEvent.checkStarted(source: archiveUrl, channel: channel),
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
        requestHeadersProvider: requestHeadersProvider,
        telemetry: telemetry,
        isMinimumOSSupported: isMinimumOSSupported,
      );
      final result = await client.checkForUpdate();
      if (result == null) {
        _client = null;
        _activeDescriptor = null;
        _activeFreshInstall = null;
        _activeSupportPolicy = null;
        _stagingPath = null;
        _skipUpdate = false;
        _clearReleaseNotesCache();
        _diagnosticsRecorder.record(
          stage: UpdateDiagnosticStage.check,
          level: UpdateDiagnosticLevel.info,
          message: "No update is available.",
        );
        _state = const UpdateIdle();
        notifyListeners();
        return;
      }

      final supportPolicy = result.index.supportPolicy;
      final activeSupportPolicy =
          supportPolicy != null && supportPolicy.appliesTo(currentVersion)
              ? supportPolicy
              : null;
      final supportPolicyEnforced = activeSupportPolicy?.isEnforced(
            currentVersion: currentVersion,
            now: DateTime.now().toUtc(),
          ) ??
          false;
      final freshInstall = result.item.freshInstall;

      if (!result.item.mandatory &&
          !supportPolicyEnforced &&
          await _isSkipped(result.descriptor)) {
        _client = null;
        _activeDescriptor = null;
        _activeFreshInstall = null;
        _activeSupportPolicy = null;
        _stagingPath = null;
        _skipUpdate = true;
        _clearReleaseNotesCache();
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
      _activeFreshInstall = freshInstall;
      _activeSupportPolicy = activeSupportPolicy;
      _stagingPath = null;
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.descriptor,
        level: UpdateDiagnosticLevel.info,
        message: "Update selected: ${result.descriptor.version} "
            "(${result.descriptor.platform}/${result.descriptor.channel}).",
      );
      if (freshInstall != null) {
        _state = UpdateFreshInstallRequired(
          descriptor: result.descriptor,
          freshInstall: freshInstall,
          mandatory: result.item.mandatory || supportPolicyEnforced,
          supportPolicy: activeSupportPolicy,
        );
      } else if (supportPolicyEnforced && activeSupportPolicy != null) {
        _state = UpdateBlockedBySupportPolicy(
          descriptor: result.descriptor,
          supportPolicy: activeSupportPolicy,
        );
      } else {
        _state = UpdateAvailable(
          descriptor: result.descriptor,
          mandatory: result.item.mandatory,
          supportPolicy: activeSupportPolicy,
        );
      }
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
      _state = UpdateFailed(error, report: _reportFromStateOrBuild(error));
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

    if (currentState is UpdateFreshInstallRequired) {
      return ManualUpdateCheckFreshInstallRequired(
        descriptor: currentState.descriptor,
        freshInstall: currentState.freshInstall,
        mandatory: currentState.mandatory,
      );
    }

    if (currentState is UpdateBlockedBySupportPolicy) {
      return ManualUpdateCheckBlockedBySupportPolicy(
        descriptor: currentState.descriptor,
        supportPolicy: currentState.supportPolicy,
      );
    }

    if (currentState is UpdateFailed) {
      return ManualUpdateCheckFailed(currentState.error, StackTrace.current);
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
    if (_state is UpdateFreshInstallRequired) {
      throw StateError("This update must be installed from a fresh download.");
    }
    final mandatory = switch (_state) {
      UpdateAvailable(:final mandatory) ||
      UpdateFreshInstallRequired(:final mandatory) =>
        mandatory,
      UpdateBlockedBySupportPolicy() => true,
      _ => false,
    };

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
      _state = UpdateReadyToInstall(
        stagingPath: result.stagingPath,
        mandatory: mandatory,
      );
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

  @override
  void dispose() {
    _releaseNotesFetcher?.close();
    super.dispose();
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

  void _clearReleaseNotesCache() {
    _cachedReleaseNotes = null;
    _cachedReleaseNotesKey = null;
    _releaseNotesState = const ReleaseNotesIdle();
  }
}

String _releaseNotesCacheKey(ReleaseDescriptor descriptor) {
  return [
    descriptor.packageId,
    descriptor.version,
    descriptor.buildNumber?.toString() ?? "",
    descriptor.platform,
    descriptor.channel,
    descriptor.artifact.url.toString(),
  ].join("|");
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

/// Default desktop URL launcher used by ready-made fresh-install UI.
Future<void> defaultExternalUrlLauncher(Uri url) async {
  final scheme = url.scheme.toLowerCase();
  if (scheme != "http" && scheme != "https") {
    throw ArgumentError.value(url, "url", "Only http(s) URLs can be opened.");
  }

  final urlText = url.toString();
  final executable = switch (Platform.operatingSystem) {
    "macos" => "open",
    "windows" => "rundll32",
    _ => "xdg-open",
  };
  final arguments = switch (Platform.operatingSystem) {
    "windows" => ["url.dll,FileProtocolHandler", urlText],
    _ => [urlText],
  };

  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "${result.stdout}\n${result.stderr}",
      result.exitCode,
    );
  }
}
