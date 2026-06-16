import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter/services.dart";
import "package:path/path.dart" as path;

/// Reads the current desktop app version from platform metadata.
Future<DesktopVersionInfo?> currentVersionInfo() async {
  if (Platform.isLinux) {
    final exePath = await File("/proc/self/exe").resolveSymbolicLinks();
    final appPath = path.dirname(exePath);
    final versionPath = path.join(
      appPath,
      "data",
      "flutter_assets",
      "version.json",
    );
    final versionJson = jsonDecode(await File(versionPath).readAsString())
        as Map<String, dynamic>;
    return DesktopVersionInfo.fromParts(
      versionName: versionJson["version"]?.toString(),
      buildNumber: versionJson["build_number"]?.toString(),
    );
  }

  final methodChannel = MethodChannelDesktopUpdater();
  Map<String, String?>? versionInfo;
  try {
    versionInfo = await methodChannel.getCurrentVersionInfo();
  } on MissingPluginException {
    versionInfo = null;
  }

  if (versionInfo != null) {
    return DesktopVersionInfo.fromParts(
      versionName: versionInfo["version"],
      buildNumber: versionInfo["buildNumber"],
    );
  }

  final buildNumber = await methodChannel.getCurrentVersion();
  if (buildNumber == null || buildNumber.trim().isEmpty) {
    return null;
  }

  return DesktopVersionInfo.fromParts(buildNumber: buildNumber);
}
