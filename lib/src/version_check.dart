import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:http/http.dart" as http;

Future<ItemModel?> versionCheckFunction({
  required String appArchiveUrl,
}) async {
  final executablePath = await DesktopUpdater().getExecutablePath();

  final directoryPath = executablePath?.substring(
    0,
    executablePath.lastIndexOf(Platform.pathSeparator),
  );

  if (directoryPath == null) {
    throw Exception("Desktop Updater: Executable path is null");
  }

  var dir = Directory(directoryPath);

  if (Platform.isMacOS) {
    dir = dir.parent;
  }

  // Eğer belirtilen yol bir dizinse
  if (await dir.exists()) {
    // temp dizini oluşturulur
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater");

    // Download oldHashFilePath
    final client = http.Client();

    final appArchive = http.Request("GET", Uri.parse(appArchiveUrl));
    final appArchiveResponse = await client.send(appArchive);

    // temp dizinindeki dosyaları kopyala
    // dir + output.txt dosyası oluşturulur
    final outputFile =
        File("${tempDir.path}${Platform.pathSeparator}app-archive.json");

    // Çıktı dosyasını açıyoruz
    final sink = outputFile.openWrite();

    // Save the file
    await appArchiveResponse.stream.pipe(sink);

    // Close the file
    await sink.close();

    print("app archive file downloaded to ${outputFile.path}");

    if (!outputFile.existsSync()) {
      throw Exception("Desktop Updater: App archive do not exist");
    }

    final appArchiveString = await outputFile.readAsString();

    // Decode as List<FileHashModel?>
    final appArchiveDecoded = AppArchiveModel.fromJson(
      jsonDecode(appArchiveString),
    );

    final versions = appArchiveDecoded.items
        .where(
          (element) => element.platform == Platform.operatingSystem,
        )
        .toList();

    if (versions.isEmpty) {
      throw Exception("Desktop Updater: No version found for this platform");
    }

    // Get the latest version with shortVersion number
    final latestVersion = versions.reduce(
      (value, element) {
        if (value.shortVersion > element.shortVersion) {
          return value;
        }
        return element;
      },
    );

    print("Latest version: ${latestVersion.shortVersion}");

    late String? currentVersion;

    await DesktopUpdater().getCurrentVersion().then(
      (value) {
        print("Current version: $value");
        currentVersion = value;
      },
    );

    if (currentVersion == null) {
      throw Exception("Desktop Updater: Current version is null");
    }

    if (latestVersion.shortVersion > int.parse(currentVersion!)) {
      print("New version found: ${latestVersion.version}");
      return latestVersion;
    } else {
      print("No new version found");
    }
  }
  return null;
}