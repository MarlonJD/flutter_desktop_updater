import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../example/tool/hosted_update_smoke.dart" as hosted_smoke;
import "support/dart_cli.dart";

void main() {
  test("hosted smoke isolates recovery receipts for each invocation", () async {
    final root = await Directory.systemTemp.createTemp("hosted_receipt_test_");
    final runDirectories = <Directory>[];
    try {
      final foreignReceipt =
          File(path.join(root.path, "existing-receipt.json"));
      await foreignReceipt.writeAsString("unrelated receipt");
      final app = File(path.join(root.path, "fake-app"));
      await app.writeAsString(r'''#!/bin/sh
set -eu
printf '%s' "$DESKTOP_UPDATER_RECOVERY_STORE_PATH" > "$0.recovery-path"
printf '%s' 'test receipt' > "$DESKTOP_UPDATER_RECOVERY_STORE_PATH"
printf '%s' 'installing' > "$DESKTOP_UPDATER_HOSTED_SMOKE_MARKER"
printf '%s' 'installed' > "$(dirname "$0")/desktop_updater_smoke.txt"
''');
      final chmod = await Process.run("chmod", ["+x", app.path]);
      expect(chmod.exitCode, 0);
      final receiptPaths = <String>[];
      for (var run = 0; run < 2; run++) {
        final result = await Process.run(
          resolveDartExecutable(),
          [
            "run",
            "example/tool/hosted_update_smoke.dart",
            "--app",
            app.path,
            "--app-archive-url",
            "http://127.0.0.1/unused-app-archive.json",
          ],
          environment: {
            "DESKTOP_UPDATER_RECOVERY_STORE_PATH": foreignReceipt.path,
          },
        );
        final markerLine = (result.stdout as String)
            .split("\n")
            .firstWhere((line) => line.startsWith("Hosted smoke marker: "));
        final runDirectory =
            File(markerLine.substring("Hosted smoke marker: ".length)).parent;
        expect(path.basename(runDirectory.path),
            startsWith("desktop_updater_hosted_smoke_"));
        runDirectories.add(runDirectory);
        expect(result.exitCode, 0,
            reason: "${result.stdout}\n${result.stderr}");
        final receiptPath =
            await File("${app.path}.recovery-path").readAsString();
        expect(path.dirname(receiptPath), runDirectory.path);
        expect(await File(receiptPath).readAsString(), "test receipt");
        expect(await foreignReceipt.readAsString(), "unrelated receipt");
        receiptPaths.add(receiptPath);
        await File(path.join(root.path, "desktop_updater_smoke.txt")).delete();
      }
      expect(receiptPaths.toSet(), hasLength(2));
    } finally {
      for (final directory in runDirectories) {
        await directory.delete(recursive: true);
      }
      await root.delete(recursive: true);
    }
  }, skip: Platform.isWindows);

  test("hosted update smoke tool launches app with hosted env contract", () {
    final source =
        File("example/tool/hosted_update_smoke.dart").readAsStringSync();

    expect(source, contains("--app-archive-url"));
    expect(source, contains("--production-gates"));
    expect(source, contains("DESKTOP_UPDATER_APP_ARCHIVE_URL"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE_MARKER"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS"));
    expect(source, isNot(contains("--expect-installer-handoff")));
    expect(source, isNot(contains("pkg installer opened")));
    expect(source, contains("if (!productionGates)"));
    expect(source, contains("checking"));
    expect(source, contains("downloading"));
    expect(source, contains("installing"));
  });

  test("hosted smoke marker wait accepts already reached later states", () {
    expect(hosted_smoke.markerHasReached("checking", "checking"), isTrue);
    expect(hosted_smoke.markerHasReached("downloading", "checking"), isTrue);
    expect(hosted_smoke.markerHasReached("installing", "checking"), isTrue);
    expect(hosted_smoke.markerHasReached("installing", "downloading"), isTrue);
    expect(hosted_smoke.markerHasReached("checking", "downloading"), isFalse);
    expect(
      hosted_smoke.markerHasReached("failed: network", "checking"),
      isFalse,
    );
  });

  test("hosted smoke does not preserve the retired Installer.app success mode",
      () {
    final source =
        File("example/tool/hosted_update_smoke.dart").readAsStringSync();

    expect(source, isNot(contains("expectInstallerHandoff")));
    expect(source, isNot(contains("Installer.app handoff scheduled")));
  });
}
