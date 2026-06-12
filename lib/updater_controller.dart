import "dart:async";

import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/src/current_version.dart";
import "package:desktop_updater/src/localization.dart";
import "package:desktop_updater/src/manual_update_check_result.dart";
import "package:flutter/material.dart";

class DesktopUpdaterController extends ChangeNotifier {
  DesktopUpdaterController({
    required Uri? appArchiveUrl,
    this.localization,
    this.allowUnsignedMacOSUpdates = false,
    bool skipInitialVersionCheck = false,
  }) : _skipInitialVersionCheck = skipInitialVersionCheck {
    if (appArchiveUrl != null) {
      init(appArchiveUrl);
    }
  }

  final bool _skipInitialVersionCheck;
  bool get skipInitialVersionCheck => _skipInitialVersionCheck;

  DesktopUpdateLocalization? localization;
  DesktopUpdateLocalization? get getLocalization => localization;

  /// Allows macOS Release installs to bypass native signing, Gatekeeper,
  /// stapler, and Team ID checks.
  ///
  /// Keep this false for public macOS distribution. When true, macOS still
  /// requires a complete `.app` bundle with the same bundle identifier.
  final bool allowUnsignedMacOSUpdates;

  Uri? _appArchiveUrl;
  Uri? get appArchiveUrl => _appArchiveUrl;

  String? get appName => _activeDescriptor?.appName;
  String? get appVersion => _activeDescriptor?.version;

  bool _skipUpdate = false;
  bool get skipUpdate => _skipUpdate;

  UpdateState _state = const UpdateIdle();
  UpdateState get state => _state;

  ReleaseDescriptor? _activeDescriptor;
  ReleaseDescriptor? get activeDescriptor => _activeDescriptor;

  UpdateClient? _client;
  String? _stagingPath;

  void init(Uri url) {
    _appArchiveUrl = url;
    if (_skipInitialVersionCheck) {
      notifyListeners();
      return;
    }

    unawaited(checkVersion());
    notifyListeners();
  }

  void makeSkipUpdate() {
    _skipUpdate = true;
    notifyListeners();
  }

  Future<void> checkVersion() async {
    final archiveUrl = _appArchiveUrl;
    if (archiveUrl == null) {
      throw StateError("App archive URL is not set.");
    }

    _state = const UpdateChecking();
    notifyListeners();

    try {
      final currentVersion = await currentVersionInfo();
      if (currentVersion == null) {
        throw StateError("Current app version is unavailable.");
      }

      final client = UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: currentVersion,
      );
      final result = await client.checkForUpdate();
      if (result == null) {
        _client = null;
        _activeDescriptor = null;
        _stagingPath = null;
        _state = const UpdateIdle();
        notifyListeners();
        return;
      }

      _client = client;
      _activeDescriptor = result.descriptor;
      _stagingPath = null;
      _state = UpdateAvailable(
        descriptor: result.descriptor,
        mandatory: result.item.mandatory,
      );
      notifyListeners();
    } catch (error) {
      _state = UpdateFailed(error);
      notifyListeners();
      rethrow;
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
      notifyListeners();
      rethrow;
    }
  }

  Future<void> restartApp() async {
    final stagingPath = _stagingPath;
    if (stagingPath == null || stagingPath.isEmpty) {
      throw StateError("No downloaded update is ready to install.");
    }

    _state = const UpdateInstalling();
    notifyListeners();

    await DesktopUpdaterPlatform.instance.installUpdate(
      stagingPath: stagingPath,
      allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
    );
  }
}
