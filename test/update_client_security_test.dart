import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "fixtures/update_server.dart";

void main() {
  test("rejects index item that points to an older descriptor", () async {
    final fixture = await _UpdateFixture.create(
      indexVersion: "99.0.0",
      indexBuildNumber: 9900,
      descriptorVersion: "1.0.0",
      descriptorBuildNumber: 100,
    );
    try {
      final client = UpdateClient(
        appArchiveUrl: fixture.archiveUrl,
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "2.0.0",
          buildNumber: "200",
        ),
        platform: "macos",
      );

      await expectLater(
        client.checkForUpdate(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("release.json version does not match app-archive.json"),
          ),
        ),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("accepts index item when descriptor identity matches", () async {
    final fixture = await _UpdateFixture.create(
      indexVersion: "2.1.0",
      indexBuildNumber: 210,
      descriptorVersion: "2.1.0",
      descriptorBuildNumber: 210,
    );
    try {
      final client = UpdateClient(
        appArchiveUrl: fixture.archiveUrl,
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "2.0.0",
          buildNumber: "200",
        ),
        platform: "macos",
      );

      final result = await client.checkForUpdate();

      expect(result, isNotNull);
      expect(result!.item.version, "2.1.0");
      expect(result.item.version, result.descriptor.version);
      expect(result.item.buildNumber, 210);
      expect(result.descriptor.version, "2.1.0");
      expect(result.descriptor.buildNumber, 210);
      expect(result.item.buildNumber, result.descriptor.buildNumber);
    } finally {
      await fixture.delete();
    }
  });

  test("filters staged rollout index items before descriptor download",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final rollout = {"percentage": 25, "salt": "stable-2026-06"};

    final withoutIdentityTransport = _MapUpdateTransport({
      archiveUrl: _indexJson(releaseUrl, rollout: rollout),
      releaseUrl: _descriptorJson(artifactUrl: artifactUrl),
    });
    final withoutIdentity = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      platform: "macos",
      transport: withoutIdentityTransport,
    );

    expect(await withoutIdentity.checkForUpdate(), isNull);
    expect(withoutIdentityTransport.downloadedSources, [archiveUrl]);

    final outsideRolloutTransport = _MapUpdateTransport({
      archiveUrl: _indexJson(releaseUrl, rollout: rollout),
      releaseUrl: _descriptorJson(artifactUrl: artifactUrl),
    });
    final outsideRollout = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      platform: "macos",
      transport: outsideRolloutTransport,
      installationIdentity: "device-1",
    );

    expect(await outsideRollout.checkForUpdate(), isNull);
    expect(outsideRolloutTransport.downloadedSources, [archiveUrl]);

    final eligibleTransport = _MapUpdateTransport({
      archiveUrl: _indexJson(releaseUrl, rollout: rollout),
      releaseUrl: _descriptorJson(artifactUrl: artifactUrl),
    });
    final eligible = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      platform: "macos",
      transport: eligibleTransport,
      installationIdentity: "pilot-a",
    );

    final result = await eligible.checkForUpdate();

    expect(result, isNotNull);
    expect(result!.item.version, "2.1.0");
    expect(eligibleTransport.downloadedSources, [archiveUrl, releaseUrl]);
  });

  test("keeps rollout metadata absent items eligible without identity",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final transport = _MapUpdateTransport({
      archiveUrl: _indexJson(releaseUrl),
      releaseUrl: _descriptorJson(artifactUrl: artifactUrl),
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      platform: "macos",
      transport: transport,
    );

    final result = await client.checkForUpdate();

    expect(result, isNotNull);
    expect(transport.downloadedSources, [archiveUrl, releaseUrl]);
  });

  test("keeps delta artifacts descriptor-only during update selection",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final deltaUrl = Uri.parse(
      "https://updates.example.com/2.0.0-to-2.1.0.patch",
    );
    final transport = _MapUpdateTransport({
      archiveUrl: _indexJson(releaseUrl),
      releaseUrl: _descriptorJson(
        artifactUrl: artifactUrl,
        deltaArtifacts: [
          {
            "fromVersion": "2.0.0",
            "kind": "bsdiff",
            "url": deltaUrl.toString(),
            "sha256": "b" * 64,
            "length": 456,
          },
        ],
      ),
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      platform: "macos",
      transport: transport,
    );

    final result = await client.checkForUpdate();

    expect(result, isNotNull);
    expect(result!.descriptor.artifact.url, artifactUrl);
    expect(result.descriptor.deltaArtifacts.single.url, deltaUrl);
    expect(transport.downloadedSources, [archiveUrl, releaseUrl]);
  });

  test("skips descriptors that require a newer updater", () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final transport = _MapUpdateTransport({
      archiveUrl: _indexJson(releaseUrl),
      releaseUrl: _descriptorJson(
        artifactUrl: artifactUrl,
        minimumUpdaterVersion: "99.0.0",
      ),
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      currentUpdaterVersion: DesktopVersionInfo.parse("2.1.4"),
      platform: "macos",
      transport: transport,
    );

    final result = await client.checkForUpdate();

    expect(result, isNull);
    expect(transport.downloadedSources, [archiveUrl, releaseUrl]);
    expect(transport.downloadedSources, isNot(contains(artifactUrl)));
  });

  test("rejects direct artifact staging when updater version is too old", () {
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final transport = _MapUpdateTransport({});
    final client = UpdateClient(
      appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      currentUpdaterVersion: DesktopVersionInfo.parse("2.1.4"),
      platform: "macos",
      transport: transport,
    );

    expect(
      () => client.downloadVerifyAndStage(
        descriptor: _descriptor(
          artifactUrl: artifactUrl,
          minimumUpdaterVersion: "99.0.0",
        ),
      ),
      throwsUnsupportedError,
    );
    expect(transport.downloadedSources, isEmpty);
  });

  test("skips descriptors when minimum OS policy rejects the platform",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final transport = _MapUpdateTransport({
      archiveUrl: _indexJson(releaseUrl),
      releaseUrl: _descriptorJson(
        artifactUrl: artifactUrl,
        minimumOS: {"macos": "13.0"},
      ),
    });
    final checkedPolicies = <String>[];
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
      platform: "macos",
      transport: transport,
      isMinimumOSSupported: ({
        required minimumOS,
        required platform,
      }) {
        checkedPolicies.add("$platform:$minimumOS");
        return false;
      },
    );

    final result = await client.checkForUpdate();

    expect(result, isNull);
    expect(checkedPolicies, ["macos:13.0"]);
    expect(transport.downloadedSources, [archiveUrl, releaseUrl]);
  });
}

String _indexJson(Uri releaseUrl, {Map<String, dynamic>? rollout}) {
  return jsonEncode({
    "schemaVersion": 3,
    "appName": "Example",
    "items": [
      {
        "version": "2.1.0",
        "buildNumber": 210,
        "platform": "macos",
        "channel": "stable",
        "mandatory": true,
        "release": releaseUrl.toString(),
        if (rollout != null) "rollout": rollout,
      },
    ],
  });
}

String _descriptorJson({
  required Uri artifactUrl,
  String minimumUpdaterVersion = "2.0.0",
  Map<String, String> minimumOS = const {},
  List<Map<String, dynamic>> deltaArtifacts = const [],
}) {
  final json = _descriptor(
    artifactUrl: artifactUrl,
    minimumUpdaterVersion: minimumUpdaterVersion,
    minimumOS: minimumOS,
  ).toJson();
  if (deltaArtifacts.isNotEmpty) {
    json["deltaArtifacts"] = deltaArtifacts;
  }
  return jsonEncode(
    json,
  );
}

ReleaseDescriptor _descriptor({
  required Uri artifactUrl,
  String minimumUpdaterVersion = "2.0.0",
  Map<String, String> minimumOS = const {},
}) {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example",
    version: "2.1.0",
    buildNumber: 210,
    platform: "macos",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: artifactUrl,
      sha256: "a" * 64,
      length: 12,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: minimumUpdaterVersion,
    minimumOS: minimumOS,
    generatedAt: DateTime.utc(2026, 6, 13),
  );
}

class _MapUpdateTransport implements UpdateTransport {
  _MapUpdateTransport(this.responses);

  final Map<Uri, String> responses;
  final List<Uri> downloadedSources = [];

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    downloadedSources.add(source);
    final response = responses[source];
    if (response == null) {
      throw StateError("No fake response for $source.");
    }
    await destination.parent.create(recursive: true);
    await destination.writeAsString(response);
    onProgress?.call(response.length, response.length);
  }
}

class _UpdateFixture {
  const _UpdateFixture({
    required this.root,
    required this.server,
    required this.archiveUrl,
  });

  final Directory root;
  final UpdateServer server;
  final Uri archiveUrl;

  static Future<_UpdateFixture> create({
    required String indexVersion,
    required int indexBuildNumber,
    required String descriptorVersion,
    required int descriptorBuildNumber,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      "update_client_security_",
    );
    final server = await UpdateServer.bind(root);
    final releaseUrl = server.uri.resolve("release.json");
    final artifactUrl = server.uri.resolve("artifact.zip");
    final artifactFile = File(path.join(root.path, "artifact.zip"));
    await artifactFile.writeAsString("artifact bytes");
    final artifactLength = await artifactFile.length();
    const artifactSha256 =
        "4659fc0570122b0e0aa14f4ff7c261b1fe51795a01ba79963f462ebf40d7520d";

    await File(path.join(root.path, "app-archive.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "appName": "Example",
            "items": [
              {
                "version": indexVersion,
                "buildNumber": indexBuildNumber,
                "platform": "macos",
                "channel": "stable",
                "mandatory": true,
                "release": releaseUrl.toString(),
              },
            ],
          })}\n",
    );
    await File(path.join(root.path, "release.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "appName": "Example",
            "version": descriptorVersion,
            "buildNumber": descriptorBuildNumber,
            "platform": "macos",
            "channel": "stable",
            "artifact": {
              "kind": "zip",
              "url": artifactUrl.toString(),
              "sha256": artifactSha256,
              "length": artifactLength,
            },
            "install": {"strategy": "wholeBundleReplace"},
            "minimumUpdaterVersion": "2.0.0",
            "generatedAt": DateTime.utc(2026, 6, 12).toIso8601String(),
          })}\n",
    );

    return _UpdateFixture(
      root: root,
      server: server,
      archiveUrl: server.uri.resolve("app-archive.json"),
    );
  }

  Future<void> delete() async {
    await server.close();
    await root.delete(recursive: true);
  }
}
