import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;
import "package:plugin_platform_interface/plugin_platform_interface.dart";

class MockDesktopUpdaterPlatform
    with MockPlatformInterfaceMixin
    implements DesktopUpdaterPlatform {
  String? lastDiagnosticsLogPath;
  bool? lastReplaceExisting;
  MacOSInstallLocationStatus macOSInstallLocationStatus =
      const MacOSInstallLocationStatus(
    kind: MacOSInstallLocationKind.unsupported,
    bundlePath: null,
    targetPath: null,
  );

  @override
  Future<String?> getPlatformVersion() => Future.value("42");

  @override
  Future<void> restartApp() {
    return Future.value();
  }

  @override
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
    bool allowUnsignedMacOSUpdates = false,
    String? diagnosticsLogPath,
  }) {
    lastDiagnosticsLogPath = diagnosticsLogPath;
    return Future.value();
  }

  @override
  Future<String?> getExecutablePath() {
    return Future.value();
  }

  @override
  Future<String?> getCurrentVersion() {
    return Future.value();
  }

  @override
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() {
    return Future.value(macOSInstallLocationStatus);
  }

  @override
  Future<void> moveMacOSAppToApplications({
    bool replaceExisting = false,
  }) {
    lastReplaceExisting = replaceExisting;
    return Future.value();
  }
}

void main() {
  final initialPlatform = DesktopUpdaterPlatform.instance;

  test("$MethodChannelDesktopUpdater is the default instance", () {
    expect(initialPlatform, isInstanceOf<MethodChannelDesktopUpdater>());
  });

  test("getPlatformVersion", () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform();
    DesktopUpdaterPlatform.instance = fakePlatform;

    expect(await desktopUpdaterPlugin.getPlatformVersion(), "42");
  });

  test("installUpdate forwards explicit diagnostics log path to platform",
      () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform();
    DesktopUpdaterPlatform.instance = fakePlatform;

    await desktopUpdaterPlugin.installUpdate(
      stagingPath: "/tmp/staged",
      diagnosticsLogPath: "/tmp/helper.jsonl",
    );

    expect(fakePlatform.lastDiagnosticsLogPath, "/tmp/helper.jsonl");
  });

  test("checkMacOSInstallLocation forwards to platform", () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform()
      ..macOSInstallLocationStatus = const MacOSInstallLocationStatus(
        kind: MacOSInstallLocationKind.diskImage,
        bundlePath: "/Volumes/Example/Example.app",
        targetPath: "/Applications/Example.app",
      );
    DesktopUpdaterPlatform.instance = fakePlatform;

    final status = await desktopUpdaterPlugin.checkMacOSInstallLocation();

    expect(status.kind, MacOSInstallLocationKind.diskImage);
    expect(status.targetPath, "/Applications/Example.app");
  });

  test("moveMacOSAppToApplications forwards replace policy to platform",
      () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform();
    DesktopUpdaterPlatform.instance = fakePlatform;

    await desktopUpdaterPlugin.moveMacOSAppToApplications(
      replaceExisting: true,
    );

    expect(fakePlatform.lastReplaceExisting, isTrue);
  });

  test("checkZipFirstUpdate accepts app-owned request headers provider",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater_");
    try {
      final archive = File(path.join(tempDir.path, "app-archive.json"));
      await archive.writeAsString(
        '{"schemaVersion":3,"appName":"Example","items":[]}',
      );

      final result = await DesktopUpdater().checkZipFirstUpdate(
        appArchiveUrl: archive.uri,
        currentVersion: DesktopVersionInfo.fromParts(versionName: "1.0.0"),
        requestHeadersProvider: (_) => {"x-update-auth": "runtime-token"},
      );

      expect(result, isNull);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
