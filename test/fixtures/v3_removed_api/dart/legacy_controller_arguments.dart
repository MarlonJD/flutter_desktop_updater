import "package:desktop_updater/desktop_updater.dart";

void main() {
  DesktopUpdaterController(
    appArchiveUrl: null,
    allowUnsignedMacOSUpdates: true,
    diagnosticsLogPath: "/tmp/desktop-updater.jsonl",
  );
}
