import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/version_check.dart";
import "package:flutter/material.dart";

class DesktopUpdaterController extends ChangeNotifier {
  DesktopUpdaterController({
    required Uri? appArchiveUrl,
    this.localization,
    this.allowUnsignedMacOSUpdates = false,
    bool skipInitialVersionCheck = false,
    @Deprecated("Use skipInitialVersionCheck instead.") bool? skipCheckVersion,
  }) : _skipInitialVersionCheck = skipCheckVersion ?? skipInitialVersionCheck {
    if (appArchiveUrl != null) {
      init(appArchiveUrl);
    }
  }

  final bool _skipInitialVersionCheck;
  bool get skipInitialVersionCheck => _skipInitialVersionCheck;

  @Deprecated("Use skipInitialVersionCheck instead.")
  bool get getSkipCheckVersion => _skipInitialVersionCheck;

  DesktopUpdateLocalization? localization;
  DesktopUpdateLocalization? get getLocalization => localization;

  /// Allows macOS Release installs to bypass native signing, Gatekeeper,
  /// stapler, and Team ID checks.
  ///
  /// Keep this false for public macOS distribution. When true, macOS still
  /// requires a complete `.app` bundle with the same bundle identifier.
  final bool allowUnsignedMacOSUpdates;

  String? _appName;
  String? get appName => _appName;

  String? _appVersion;
  String? get appVersion => _appVersion;

  Uri? _appArchiveUrl;
  Uri? get appArchiveUrl => _appArchiveUrl;

  bool _needUpdate = false;
  bool get needUpdate =>
      state is UpdateAvailable ||
      state is UpdateDownloading ||
      state is UpdateReadyToInstall ||
      _needUpdate;

  bool _isMandatory = false;
  bool get isMandatory {
    final currentState = state;
    if (currentState is UpdateAvailable) {
      return currentState.mandatory;
    }
    return _isMandatory;
  }

  String? _folderUrl;

  UpdateProgress? _updateProgress;
  UpdateProgress? get updateProgress => _updateProgress;

  bool _isDownloading = false;
  bool get isDownloading => state is UpdateDownloading || _isDownloading;

  bool _isDownloaded = false;
  bool get isDownloaded => state is UpdateReadyToInstall || _isDownloaded;

  double _downloadProgress = 0;
  double get downloadProgress {
    final currentState = state;
    if (currentState is UpdateDownloading) {
      if (currentState.totalBytes <= 0) {
        return 0;
      }
      return currentState.receivedBytes / currentState.totalBytes;
    }
    if (currentState is UpdateReadyToInstall) {
      return 1;
    }
    return _downloadProgress;
  }

  double _downloadSize = 0;
  double? get downloadSize => _downloadSize;

  double _downloadedSize = 0;
  double get downloadedSize => _downloadedSize;

  List<FileHashModel?>? _changedFiles;
  List<String> _removedFiles = const [];
  String? _stagingPath;
  String _manifestPath = "release-manifest.json";

  List<ChangeModel?>? _releaseNotes;
  List<ChangeModel?>? get releaseNotes => _releaseNotes;

  bool _skipUpdate = false;
  bool get skipUpdate => _skipUpdate;

  UpdateState _state = const UpdateIdle();
  UpdateState get state => _state;

  UpdateClient? _zipFirstClient;
  ReleaseDescriptor? _zipFirstDescriptor;

  final _plugin = DesktopUpdater();

  void init(Uri url) {
    _appArchiveUrl = url;
    if (_skipInitialVersionCheck) {
      notifyListeners();
      return;
    }

    checkVersion();
    notifyListeners();
  }

  void makeSkipUpdate() {
    _skipUpdate = true;
    print("Skip update: $_skipUpdate");
    notifyListeners();
  }

  Future<void> checkVersion() async {
    if (_appArchiveUrl == null) {
      throw Exception("App archive URL is not set");
    }

    _state = const UpdateChecking();
    notifyListeners();

    final zipFirstHandled = await _checkZipFirstVersion();
    if (zipFirstHandled) {
      return;
    }

    final versionResponse = await _plugin.versionCheck(
      appArchiveUrl: appArchiveUrl.toString(),
    );

    if (versionResponse?.url != null) {
      print("Found folder url: ${versionResponse?.url}");

      _needUpdate = true;
      _folderUrl = versionResponse?.url;
      _isMandatory = versionResponse?.mandatory ?? false;

      // Calculate total length in bytes.
      _downloadSize = (versionResponse?.changedFiles?.fold<double>(
            0,
            (previousValue, element) => previousValue + (element?.length ?? 0),
          )) ??
          0.0;

      _changedFiles = versionResponse?.changedFiles;
      _removedFiles = versionResponse?.removedFiles ?? const [];
      _manifestPath = versionResponse?.manifestPath ?? "release-manifest.json";
      _releaseNotes = versionResponse?.changes;
      _appName = versionResponse?.appName;
      _appVersion = versionResponse?.version;
      _state = UpdateAvailable(
        descriptor: ReleaseDescriptor(
          schemaVersion: 3,
          packageId: "",
          appName: _appName ?? "",
          version: _appVersion ?? "",
          buildNumber: 0,
          platform: "",
          channel: "legacy",
          artifact: ReleaseArtifact(
            kind: "zip",
            url: Uri.parse("file:///legacy-folder-update.zip"),
            sha256:
                "0000000000000000000000000000000000000000000000000000000000000000",
            length: 0,
          ),
          install: const ReleaseInstall(strategy: "legacyFolderReplace"),
          minimumUpdaterVersion: "1.0.0",
          generatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
        mandatory: _isMandatory,
      );

      print("Need update: $_needUpdate");

      notifyListeners();
    } else {
      _state = const UpdateIdle();
      notifyListeners();
    }
  }

  Future<void> downloadUpdate() async {
    final zipFirstDescriptor = _zipFirstDescriptor;
    final zipFirstClient = _zipFirstClient;
    if (zipFirstDescriptor != null && zipFirstClient != null) {
      await _downloadZipFirstUpdate(zipFirstClient, zipFirstDescriptor);
      return;
    }

    if (_folderUrl == null) {
      throw Exception("Folder URL is not set");
    }

    if (_changedFiles == null) {
      throw Exception("Changed files are not set");
    }

    _isDownloading = true;
    _isDownloaded = false;
    _downloadProgress = 0;
    _downloadedSize = 0;
    _stagingPath = null;
    notifyListeners();

    final stream = await _plugin.updateApp(
      remoteUpdateFolder: _folderUrl!,
      changedFiles: _changedFiles ?? [],
      manifestPath: _manifestPath,
    );

    try {
      await for (final event in stream) {
        _updateProgress = event;
        _stagingPath = event.stagingDirectory ?? _stagingPath;
        _isDownloading = true;
        _isDownloaded = false;
        _downloadProgress = event.fraction;
        _downloadedSize = event.receivedBytes;
        notifyListeners();
      }

      _isDownloading = false;
      _downloadProgress = 1.0;
      _downloadedSize = _downloadSize;
      _isDownloaded = true;
      notifyListeners();
    } catch (_) {
      _isDownloading = false;
      _isDownloaded = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> restartApp() async {
    final stagingPath = _stagingPath;
    if (stagingPath == null || stagingPath.isEmpty) {
      throw StateError("No downloaded update is ready to install");
    }

    _state = const UpdateInstalling();
    notifyListeners();

    await _plugin.installUpdate(
      stagingPath: stagingPath,
      removedFiles: _removedFiles,
      allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
    );
  }

  Future<bool> _checkZipFirstVersion() async {
    final currentVersion = await currentVersionInfo();
    if (currentVersion == null) {
      return false;
    }

    final client = UpdateClient(
      appArchiveUrl: _appArchiveUrl!,
      currentVersion: currentVersion,
    );

    try {
      final result = await client.checkForUpdate();
      if (result == null) {
        _zipFirstClient = null;
        _zipFirstDescriptor = null;
        _state = const UpdateIdle();
        notifyListeners();
        return true;
      }

      _zipFirstClient = client;
      _zipFirstDescriptor = result.descriptor;
      _needUpdate = true;
      _folderUrl = null;
      _isMandatory = result.item.mandatory;
      _downloadSize = result.descriptor.artifact.length.toDouble();
      _changedFiles = null;
      _removedFiles = const [];
      _releaseNotes = const [];
      _appName = result.descriptor.appName;
      _appVersion = result.descriptor.version;
      _state = UpdateAvailable(
        descriptor: result.descriptor,
        mandatory: result.item.mandatory,
      );
      notifyListeners();
      return true;
    } on LegacyReleaseIndexException {
      _state = const UpdateIdle();
      return false;
    } catch (error) {
      _state = UpdateFailed(error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _downloadZipFirstUpdate(
    UpdateClient client,
    ReleaseDescriptor descriptor,
  ) async {
    _isDownloading = true;
    _isDownloaded = false;
    _downloadProgress = 0;
    _downloadedSize = 0;
    _stagingPath = null;
    _state = const UpdateDownloading(receivedBytes: 0, totalBytes: 0);
    notifyListeners();

    try {
      final result = await client.downloadVerifyAndStage(
        descriptor: descriptor,
        onProgress: (receivedBytes, totalBytes) {
          final total = totalBytes ?? descriptor.artifact.length;
          _downloadedSize = receivedBytes.toDouble();
          _downloadProgress = total <= 0 ? 0 : receivedBytes / total;
          _state = UpdateDownloading(
            receivedBytes: receivedBytes,
            totalBytes: total,
          );
          notifyListeners();
        },
      );

      _stagingPath = result.stagingPath;
      _isDownloading = false;
      _isDownloaded = true;
      _downloadProgress = 1;
      _downloadedSize = descriptor.artifact.length.toDouble();
      _state = UpdateReadyToInstall(stagingPath: result.stagingPath);
      notifyListeners();
    } catch (error) {
      _isDownloading = false;
      _isDownloaded = false;
      _state = UpdateFailed(error);
      notifyListeners();
      rethrow;
    }
  }
}
