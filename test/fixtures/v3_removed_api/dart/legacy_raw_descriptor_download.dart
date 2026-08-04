import "package:desktop_updater/desktop_updater.dart";

void main() {
  DesktopUpdater().downloadZipFirstUpdate(
    appArchiveUrl: Uri.parse("https://updates.example.test/app-archive.json"),
    currentVersion: DesktopVersionInfo.parse("2.7.0"),
    descriptor: throw UnimplementedError(),
  );
}
