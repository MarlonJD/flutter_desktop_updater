import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater_example/release_notes_examples.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

String? _customTooltip(Object error) {
  if (error is SocketException) return "No internet connection.";
  if (error is TimeoutException) return "Connection timed out.";
  return null;
}

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
  static const _defaultReleaseNotesUrl =
      "https://updates.example.com/release-notes.json";

  final _desktopUpdaterPlugin = DesktopUpdater();
  late final DesktopUpdaterController _desktopUpdaterController;

  String _platformVersion = "Unknown platform version";
  String _appVersion = "Unknown app version";
  String _statusMessage =
      "Ready. Configure DESKTOP_UPDATER_APP_ARCHIVE_URL with a hosted 2.x app-archive.json.";
  bool _checkingForUpdates = false;

  bool get _hostedSmokeEnabled =>
      Platform.environment["DESKTOP_UPDATER_HOSTED_SMOKE"] == "1";

  bool get _hostedSmokeAllowUnsignedMacOS =>
      Platform.environment["DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS"] ==
      "1";

  bool get _directSmokeAllowUnsignedMacOS =>
      Platform.environment["DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS"] == "1";

  @override
  void initState() {
    super.initState();

    _desktopUpdaterController = DesktopUpdaterController(
      appArchiveUrl: _configuredAppArchiveUrl(),
      releaseNotesUrl: _configuredReleaseNotesUrl(),
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
        upToDateTitleText: "Application is up to date",
        upToDateText: "{} is the latest hosted version.",
        updateCheckFailedTitleText: "Could not check for updates",
        updateCheckFailedText: "Check the archive URL and try again.",
        onUpdateFailedTooltip: _customTooltip,
        releaseNotesTitleText: "What's new",
        releaseNotesTypeLabels: {
          "feat": "New features",
          "fix": "Bug fixes",
          "other": "Other changes",
        },
        releaseNotesErrorText: "Could not load release notes.",
        releaseNotesRetryText: "Retry",
        releaseNotesEmptyText: "No release notes available for this version.",
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

  Uri? _configuredReleaseNotesUrl() {
    final value = Platform.environment["DESKTOP_UPDATER_RELEASE_NOTES_URL"];
    if (value == null || value.trim().isEmpty) {
      return Uri.parse(_defaultReleaseNotesUrl);
    }
    return Uri.parse(value.trim());
  }

  Future<void> _checkForUpdatesManually() async {
    if (_checkingForUpdates) {
      return;
    }

    setState(() {
      _checkingForUpdates = true;
      _statusMessage = "Checking the 2.x release index...";
    });

    try {
      final result = await _desktopUpdaterController.checkForUpdates();
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = switch (result) {
          ManualUpdateCheckAvailable(:final descriptor) =>
            "Update ${descriptor.version} is available for ${descriptor.platform}.",
          ManualUpdateCheckFreshInstallRequired(:final descriptor) =>
            "Update ${descriptor.version} requires a fresh download.",
          ManualUpdateCheckBlockedBySupportPolicy(:final descriptor) =>
            "This version is no longer supported. Update ${descriptor.version} is required.",
          ManualUpdateCheckUpToDate() => "No matching 2.x update was found.",
          ManualUpdateCheckFailed(:final error) =>
            "Update check failed: $error",
        };
      });

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
    final diagnosticsLogPath =
        Platform.environment["DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"];
    final stagingDirectory = Directory(stagingPath);

    if (!await stagingDirectory.exists()) {
      await _writeSmokeMarker(markerPath, "staging-missing");
      return;
    }

    await _writeSmokeMarker(markerPath, "installing");
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _desktopUpdaterPlugin.installUpdate(
      stagingPath: stagingPath,
      allowUnsignedMacOSUpdates: _directSmokeAllowUnsignedMacOS,
      diagnosticsLogPath: diagnosticsLogPath,
    );
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

      if (_desktopUpdaterController.state is! UpdateAvailable) {
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
                        DesktopUpdaterInheritedNotifier(
                          controller: _desktopUpdaterController,
                          child: const _CustomUpdateBanner(),
                        ),
                        const SizedBox(height: 12),
                        DesktopUpdateDirectCard(
                          controller: _desktopUpdaterController,
                        ),
                        const SizedBox(height: 12),
                        InlineReleaseNotesPanel(
                          controller: _desktopUpdaterController,
                        ),
                        const SizedBox(height: 12),
                        _StateCard(
                          state: _desktopUpdaterController.state,
                          statusMessage: _statusMessage,
                          checkingForUpdates: _checkingForUpdates,
                          onCheck: _checkForUpdatesManually,
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

class _CustomUpdateBanner extends StatelessWidget {
  const _CustomUpdateBanner();

  @override
  Widget build(BuildContext context) {
    final notifier = DesktopUpdaterInheritedNotifier.of(context).notifier!;
    final state = notifier.state;

    return switch (state) {
      UpdateAvailable(:final mandatory) => Card.outlined(
          child: ListTile(
            leading: const Icon(Icons.system_update),
            title: Text(
              mandatory ? "Required update available" : "Update available",
            ),
            subtitle: Text("${notifier.appName} ${notifier.appVersion}"),
            trailing: Wrap(
              spacing: 8,
              children: [
                if (!mandatory)
                  OutlinedButton(
                    onPressed: notifier.makeSkipUpdate,
                    child: const Text("Skip this version"),
                  ),
                FilledButton(
                  onPressed: notifier.downloadUpdate,
                  child: const Text("Download"),
                ),
              ],
            ),
          ),
        ),
      UpdateFreshInstallRequired(:final freshInstall, :final mandatory) =>
        Card.outlined(
          child: ListTile(
            leading: const Icon(Icons.download_for_offline),
            title: Text(
              mandatory
                  ? "Fresh download required"
                  : "Fresh download available",
            ),
            subtitle: Text(
              freshInstall.message ??
                  "This update must be installed from a fresh download.",
            ),
            trailing: FilledButton(
              onPressed: notifier.openFreshInstallDownload,
              child: const Text("Download latest"),
            ),
          ),
        ),
      UpdateBlockedBySupportPolicy() => Card.outlined(
          child: ListTile(
            leading: const Icon(Icons.lock_clock),
            title: const Text("Update required"),
            subtitle: const Text(
              "This version is no longer supported. Update to continue.",
            ),
            trailing: FilledButton(
              onPressed: notifier.downloadUpdate,
              child: const Text("Download"),
            ),
          ),
        ),
      UpdateDownloading(:final receivedBytes, :final totalBytes) =>
        Card.outlined(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Downloading update"),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: totalBytes <= 0 ? null : receivedBytes / totalBytes,
                ),
              ],
            ),
          ),
        ),
      UpdateReadyToInstall() => Card.outlined(
          child: ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text("Update ready to install"),
            trailing: FilledButton(
              onPressed: notifier.restartApp,
              child: const Text("Install"),
            ),
          ),
        ),
      _ => const SizedBox.shrink(),
    };
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Set DESKTOP_UPDATER_APP_ARCHIVE_URL to point this demo at your hosted 2.x app-archive.json.",
                    ),
                    SizedBox(height: 6),
                    Text(
                      "Set DESKTOP_UPDATER_RELEASE_NOTES_URL to a JSON array endpoint "
                      "({\"data\":[{\"type\":\"feat\",\"message\":\"...\"}]}) to enable the release notes icon.",
                    ),
                  ],
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
    required this.checkingForUpdates,
    required this.onCheck,
    required this.onDownload,
    required this.onInstall,
  });

  final UpdateState state;
  final String statusMessage;
  final bool checkingForUpdates;
  final Future<void> Function() onCheck;
  final Future<void> Function() onDownload;
  final Future<void> Function() onInstall;

  @override
  Widget build(BuildContext context) {
    final currentState = state;
    final canDownload = currentState is UpdateAvailable ||
        currentState is UpdateBlockedBySupportPolicy;
    final canInstall = currentState is UpdateReadyToInstall;
    final checking = checkingForUpdates || currentState is UpdateChecking;
    final downloading = currentState is UpdateDownloading;
    final progress =
        currentState is UpdateDownloading && currentState.totalBytes > 0
            ? currentState.receivedBytes / currentState.totalBytes
            : null;

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
            Text("State: ${_stateLabel(currentState)}"),
            if (downloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: checking || downloading ? null : onCheck,
                  icon: checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update),
                  label: Text(checking ? "Checking..." : "Check for updates"),
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
      UpdateFreshInstallRequired(:final descriptor, :final mandatory) =>
        "fresh install required ${descriptor.version}"
            "${mandatory ? " (mandatory)" : ""}",
      UpdateBlockedBySupportPolicy(:final descriptor, :final supportPolicy) =>
        "blocked; update to ${descriptor.version}"
            " before ${supportPolicy.enforcedAfter.toIso8601String()}",
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
