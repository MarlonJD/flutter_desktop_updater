import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("typed update states are distinct", () {
    final descriptor = _descriptor();
    final states = <UpdateState>[
      UpdateIdle(),
      UpdateChecking(),
      UpdateAvailable(descriptor: descriptor, mandatory: false),
      UpdateFreshInstallRequired(
        descriptor: descriptor,
        freshInstall: ReleaseFreshInstall(
          downloadUrl: Uri.parse("https://example.com/download/latest"),
        ),
        mandatory: true,
      ),
      UpdateBlockedBySupportPolicy(
        descriptor: descriptor,
        supportPolicy: ReleaseSupportPolicy(
          minimumSupportedVersion: "2.4.0",
          enforcedAfter: DateTime.utc(2026, 7, 15),
        ),
      ),
      UpdateDownloading(receivedBytes: 1, totalBytes: 2),
      UpdateReadyToInstall(stagingPath: "/tmp/stage"),
      UpdateInstalling(),
      UpdateFailed("boom"),
    ];

    expect(states.map((state) => state.runtimeType).toSet(), hasLength(9));
  });
}

ReleaseDescriptor _descriptor() {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example.app",
    version: "2.4.0",
    buildNumber: 240,
    platform: "macos",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://example.com/app.zip"),
      sha256:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      length: 1024,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 23),
  );
}
