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
  String _platformVersion = "Unknown";
  final _desktopUpdaterPlugin = DesktopUpdater();
  late DesktopUpdaterController _desktopUpdaterController;

  @override
  void initState() {
    super.initState();
    initPlatformState();

    _desktopUpdaterController = DesktopUpdaterController(
      appArchiveUrl: Uri.parse(
        "https://www.yoursite.com/app-archive.json",
      ),
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
                const Text(
                  "Running on: 1.0.0+1",
                ),
                Text("Running on: $_platformVersion\n"),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
