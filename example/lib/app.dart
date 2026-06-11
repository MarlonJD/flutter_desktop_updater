import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_widget.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _defaultAppArchiveUrl =
      "https://www.yoursite.com/app-archive.json";

  String _platformVersion = "Unknown";
  String _appVersion = "Unknown app version";
  final _desktopUpdaterPlugin = DesktopUpdater();
  late DesktopUpdaterController _desktopUpdaterController;

  bool get _hostedSmokeEnabled =>
      Platform.environment["DESKTOP_UPDATER_HOSTED_SMOKE"] == "1";

  bool get _hostedSmokeAllowUnsignedMacOS =>
      Platform.environment["DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS"] ==
      "1";

  @override
  void initState() {
    super.initState();
    initPlatformState();
    initAppVersionState();

    _desktopUpdaterController = DesktopUpdaterController(
      appArchiveUrl: _configuredAppArchiveUrl(),
      skipInitialVersionCheck: _hostedSmokeEnabled,
      allowUnsignedMacOSUpdates: _hostedSmokeAllowUnsignedMacOS,
      localization: const DesktopUpdateLocalization(
        updateAvailableText: "Update available",
        newVersionAvailableText: "{} {} is available",
        newVersionLongText:
            "New version is ready to download, click the button below to start downloading. This will download {} MB of data.",
        restartText: "Restart to update",
        warningTitleText: "Are you sure?",
        restartWarningText:
            "A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?",
        warningCancelText: "Not now",
        warningConfirmText: "Restart",
      ),
    );

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

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    String platformVersion;
    // Platform messages may fail, so we use a try/catch PlatformException.
    // We also handle the message potentially returning null.
    try {
      platformVersion = await _desktopUpdaterPlugin.getPlatformVersion() ??
          "Unknown platform version";
    } on PlatformException {
      platformVersion = "Failed to get platform version.";
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
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
      appBar: AppBar(
        title: const Text("Plugin example app"),
      ),
      body: DesktopUpdateWidget(
        controller: _desktopUpdaterController,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            child: Column(
              children: [
                Text("App version: $_appVersion"),
                Text("Running on: $_platformVersion\n"),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
