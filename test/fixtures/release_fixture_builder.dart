import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:path/path.dart" as path;

class ReleaseFixture {
  const ReleaseFixture({
    required this.root,
    required this.artifact,
    required this.release,
    required this.index,
  });

  final Directory root;
  final File artifact;
  final File release;
  final File index;
}

Future<ReleaseFixture> buildReleaseFixture({
  required Directory root,
  required Uri baseUri,
  String platform = "linux",
  String version = "2.0.0",
  int buildNumber = 200,
  bool badChecksum = false,
  bool traversalZip = false,
}) async {
  await root.create(recursive: true);
  final artifact = File(path.join(root.path, "Example-$platform.zip"));
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        traversalZip ? "../evil.txt" : "app.txt",
        "version=$version",
      ),
    );
  artifact.writeAsBytesSync(ZipEncoder().encode(archive));
  final artifactSha =
      crypto.sha256.convert(await artifact.readAsBytes()).toString();

  final release = File(path.join(root.path, "release.json"));
  await release.writeAsString(
    const JsonEncoder.withIndent("  ").convert({
      "schemaVersion": 3,
      "packageId": "com.example.app",
      "appName": "Example",
      "version": version,
      "buildNumber": buildNumber,
      "platform": platform,
      "channel": "stable",
      "artifact": {
        "kind": "zip",
        "url": baseUri.resolve(path.basename(artifact.path)).toString(),
        "sha256": badChecksum ? "a" * 64 : artifactSha,
        "length": await artifact.length(),
      },
      "install": {"strategy": "wholeDirectoryReplace"},
      "minimumUpdaterVersion": "2.0.0",
      "generatedAt": "2026-06-11T00:00:00Z",
    }),
  );

  final index = File(path.join(root.path, "app-archive.json"));
  await index.writeAsString(
    const JsonEncoder.withIndent("  ").convert({
      "schemaVersion": 3,
      "appName": "Example App",
      "items": [
        {
          "version": version,
          "buildNumber": buildNumber,
          "platform": platform,
          "channel": "stable",
          "mandatory": false,
          "release": baseUri.resolve("release.json").toString(),
        },
      ],
    }),
  );

  return ReleaseFixture(
    root: root,
    artifact: artifact,
    release: release,
    index: index,
  );
}
