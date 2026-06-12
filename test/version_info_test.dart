import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("DesktopVersionInfo", () {
    test("parses Flutter versions with numeric build metadata", () {
      final version = DesktopVersionInfo.parse("1.2.3+4");

      expect(version.versionName, "1.2.3");
      expect(version.buildNumber, 4);
    });

    test("parses Flutter versions without build metadata", () {
      final version = DesktopVersionInfo.parse("1.2.3");

      expect(version.versionName, "1.2.3");
      expect(version.buildNumber, isNull);
    });

    test("rejects empty build metadata", () {
      expect(() => DesktopVersionInfo.parse("1.2.3+"), throwsFormatException);
    });

    test("uses explicit build number when version omits build metadata", () {
      final version = DesktopVersionInfo.fromParts(
        versionName: "1.2.3",
        buildNumber: "9",
      );

      expect(version.versionName, "1.2.3");
      expect(version.buildNumber, 9);
    });

    test("formats build-number release labels with build metadata", () {
      final version = DesktopVersionInfo.parse("1.2.3+4");

      expect(releaseVersionLabel(version), "1.2.3+4");
      expect(releaseVersionFolder(version), "4");
    });

    test("formats buildless release labels with the semantic version", () {
      final version = DesktopVersionInfo.parse("1.2.3");

      expect(releaseVersionLabel(version), "1.2.3");
      expect(releaseVersionFolder(version), "1.2.3");
    });

    test("extracts archive version labels without splitting on hyphens", () {
      final versionLabel = archiveVersionLabelFromName(
        archiveName: "my-app-2.0.0-dev.2-windows",
        appName: "my-app",
        platform: "windows",
      );

      expect(versionLabel, "2.0.0-dev.2");
    });

    test("extracts archive version labels with build metadata", () {
      final versionLabel = archiveVersionLabelFromName(
        archiveName: "desktop_updater_example-1.2.3+4-linux",
        appName: "desktop_updater_example",
        platform: "linux",
      );

      expect(versionLabel, "1.2.3+4");
    });

    test("ignores archive names for other platforms", () {
      final versionLabel = archiveVersionLabelFromName(
        archiveName: "desktop_updater_example-1.2.3+4-macos.app",
        appName: "desktop_updater_example",
        platform: "windows",
      );

      expect(versionLabel, isNull);
    });
  });

  group("version comparison", () {
    test("keeps build-number ordering when both sides expose builds", () {
      final current = DesktopVersionInfo.fromParts(
        versionName: "1.2.3",
        buildNumber: "4",
      );
      final remote = DesktopVersionInfo.fromParts(
        versionName: "1.2.3",
        buildNumber: "5",
      );

      expect(compareDesktopVersions(remote, current), greaterThan(0));
    });

    test("uses semantic version ordering when build numbers are absent", () {
      final current = DesktopVersionInfo.parse("1.2.3");
      final remote = DesktopVersionInfo.parse("1.2.4");

      expect(compareDesktopVersions(remote, current), greaterThan(0));
    });

    test("does not update to an older semantic version without build numbers",
        () {
      final current = DesktopVersionInfo.parse("1.2.3");
      final remote = DesktopVersionInfo.parse("1.2.2");

      expect(compareDesktopVersions(remote, current), lessThan(0));
    });

    test(
      "does not treat build-only difference as newer when current build is unavailable",
      () {
        final current = DesktopVersionInfo.parse("1.2.3");
        final remote = DesktopVersionInfo.fromParts(
          versionName: "1.2.3",
          buildNumber: "5",
        );

        expect(compareDesktopVersions(remote, current), 0);
      },
    );
  });
}
