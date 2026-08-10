import "dart:async";
import "dart:io";
import "dart:math";

import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/core/release_notes.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
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
import "package:path/path.dart" as path;

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
    required String expectedPackageId,
    required UpdateRecoveryStore recoveryStore,
    required Map<String, String> trustedReleasePublicKeys,
    DesktopUpdateLocalization? localization,
    this.channel = "stable",
    this.installationIdentity,
    this.preferences,
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
  })  : expectedPackageId =
            _normalizeControllerExpectedPackageId(expectedPackageId),
        recoveryStore = recoveryStore,
        trustedReleasePublicKeys =
            normalizeReleasePublicKeys(trustedReleasePublicKeys),
        _isWindows = Platform.isWindows,
        _localization = localization,
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
    required String expectedPackageId,
    required UpdateRecoveryStore recoveryStore,
    required Map<String, String> trustedReleasePublicKeys,
    DesktopUpdateLocalization? localization,
    this.channel = "stable",
    this.installationIdentity,
    this.preferences,
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
    bool? isWindows,
  })  : expectedPackageId =
            _normalizeControllerExpectedPackageId(expectedPackageId),
        recoveryStore = recoveryStore,
        trustedReleasePublicKeys =
            normalizeReleasePublicKeys(trustedReleasePublicKeys),
        _isWindows = isWindows ?? Platform.isWindows,
        _localization = localization,
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
  final bool _isWindows;

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

  /// App-owned expected package identity for signed metadata and install.
  final String expectedPackageId;

  /// App-owned durable persistence adapter for pending install recovery.
  final UpdateRecoveryStore recoveryStore;

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

  /// Pinned Ed25519 public keys required for app archive and descriptor trust.
  final Map<String, String> trustedReleasePublicKeys;

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
  UpdateCheckResult? _activeCheckResult;
  UpdateStageResult? _activeStageResult;
  String? _stagingPath;
  StagedUpdateProvenance? _stageProvenance;
  String? _stageProvenanceSha256;
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
        expectedPackageId: expectedPackageId,
        trustedReleasePublicKeys: trustedReleasePublicKeys,
        channel: channel,
        installationIdentity: installationIdentity,
        requestHeadersProvider: requestHeadersProvider,
        telemetry: telemetry,
        isMinimumOSSupported: isMinimumOSSupported,
      );
      final result = await client.checkForUpdate();
      if (result == null) {
        _client = null;
        _activeCheckResult = null;
        _activeStageResult = null;
        _activeDescriptor = null;
        _activeFreshInstall = null;
        _activeSupportPolicy = null;
        _stagingPath = null;
        _stageProvenance = null;
        _stageProvenanceSha256 = null;
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
        _activeCheckResult = null;
        _activeStageResult = null;
        _activeDescriptor = null;
        _activeFreshInstall = null;
        _activeSupportPolicy = null;
        _stagingPath = null;
        _stageProvenance = null;
        _stageProvenanceSha256 = null;
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
      _activeCheckResult = result;
      _activeStageResult = null;
      _activeDescriptor = result.descriptor;
      _activeFreshInstall = freshInstall;
      _activeSupportPolicy = activeSupportPolicy;
      _stagingPath = null;
      _stageProvenance = null;
      _stageProvenanceSha256 = null;
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
    if (_state is UpdateFailed || _state is UpdateInstalling) {
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
    final checkResult = _activeCheckResult;
    if (descriptor == null || client == null || checkResult == null) {
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
    _activeStageResult = null;
    _stageProvenance = null;
    _stageProvenanceSha256 = null;
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
        artifactKind: descriptor.artifact.kind,
        installStrategy: descriptor.install.strategy,
      ),
    );
    notifyListeners();

    try {
      final result = await client.downloadVerifyAndStage(
        checkResult: checkResult,
        onProgress: (receivedBytes, totalBytes) {
          _state = UpdateDownloading(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes ?? descriptor.artifact.length,
          );
          notifyListeners();
        },
      );

      _stagingPath = result.stagingPath;
      _activeStageResult = result;
      _stageProvenance = result.stageProvenance;
      _stageProvenanceSha256 = result.stageProvenanceSha256;
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
          artifactKind: descriptor.artifact.kind,
          installStrategy: descriptor.install.strategy,
          error: error,
        ),
      );
      notifyListeners();
      rethrow;
    }
  }

  /// Opens macOS Background Items settings for privileged helper approval.
  Future<void> openMacOSBackgroundItemsSettings() {
    return DesktopUpdaterPlatform.instance.openMacOSBackgroundItemsSettings();
  }

  /// Hands the staged update to the native installer or restart helper.
  Future<void> restartApp() async {
    final stagingPath = _stagingPath;
    final stageResult = _activeStageResult;
    final provenance = _stageProvenance;
    final provenanceSha256 = _stageProvenanceSha256;
    final client = _client;
    if (stagingPath == null ||
        stagingPath.isEmpty ||
        stageResult == null ||
        provenance == null ||
        provenanceSha256 == null ||
        client == null) {
      throw StateError("No downloaded update is ready to install.");
    }

    _state = const UpdateInstalling();
    _diagnosticsRecorder.record(
      stage: UpdateDiagnosticStage.install,
      level: UpdateDiagnosticLevel.info,
      message: "Install handoff started for $stagingPath",
    );
    _diagnosticsRecorder.record(
      stage: UpdateDiagnosticStage.install,
      level: UpdateDiagnosticLevel.info,
      message: "Relaunch attempt scheduled.",
    );
    emitUpdateTelemetry(
      telemetry,
      UpdateTelemetryEvent.installScheduled(
        stagingPath: stagingPath,
        version: _activeDescriptor?.version,
        channel: _activeDescriptor?.channel,
        platform: _activeDescriptor?.platform,
        artifactKind: _activeDescriptor?.artifact.kind,
        installStrategy: _activeDescriptor?.install.strategy,
      ),
    );
    notifyListeners();

    var dispatchAttempted = false;
    try {
      _validateNativeInstallTrust();
      final candidateTransactionId = _createInstallTransactionId();
      final receipt = await _writePendingRecoveryMarker(
        stagingPath,
        candidateTransactionId,
      );
      // Once the durable receipt exists, every failure from the dispatch
      // boundary is ambiguous to the app. Keep the marker until authenticated
      // recovery proves absence or terminal completion.
      dispatchAttempted = true;
      await dispatchVerifiedInstall(
        session: client,
        stageResult: stageResult,
        persistedTransaction: receipt,
      );
      final cleanupReport = _buildCleanupReport(
        stagingPath: stagingPath,
        cleanupAttempted: false,
      );
      _recordCleanupReport(cleanupReport);
      _state = UpdateInstalling(cleanupReport: cleanupReport);
      notifyListeners();
    } on Object catch (error) {
      if (!dispatchAttempted) {
        await _clearPendingRecoveryMarker();
      }
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
          artifactKind: _activeDescriptor?.artifact.kind,
          installStrategy: _activeDescriptor?.install.strategy,
          error: error,
        ),
      );
      notifyListeners();
      rethrow;
    }
  }

  void _validateNativeInstallTrust() {
    final signature = _activeDescriptor?.signature;
    if (signature == null ||
        signature.algorithm != "ed25519" ||
        signature.publicKeyId.trim().isEmpty ||
        signature.value.trim().isEmpty) {
      throw StateError(
        "Native install handoff requires a signed release.json "
        "descriptor using Ed25519.",
      );
    }
  }

  /// Recovers a pending native install marker from the app-owned store.
  Future<void> recoverPendingInstall() async {
    final UpdateInstallRecoveryMarker? marker;
    try {
      marker = await recoveryStore.readPendingInstall(channel: channel);
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
    _diagnosticsRecorder.record(
      stage: UpdateDiagnosticStage.install,
      level: UpdateDiagnosticLevel.info,
      message: "Recovery started for pending install.",
    );

    final transactionId = marker.transactionId;
    if (transactionId != null && transactionId.isNotEmpty) {
      final NativeInstallTransactionStatus? nativeStatus;
      try {
        final recovery = DesktopUpdaterPlatform.instance.nativeInstallRecovery;
        if (_isWindows) {
          if (recovery is! AtomicAfterExitNativeInstallRecovery) {
            throw StateError(
              "Windows native recovery must be atomic after caller exit.",
            );
          }
          nativeStatus = await recovery
              .resolvePendingInstallTransactionAfterExit(transactionId);
        } else {
          if (recovery is! QueryAndRecoverNativeInstallRecovery) {
            throw StateError(
              "This platform must expose query/recover native recovery.",
            );
          }
          var status = await recovery.queryInstallTransaction(transactionId);
          if (status?.requiresRecovery ?? false) {
            const maximumRecoveryAttempts = 6;
            var attempts = 0;
            do {
              status = await recovery
                  .recoverPendingInstallTransaction(transactionId);
              attempts += 1;
            } while ((status?.awaitsCallerExit ?? false) &&
                attempts < maximumRecoveryAttempts);
          }
          nativeStatus = status;
        }
      } on Object catch (error) {
        _failRecoveredInstall(
          marker,
          StateError("Could not verify native install transaction status."),
          message: "Could not verify native install transaction status.",
          appVersion: marker.appVersion,
          error: error,
        );
        return;
      }

      // A custom released platform implementation has no native recovery
      // lookup surface, so preserve its existing version-only behavior.
      if (nativeStatus?.awaitsCallerExit ?? false) {
        _state = const UpdateInstalling();
        notifyListeners();
        return;
      }
      if (nativeStatus != null && !nativeStatus.isTerminalSuccess) {
        if (nativeStatus.isTerminalFailure) {
          final cleaned = await _cleanupRecoveredOwnedStage(marker);
          if (cleaned) {
            await _clearPendingRecoveryMarker();
          }
        }
        _failRecoveredInstall(
          marker,
          StateError("Native helper did not confirm a completed install."),
          message: "Native helper did not confirm a completed install.",
          appVersion: marker.appVersion,
        );
        return;
      }
    }

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
      if (!await _cleanupRecoveredOwnedStage(marker)) {
        _failRecoveredInstall(
          marker,
          StateError("Completed install stage cleanup failed."),
          message: "Completed install stage cleanup failed.",
          appVersion: _currentAppVersion,
        );
        return;
      }
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

  Future<PersistedInstallTransaction> _writePendingRecoveryMarker(
    String stagingPath,
    String? transactionId,
  ) async {
    final descriptor = _activeDescriptor;
    if (descriptor == null || transactionId == null) {
      throw StateError("No active descriptor or transaction is available.");
    }
    final marker = UpdateInstallRecoveryMarker.pendingV3(
      createdAt: DateTime.now(),
      packageVersion: _diagnosticsRecorder.packageVersion,
      platform: _diagnosticsRecorder.platform,
      channel: channel,
      appVersion: _currentAppVersion,
      updateVersion: descriptor.version,
      updateBuildNumber: descriptor.buildNumber,
      expectedPackageId: expectedPackageId,
      stagingPath: stagingPath,
      stageProvenanceSha256: _stageProvenanceSha256!,
      diagnosticsText: _buildProblemReport(
        StateError("Install handoff pending."),
        updateVersion: descriptor.version,
        stagingPath: stagingPath,
      ).toPlainText(),
      transactionId: transactionId,
    );

    try {
      await recoveryStore.writePendingInstall(marker);
      final readback = await recoveryStore.readPendingInstall(channel: channel);
      return persistedInstallTransactionFromExactReadback(
        written: marker,
        readback: readback,
      );
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.error,
        message: "Recovery marker write/readback failed.",
        error: error,
      );
      rethrow;
    }
  }

  String _createInstallTransactionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, "0")).join();
    return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-"
        "${hex.substring(12, 16)}-${hex.substring(16, 20)}-"
        "${hex.substring(20)}";
  }

  Future<void> _clearPendingRecoveryMarker() async {
    try {
      await recoveryStore.clearPendingInstall(channel: channel);
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.info,
        message: "Recovery marker cleared.",
      );
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.warning,
        message: "Recovery marker clear failed.",
        error: error,
      );
    }
  }

  Future<bool> _cleanupRecoveredOwnedStage(
    UpdateInstallRecoveryMarker marker,
  ) async {
    final stagingPath = marker.stagingPath;
    if (stagingPath == null || stagingPath.isEmpty) {
      return true;
    }
    var stageRoot = Directory(stagingPath);
    if (!path.basename(stageRoot.path).startsWith(
          desktopUpdaterStagingPrefix,
        )) {
      stageRoot = stageRoot.parent;
    }
    final stageName = path.basename(stageRoot.path);
    if (!stageName.startsWith(desktopUpdaterStagingPrefix)) {
      return true;
    }
    if (await FileSystemEntity.type(
          stageRoot.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound) {
      return true;
    }
    final nonce = stageName.substring(desktopUpdaterStagingPrefix.length);
    try {
      await deleteOwnedStagingDirectory(
        parent: stageRoot.parent,
        stageRoot: stageRoot,
        nonce: nonce,
      );
      _recordCleanupReport(
        _buildCleanupReport(
          stagingPath: stagingPath,
          cleanupAttempted: true,
          cleanupSucceeded: true,
        ),
      );
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.cleanup,
        level: UpdateDiagnosticLevel.info,
        message: "Recovered install stage cleanup succeeded.",
      );
      return true;
    } on Object catch (error) {
      _diagnosticsRecorder.record(
        stage: UpdateDiagnosticStage.install,
        level: UpdateDiagnosticLevel.warning,
        message: "Recovered install stage cleanup failed.",
        error: error,
      );
      _recordCleanupReport(
        _buildCleanupReport(
          stagingPath: stagingPath,
          cleanupAttempted: true,
          cleanupSucceeded: false,
          errorText: error.toString(),
        ),
      );
      return false;
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

String _normalizeControllerExpectedPackageId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      value,
      "expectedPackageId",
      "must not be blank",
    );
  }
  return normalized;
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
