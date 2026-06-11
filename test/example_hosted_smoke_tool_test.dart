import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../example/tool/hosted_update_smoke.dart" as hosted_smoke;

void main() {
  test("hosted update smoke tool launches app with hosted env contract", () {
    final source =
        File("example/tool/hosted_update_smoke.dart").readAsStringSync();

    expect(source, contains("--app-archive-url"));
    expect(source, contains("--production-gates"));
    expect(source, contains("DESKTOP_UPDATER_APP_ARCHIVE_URL"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE_MARKER"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS"));
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
}
