import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// Demonstrates the desktop_updater 2.x zip-first runtime flow.
class HomePage extends StatefulWidget {
  /// Creates the example home page.
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _defaultAppArchiveUrl =
      "https://updates.example.com/app-archive.json";

  final _desktopUpdaterPlugin = DesktopUpdater();
  late final DesktopUpdaterController _desktopUpdaterController;

  String _platformVersion = "Unknown platform version";
  String _appVersion = "Unknown app version";
  String _statusMessage =
      "Ready. Configure DESKTOP_UPDATER_APP_ARCHIVE_URL with a hosted 2.x app-archive.json.";

  bool get _hostedSmokeEnabled =>
      Platform.environment["DESKTOP_UPDATER_HOSTED_SMOKE"] == "1";

  bool get _hostedSmokeAllowUnsignedMacOS =>
      Platform.environment["DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS"] ==
      "1";

  @override
  void initState() {
    super.initState();

    _desktopUpdaterController = DesktopUpdaterController(
      appArchiveUrl: _configuredAppArchiveUrl(),
      skipInitialVersionCheck: true,
      allowUnsignedMacOSUpdates: _hostedSmokeAllowUnsignedMacOS,
      localization: const DesktopUpdateLocalization(
        updateAvailableText: "Update available",
        newVersionAvailableText: "{} {} is available",
        newVersionLongText:
            "The 2.x release descriptor points to one verified zip artifact. Download size: {} MB.",
        restartText: "Install update",
        warningTitleText: "Install staged update?",
        restartWarningText:
            "The app will hand the staged artifact to the platform installer.",
        warningCancelText: "Not now",
        warningConfirmText: "Install",
      ),
    );

    unawaited(initPlatformState());
    unawaited(initAppVersionState());
    unawaited(_runSmokeTestCommand());
    unawaited(_runHostedSmokeTestCommand());
  }

  Uri _configuredAppArchiveUrl() {
    final value = Platform.environment["DESKTOP_UPDATER_APP_ARCHIVE_URL"];
    return Uri.parse(
      value == null || value.trim().isEmpty
          ? _defaultAppArchiveUrl
          : value.trim(),
    );
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _statusMessage = "Checking the 2.x release index...";
    });

    try {
      await _desktopUpdaterController.checkVersion();
      final state = _desktopUpdaterController.state;
      setState(() {
        _statusMessage = switch (state) {
          UpdateAvailable(:final descriptor) =>
            "Update ${descriptor.version} is available for ${descriptor.platform}.",
          UpdateIdle() => "No matching 2.x update was found.",
          UpdateFailed(:final error) => "Update check failed: $error",
          _ => _statusMessage,
        };
      });
    } on Object catch (error) {
      setState(() {
        _statusMessage = "Update check failed: $error";
      });
    }
  }

  Future<void> _downloadUpdate() async {
    setState(() {
      _statusMessage = "Downloading and verifying the zip artifact...";
    });

    try {
      await _desktopUpdaterController.downloadUpdate();
      setState(() {
        _statusMessage = "Update staged and ready to install.";
      });
    } on Object catch (error) {
      setState(() {
        _statusMessage = "Download failed: $error";
      });
    }
  }

  Future<void> _installUpdate() async {
    try {
      await _desktopUpdaterController.restartApp();
    } on Object catch (error) {
      setState(() {
        _statusMessage = "Install failed: $error";
      });
    }
  }

  Future<void> _runSmokeTestCommand() async {
    final stagingPath = Platform.environment["DESKTOP_UPDATER_SMOKE_STAGING"];
    if (stagingPath == null || stagingPath.isEmpty) {
      return;
    }

    final markerPath = Platform.environment["DESKTOP_UPDATER_SMOKE_MARKER"];
    final stagingDirectory = Directory(stagingPath);

    if (!await stagingDirectory.exists()) {
      await _writeSmokeMarker(markerPath, "staging-missing");
      return;
    }

    await _writeSmokeMarker(markerPath, "installing");
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _desktopUpdaterPlugin.installUpdate(stagingPath: stagingPath);
  }

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

  Future<void> _writeSmokeMarker(String? markerPath, String value) async {
    if (markerPath == null || markerPath.isEmpty) {
      return;
    }

    final marker = File(markerPath);
    await marker.parent.create(recursive: true);
    await marker.writeAsString(value);
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion = await _desktopUpdaterPlugin.getPlatformVersion() ??
          "Unknown platform version";
    } on PlatformException {
      platformVersion = "Failed to get platform version.";
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  Future<void> initAppVersionState() async {
    String appVersion;

    try {
      final versionInfo = await _desktopUpdaterPlugin.getCurrentVersionInfo();
      if (versionInfo == null || versionInfo.versionName == null) {
        appVersion = "Unknown app version";
      } else if (versionInfo.buildNumber == null) {
        appVersion = versionInfo.versionName!;
      } else {
        appVersion = "${versionInfo.versionName!}+${versionInfo.buildNumber}";
      }
    } on PlatformException {
      appVersion = "Failed to get app version.";
    }

    if (!mounted) return;

    setState(() {
      _appVersion = appVersion;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("desktop_updater 2.x demo")),
      body: Stack(
        children: [
          ListenableBuilder(
            listenable: _desktopUpdaterController,
            builder: (context, _) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ContractCard(
                          appArchiveUrl: _desktopUpdaterController.appArchiveUrl
                              .toString(),
                          appVersion: _appVersion,
                          platformVersion: _platformVersion,
                        ),
                        const SizedBox(height: 12),
                        _StateCard(
                          state: _desktopUpdaterController.state,
                          statusMessage: _statusMessage,
                          controller: _desktopUpdaterController,
                          onCheck: _checkForUpdates,
                          onDownload: _downloadUpdate,
                          onInstall: _installUpdate,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          UpdateDialogListener(controller: _desktopUpdaterController),
        ],
      ),
    );
  }
}

class _ContractCard extends StatelessWidget {
  const _ContractCard({
    required this.appArchiveUrl,
    required this.appVersion,
    required this.platformVersion,
  });

  final String appArchiveUrl;
  final String appVersion;
  final String platformVersion;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "app-archive.json -> release.json -> zip",
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              "This example uses the 2.x zip-first contract. The app checks an index, downloads the selected release descriptor, verifies the exact artifact, then stages it for the platform installer.",
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _InfoRow(label: "App archive:", value: appArchiveUrl),
            _InfoRow(label: "App version:", value: appVersion),
            _InfoRow(label: "Running on:", value: platformVersion),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  "Set DESKTOP_UPDATER_APP_ARCHIVE_URL to point this demo at your hosted 2.x app-archive.json.",
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.state,
    required this.statusMessage,
    required this.controller,
    required this.onCheck,
    required this.onDownload,
    required this.onInstall,
  });

  final UpdateState state;
  final String statusMessage;
  final DesktopUpdaterController controller;
  final Future<void> Function() onCheck;
  final Future<void> Function() onDownload;
  final Future<void> Function() onInstall;

  @override
  Widget build(BuildContext context) {
    final canDownload = state is UpdateAvailable;
    final canInstall = state is UpdateReadyToInstall;
    final checking = state is UpdateChecking;
    final downloading = state is UpdateDownloading;

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Update state",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(statusMessage),
            const SizedBox(height: 12),
            Text("State: ${_stateLabel(state)}"),
            if (downloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: controller.downloadProgress),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: checking || downloading ? null : onCheck,
                  child: const Text("Check for updates"),
                ),
                OutlinedButton(
                  onPressed: canDownload && !downloading ? onDownload : null,
                  child: const Text("Download update"),
                ),
                OutlinedButton(
                  onPressed: canInstall ? onInstall : null,
                  child: const Text("Install staged update"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _stateLabel(UpdateState state) {
    return switch (state) {
      UpdateIdle() => "idle",
      UpdateChecking() => "checking",
      UpdateAvailable(:final descriptor) =>
        "available ${descriptor.version} (${descriptor.platform})",
      UpdateDownloading(:final receivedBytes, :final totalBytes) =>
        "downloading $receivedBytes / $totalBytes bytes",
      UpdateReadyToInstall(:final stagingPath) => "ready at $stagingPath",
      UpdateInstalling() => "installing",
      UpdateFailed(:final error) => "failed: $error",
    };
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
