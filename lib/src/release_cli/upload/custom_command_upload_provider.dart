import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:path/path.dart" as path;

/// Runs the shell process used by [CustomCommandUploadProvider].
typedef CustomCommandProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// Upload provider that delegates publishing to a user configured command.
class CustomCommandUploadProvider implements UploadProvider {
  /// Creates a custom command upload provider.
  const CustomCommandUploadProvider({
    CustomCommandProcessRunner runProcess = defaultCustomCommandProcessRunner,
    bool? isWindows,
  })  : _runProcess = runProcess,
        _isWindows = isWindows;

  final CustomCommandProcessRunner _runProcess;
  final bool? _isWindows;

  @override
  Future<UploadResult> upload({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  }) async {
    if (config is! CustomCommandUploadConfig) {
      throw const FormatException(
        "CustomCommandUploadProvider requires CustomCommandUploadConfig.",
      );
    }

    final manifestPath = path.join(
      localRoot.path,
      ".desktop_updater_publish.json",
    );
    final environment = {
      ...Platform.environment,
      "DESKTOP_UPDATER_LOCAL_ROOT": localRoot.path,
      "DESKTOP_UPDATER_PUBLISH_MANIFEST": manifestPath,
      "DESKTOP_UPDATER_BASE_URL": manifest.baseUrl.toString(),
      "DESKTOP_UPDATER_APP_ARCHIVE_URL": manifest.appArchive.url.toString(),
      "DESKTOP_UPDATER_RELEASE_URL": manifest.release.url.toString(),
      "DESKTOP_UPDATER_ARTIFACT_URL": manifest.artifact.url.toString(),
      "DESKTOP_UPDATER_PLATFORM": manifest.release.platform,
      "DESKTOP_UPDATER_VERSION": manifest.release.version,
      "DESKTOP_UPDATER_CHANNEL": manifest.release.channel,
      "PUBLISH_MANIFEST": manifestPath,
      "BASE_URL": manifest.baseUrl.toString(),
      "APP_ARCHIVE_URL": manifest.appArchive.url.toString(),
      "RELEASE_URL": manifest.release.url.toString(),
      "ARTIFACT_URL": manifest.artifact.url.toString(),
      "PLATFORM": manifest.release.platform,
      "VERSION": manifest.release.version,
      "CHANNEL": manifest.release.channel,
    };

    final result = await _runShellCommand(config.command, environment);
    if (result.stdout.toString().isNotEmpty) {
      output.write(result.stdout);
    }
    if (result.stderr.toString().isNotEmpty) {
      output.write(result.stderr);
    }
    if (result.exitCode != 0) {
      throw ProcessException(
        "customCommand",
        [config.command],
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
    }
    return const UploadResult(uploaded: true);
  }

  Future<ProcessResult> _runShellCommand(
    String command,
    Map<String, String> environment,
  ) {
    if (_isWindows ?? Platform.isWindows) {
      return _runWindowsCommand(command, environment);
    }
    return _runProcess("/bin/sh", ["-c", command], environment: environment);
  }

  Future<ProcessResult> _runWindowsCommand(
    String command,
    Map<String, String> environment,
  ) async {
    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_upload_");
    try {
      final script = File(path.join(tempDir.path, "upload.cmd"));
      await script.writeAsString("@echo off\r\n$command\r\n");
      return await _runProcess(
        "cmd",
        ["/d", "/e:off", "/v:off", "/c", script.path],
        environment: environment,
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  }
}

/// Default process runner for custom command upload scripts.
Future<ProcessResult> defaultCustomCommandProcessRunner(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) {
  return Process.run(
    executable,
    arguments,
    environment: environment,
  );
}
