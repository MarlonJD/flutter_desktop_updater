import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/macos_distribution_artifacts.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:desktop_updater/src/release_cli/validate_command.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../fixtures/update_server.dart";

void main() {
  test("validate simulates an older version and verifies hosted artifact",
      () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.0.1",
      targetBuildNumber: 201,
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "validate",
          "--manifest",
          fixture.manifestFile.path,
          "--from-version",
          "2.0.0+200",
        ],
        projectRoot: fixture.projectRoot,
        output: output,
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Hosted app archive: OK"));
      expect(output.toString(), contains("Update selection: OK"));
      expect(output.toString(), contains("Hosted release descriptor: OK"));
      expect(output.toString(), contains("Hosted artifact SHA-256: OK"));
    } finally {
      await fixture.delete();
    }
  });

  test("validate reports hosted Inno installer artifact kind", () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.5.0",
      targetBuildNumber: 250,
      platform: "windows",
      artifactKind: "innoInstaller",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "validate",
          "--manifest",
          fixture.manifestFile.path,
          "--from-version",
          "2.4.0+240",
        ],
        projectRoot: fixture.projectRoot,
        output: output,
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Hosted artifact SHA-256: OK"));
      expect(output.toString(), contains("Artifact kind: innoInstaller"));
    } finally {
      await fixture.delete();
    }
  });

  test("validate reports hosted macOS DMG trust validation", () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.6.0",
      targetBuildNumber: 260,
      artifactKind: "dmg",
    );
    try {
      final output = StringBuffer();
      final commands = <String>[];
      final manifest = await PublishManifest.readFrom(fixture.manifestFile);

      await ReleaseValidator(
        isMacOSHost: true,
        macosVerifier: MacOSDistributionVerifier(
          runProcess: (executable, arguments) async {
            commands.add([executable, ...arguments].join(" "));
            return ProcessResult(0, 0, "", "");
          },
        ),
      ).validateReleaseFiles(manifest: manifest, output: output);

      expect(output.toString(), contains("Artifact kind: dmg"));
      expect(
        output.toString(),
        contains("macOS DMG primary signature: OK"),
      );
      expect(
        commands.single,
        startsWith("/usr/sbin/spctl --assess --type open"),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("validate reports hosted macOS PKG trust validation", () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.6.0",
      targetBuildNumber: 260,
      artifactKind: "pkgInstaller",
    );
    try {
      final output = StringBuffer();
      final commands = <String>[];
      final manifest = await PublishManifest.readFrom(fixture.manifestFile);

      await ReleaseValidator(
        isMacOSHost: true,
        macosVerifier: MacOSDistributionVerifier(
          runProcess: (executable, arguments) async {
            commands.add([executable, ...arguments].join(" "));
            if (executable == "/usr/sbin/pkgutil" &&
                arguments.first == "--expand-full") {
              final expanded = Directory(arguments.last);
              await expanded.create(recursive: true);
              await File(path.join(expanded.path, "PackageInfo"))
                  .writeAsString('<pkg-info identifier="com.example.app.pkg">');
            }
            return ProcessResult(0, 0, "", "");
          },
        ),
      ).validateReleaseFiles(manifest: manifest, output: output);

      expect(output.toString(), contains("Artifact kind: pkgInstaller"));
      expect(output.toString(), contains("macOS PKG signature: OK"));
      expect(
        output.toString(),
        contains("macOS PKG Gatekeeper install assessment: OK"),
      );
      expect(
        output.toString(),
        contains("macOS PKG stapler validation: OK"),
      );
      expect(
        commands,
        contains(
            "/usr/sbin/pkgutil --check-signature ${commands.first.split(" ").last}"),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("validate labels macOS trust validation not run off macOS", () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.6.0",
      targetBuildNumber: 260,
      artifactKind: "dmg",
    );
    try {
      final output = StringBuffer();
      final manifest = await PublishManifest.readFrom(fixture.manifestFile);

      await ReleaseValidator(
        isMacOSHost: false,
      ).validateReleaseFiles(manifest: manifest, output: output);

      expect(
        output.toString(),
        contains("macOS artifact trust validation: not run"),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("validate honors DMG descriptors with primary signature disabled",
      () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.6.0",
      targetBuildNumber: 260,
      artifactKind: "dmg",
      dmgVerifyPrimarySignature: false,
    );
    try {
      final output = StringBuffer();
      final commands = <String>[];
      final manifest = await PublishManifest.readFrom(fixture.manifestFile);

      await ReleaseValidator(
        isMacOSHost: true,
        macosVerifier: MacOSDistributionVerifier(
          runProcess: (executable, arguments) async {
            commands.add([executable, ...arguments].join(" "));
            return ProcessResult(0, 0, "", "");
          },
        ),
      ).validateReleaseFiles(manifest: manifest, output: output);

      expect(
        output.toString(),
        contains("macOS DMG primary signature: not run"),
      );
      expect(commands, isEmpty);
    } finally {
      await fixture.delete();
    }
  });

  test("verify command skips zip extraction for Inno installers", () {
    final source = File("bin/verify.dart").readAsStringSync();

    expect(source, contains('descriptor.artifact.kind == "innoInstaller"'));
    expect(source, contains("Installer artifact verified."));
  });

  test("verify command supports macOS DMG and PKG artifact gates", () {
    final source = File("bin/verify.dart").readAsStringSync();

    expect(source, contains('descriptor.artifact.kind == "dmg"'));
    expect(source, contains('descriptor.artifact.kind == "pkgInstaller"'));
    expect(source, contains("macOS artifact trust validation: not run"));
  });

  test("validate rejects hosted descriptor identity mismatch", () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.0.1",
      targetBuildNumber: 201,
    );
    try {
      final releaseFile = File(
        path.join(
          fixture.projectRoot.path,
          "web",
          "releases",
          "2.0.1",
          "macos",
          "release.json",
        ),
      );
      final json =
          jsonDecode(await releaseFile.readAsString()) as Map<String, dynamic>;
      await releaseFile.writeAsString(
        "${const JsonEncoder.withIndent("  ").convert({
              ...json,
              "version": "1.0.0",
              "buildNumber": 100,
            })}\n",
      );

      final output = StringBuffer();
      final exitCode = await runReleaseCommand(
        [
          "validate",
          "--manifest",
          fixture.manifestFile.path,
          "--from-version",
          "2.0.0+200",
        ],
        projectRoot: fixture.projectRoot,
        output: output,
      );

      expect(exitCode, 1);
      expect(
        output.toString(),
        contains("release.json version mismatch"),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("validate verifies signed hosted release descriptor", () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.0.1",
      targetBuildNumber: 201,
    );
    try {
      await _signHostedRelease(fixture);
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "validate",
          "--manifest",
          fixture.manifestFile.path,
          "--from-version",
          "2.0.0+200",
          "--require-signature",
          "--public-keys-env",
          "DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS",
        ],
        projectRoot: fixture.projectRoot,
        output: output,
        environment: {
          "DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS": jsonEncode({
            _publicKeyId: fixture.publicKey,
          }),
        },
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Hosted release descriptor: OK"));
      expect(output.toString(), contains("Hosted artifact SHA-256: OK"));
    } finally {
      await fixture.delete();
    }
  });

  test(
      "validate rejects tampered signed hosted descriptor before metadata trust",
      () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.0.1",
      targetBuildNumber: 201,
    );
    try {
      final releaseFile = await _signHostedRelease(fixture);
      final json =
          jsonDecode(await releaseFile.readAsString()) as Map<String, dynamic>;
      final artifact = json["artifact"] as Map<String, dynamic>;
      await releaseFile.writeAsString(
        "${const JsonEncoder.withIndent("  ").convert({
              ...json,
              "artifact": {
                ...artifact,
                "sha256": "b" * 64,
              },
            })}\n",
      );

      final output = StringBuffer();
      final exitCode = await runReleaseCommand(
        [
          "validate",
          "--manifest",
          fixture.manifestFile.path,
          "--from-version",
          "2.0.0+200",
          "--require-signature",
          "--public-keys-env",
          "DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS",
        ],
        projectRoot: fixture.projectRoot,
        output: output,
        environment: {
          "DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS": jsonEncode({
            _publicKeyId: fixture.publicKey,
          }),
        },
      );

      expect(exitCode, 1);
      expect(
        output.toString(),
        contains("release.json signature verification failed."),
      );
      expect(
        output.toString(),
        isNot(contains("release.json artifact SHA-256 mismatch")),
      );
    } finally {
      await fixture.delete();
    }
  });
}

class HostedPublishFixture {
  const HostedPublishFixture({
    required this.projectRoot,
    required this.manifestFile,
    required this.server,
    required this.publicKey,
  });

  final Directory projectRoot;
  final File manifestFile;
  final UpdateServer server;
  final String publicKey;

  Future<void> delete() async {
    await server.close();
    await projectRoot.delete(recursive: true);
  }
}

Future<HostedPublishFixture> createHostedPublishFixture({
  required String targetVersion,
  required int targetBuildNumber,
  String platform = "macos",
  String artifactKind = "zip",
  bool dmgVerifyPrimarySignature = true,
}) async {
  final projectRoot = await Directory.systemTemp.createTemp("hosted_publish_");
  final webRoot = Directory(path.join(projectRoot.path, "web"));
  await webRoot.create();
  final server = await UpdateServer.bind(webRoot);

  final releaseRelativePath = path.posix.join(
    "releases",
    targetVersion,
    platform,
    "release.json",
  );
  final artifactRelativePath = path.posix.join(
    "releases",
    targetVersion,
    platform,
    _artifactFileName(
      artifactKind: artifactKind,
      platform: platform,
      targetVersion: targetVersion,
    ),
  );
  final releaseUrl = server.uri.resolve(releaseRelativePath);
  final artifactUrl = server.uri.resolve(artifactRelativePath);
  final artifactFile = File(path.join(webRoot.path, artifactRelativePath));
  await artifactFile.parent.create(recursive: true);
  await artifactFile.writeAsString("artifact bytes");
  final artifactSha256 = await sha256File(artifactFile);
  final artifactLength = await artifactFile.length();
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(_privateSeed);
  final publicKey = await keyPair.extractPublicKey();

  await File(path.join(webRoot.path, "app-archive.json")).writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "appName": "Example",
          "items": [
            {
              "version": targetVersion,
              "buildNumber": targetBuildNumber,
              "platform": platform,
              "channel": "stable",
              "mandatory": false,
              "release": releaseUrl.toString(),
            },
          ],
        })}\n",
  );
  await File(path.join(webRoot.path, releaseRelativePath)).writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "packageId": "com.example.app",
          "appName": "Example",
          "version": targetVersion,
          "buildNumber": targetBuildNumber,
          "platform": platform,
          "channel": "stable",
          "artifact": {
            "kind": artifactKind,
            "url": artifactUrl.toString(),
            "sha256": artifactSha256,
            "length": artifactLength,
          },
          "install": _installDescriptorForArtifactKind(
            artifactKind,
            dmgVerifyPrimarySignature: dmgVerifyPrimarySignature,
          ),
          "minimumUpdaterVersion": _minimumUpdaterVersion(artifactKind),
          "generatedAt": DateTime.utc(2026, 6, 12).toIso8601String(),
        })}\n",
  );

  final manifest = PublishManifest(
    schemaVersion: 1,
    baseUrl: server.uri,
    localRoot: webRoot.path,
    appArchive: PublishManifestFile(
      path: "app-archive.json",
      url: server.uri.resolve("app-archive.json"),
    ),
    release: PublishManifestRelease(
      version: targetVersion,
      buildNumber: targetBuildNumber,
      platform: platform,
      channel: "stable",
      path: releaseRelativePath,
      url: releaseUrl,
    ),
    artifact: PublishManifestArtifact(
      kind: artifactKind,
      path: artifactRelativePath,
      url: artifactUrl,
      sha256: artifactSha256,
      length: artifactLength,
    ),
  );
  final manifestFile = File(
    path.join(projectRoot.path, ".desktop_updater_publish.json"),
  );
  await manifest.writeTo(manifestFile);

  return HostedPublishFixture(
    projectRoot: projectRoot,
    manifestFile: manifestFile,
    server: server,
    publicKey: base64Encode(publicKey.bytes),
  );
}

String _artifactFileName({
  required String artifactKind,
  required String platform,
  required String targetVersion,
}) {
  switch (artifactKind) {
    case "innoInstaller":
      return "Example-$targetVersion-windows-setup.exe";
    case "dmg":
      return "Example-$targetVersion-macos.dmg";
    case "pkgInstaller":
      return "Example-$targetVersion-macos.pkg";
  }
  return "Example-$targetVersion-$platform.zip";
}

Map<String, Object?> _installDescriptorForArtifactKind(
  String artifactKind, {
  required bool dmgVerifyPrimarySignature,
}) {
  switch (artifactKind) {
    case "innoInstaller":
      return {
        "strategy": "innoInstaller",
        "inno": {
          "silentArgs": [
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
          ],
          "inheritInstallDirectory": true,
          "logFileName": "desktop_updater_inno_install.log",
          "relaunchAfterInstall": true,
          "requiresElevation": "auto",
          "authenticode": {"required": false},
        },
      };
    case "dmg":
      return {
        "strategy": "wholeBundleReplace",
        "macosDmg": {
          "appBundleName": "Example.app",
          "verifyPrimarySignature": dmgVerifyPrimarySignature,
        },
      };
    case "pkgInstaller":
      return {
        "strategy": "pkgInstaller",
        "macosPkg": {
          "launchMode": "installerApp",
          "expectedPackageIds": ["com.example.app.pkg"],
          "relaunchAfterInstall": false,
        },
      };
  }
  return {"strategy": "wholeBundleReplace"};
}

String _minimumUpdaterVersion(String artifactKind) {
  switch (artifactKind) {
    case "innoInstaller":
      return "2.5.0";
    case "dmg":
    case "pkgInstaller":
      return "2.6.0";
  }
  return "2.0.0";
}

const _publicKeyId = "stable-2026";
const _privateSeed = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
];

Future<File> _signHostedRelease(HostedPublishFixture fixture) async {
  final releaseFile = File(
    path.join(
      fixture.projectRoot.path,
      "web",
      "releases",
      "2.0.1",
      "macos",
      "release.json",
    ),
  );
  final json =
      jsonDecode(await releaseFile.readAsString()) as Map<String, dynamic>;
  final descriptorToSign = ReleaseDescriptor.fromJson({
    ...json,
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": _publicKeyId,
      "value": "",
    },
  });
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(_privateSeed);
  final signature = await algorithm.sign(
    descriptorToSign.canonicalSignatureBytes(),
    keyPair: keyPair,
  );
  await releaseFile.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          ...json,
          "signature": {
            "algorithm": "ed25519",
            "publicKeyId": _publicKeyId,
            "value": base64Encode(signature.bytes),
          },
        })}\n",
  );
  return releaseFile;
}
