import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:path/path.dart" as path;

class CustomCommandUploadProvider implements UploadProvider {
  const CustomCommandUploadProvider();

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

    final executable = Platform.isWindows ? "cmd" : "/bin/sh";
    final arguments =
        Platform.isWindows ? ["/c", config.command] : ["-c", config.command];
    final result = await Process.run(
      executable,
      arguments,
      environment: environment,
    );
    if (result.stdout.toString().isNotEmpty) {
      output.write(result.stdout);
    }
    if (result.stderr.toString().isNotEmpty) {
      output.write(result.stderr);
    }
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
    }
    return const UploadResult(uploaded: true);
  }
}
