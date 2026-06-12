import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:path/path.dart" as path;

class ManualUploadProvider implements UploadProvider {
  const ManualUploadProvider();

  @override
  Future<UploadResult> upload({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  }) async {
    final manifestPath = path.join(
      localRoot.path,
      ".desktop_updater_publish.json",
    );

    output
      ..writeln("Manual publish package is ready.")
      ..writeln("Not uploaded yet.")
      ..writeln()
      ..writeln("Upload this folder contents to your update host:")
      ..writeln(_folderUri(localRoot))
      ..writeln()
      ..writeln("Expected remote root:")
      ..writeln(manifest.baseUrl)
      ..writeln()
      ..writeln("After upload, validate:")
      ..writeln(
        "dart run desktop_updater:release validate --manifest $manifestPath",
      )
      ..writeln()
      ..writeln("Want automatic upload next time?")
      ..writeln("See docs/publishing.md");

    return const UploadResult(uploaded: false);
  }
}

String _folderUri(Directory directory) {
  final uri = directory.absolute.uri.toString();
  return uri.endsWith("/") ? uri : "$uri/";
}
