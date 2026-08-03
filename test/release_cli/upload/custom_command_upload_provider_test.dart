import "dart:io";

import "package:desktop_updater/src/release_manifest.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/custom_command_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("custom command receives publish manifest environment", () async {
    final tempDir = await Directory.systemTemp.createTemp("custom_upload_");
    try {
      final logFile = File(path.join(tempDir.path, "env.log"));
      final script = File(
        path.join(
          tempDir.path,
          Platform.isWindows ? "upload.cmd" : "upload.sh",
        ),
      );
      if (Platform.isWindows) {
        await script.writeAsString("""
@echo off
if not "%~x0"==".cmd" exit /b 65
> "${logFile.path}" echo %DESKTOP_UPDATER_PUBLISH_MANIFEST%
>> "${logFile.path}" echo %DESKTOP_UPDATER_ARTIFACT_KIND%
""");
      } else {
        await script.writeAsString("""
#!/bin/sh
printf '%s\\n' "\$DESKTOP_UPDATER_PUBLISH_MANIFEST" > "${logFile.path}"
printf '%s\\n' "\$DESKTOP_UPDATER_ARTIFACT_KIND" >> "${logFile.path}"
""");
        final chmod = await Process.run("chmod", ["+x", script.path]);
        expect(chmod.exitCode, 0);
      }

      final localRoot = Directory(path.join(tempDir.path, "dist"));
      final manifest = testPublishManifest(localRoot: localRoot.path);
      await _writePayload(localRoot, manifest);
      const provider = CustomCommandUploadProvider();
      await provider.uploadVersionedFiles(
        localRoot: localRoot,
        manifest: manifest,
        config: CustomCommandUploadConfig(command: script.path),
        output: StringBuffer(),
      );

      expect(
        await logFile.readAsString(),
        contains(".desktop_updater_publish.json"),
      );
      expect(await logFile.readAsString(), contains("zip"));
      expect(await logFile.readAsString(), isNot(contains(localRoot.path)));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("windows custom command preserves quoted script paths", () async {
    final tempDir = await Directory.systemTemp.createTemp("custom_upload_");
    try {
      final calls = <_CommandCall>[];
      String? wrapperScript;
      final provider = CustomCommandUploadProvider(
        isWindows: true,
        runProcess: (
          executable,
          arguments, {
          environment,
        }) async {
          calls.add(
            _CommandCall(
              executable: executable,
              arguments: arguments,
              environment: environment,
            ),
          );
          wrapperScript = await File(arguments.last).readAsString();
          return ProcessResult(123, 0, "uploaded\n", "");
        },
      );
      final output = StringBuffer();
      final localRoot = Directory(path.join(tempDir.path, "dist"));
      final manifest = testPublishManifest(localRoot: localRoot.path);
      await _writePayload(localRoot, manifest);

      await provider.uploadVersionedFiles(
        localRoot: localRoot,
        manifest: manifest,
        config: const CustomCommandUploadConfig(
          command: r'dart "C:\repo path\copy_updates.dart"',
        ),
        output: output,
      );

      expect(output.toString(), contains("uploaded"));
      expect(calls, hasLength(1));
      expect(calls.single.executable, "cmd");
      expect(
        calls.single.arguments.take(4),
        ["/d", "/e:on", "/v:off", "/c"],
      );
      expect(calls.single.arguments.last, endsWith("upload.cmd"));
      expect(
        wrapperScript,
        contains(r'dart "C:\repo path\copy_updates.dart"'),
      );
      expect(
        calls.single.environment?["DESKTOP_UPDATER_LOCAL_ROOT"],
        isNot(path.join(tempDir.path, "dist")),
      );
      expect(
        calls.single.environment?["DESKTOP_UPDATER_UPLOAD_PHASE"],
        "versioned",
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("index phase validates strict receipt against expected revision",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("custom_upload_");
    try {
      final localRoot = Directory(path.join(tempDir.path, "dist"));
      final manifest = testPublishManifest(localRoot: localRoot.path);
      await _writePayload(localRoot, manifest);
      final expectedRevision = RemoteIndexRevision.present(
        sha256: "b" * 64,
        etag: '"old"',
      );
      final calls = <_CommandCall>[];
      final provider = CustomCommandUploadProvider(
        runProcess: (
          executable,
          arguments, {
          environment,
        }) async {
          calls.add(
            _CommandCall(
              executable: executable,
              arguments: arguments,
              environment: environment,
            ),
          );
          final receiptFile =
              File(environment!["DESKTOP_UPDATER_INDEX_PUBLISH_RECEIPT"]!);
          await receiptFile.writeAsString("""
{
  "schemaVersion": 1,
  "observedPriorRevision": {
    "absent": false,
    "sha256": "${"b" * 64}",
    "etag": "\\"old\\""
  },
  "publishedSha256": "${await sha256File(File(path.join(localRoot.path, manifest.appArchive.path)))}",
  "mechanism": "conditionalWrite",
  "leaseEvidenceSha256": null
}
""");
          return ProcessResult(0, 0, "index uploaded\n", "");
        },
      );

      final receipt = await provider.uploadAppArchive(
        localRoot: localRoot,
        manifest: manifest,
        config: const CustomCommandUploadConfig(command: "upload-index"),
        output: StringBuffer(),
        expectedRevision: expectedRevision,
      );

      expect(receipt.observedPriorRevision, expectedRevision);
      expect(receipt.mechanism, IndexPublishMechanism.conditionalWrite);
      expect(
          calls.single.environment?["DESKTOP_UPDATER_UPLOAD_PHASE"], "index");
      expect(
        calls.single
            .environment?["DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_SHA256"],
        "b" * 64,
      );
      expect(
        calls.single.environment,
        isNot(containsPair("DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_ABSENT", "")),
      );
      expect(
        calls.single.environment?["DESKTOP_UPDATER_LOCAL_ROOT"],
        isNot(localRoot.path),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  group("strict index publish receipt parser", () {
    test("rejects unknown keys, duplicate keys, BOM, bad digest, and evidence",
        () async {
      final cases = <String, Matcher>{
        _receiptJson(extra: '"extra": true,'): throwsA(isA<FormatException>()),
        '{"schemaVersion":1,"schemaVersion":1}':
            throwsA(isA<FormatException>()),
        '${String.fromCharCodes([0xfeff])}${_receiptJson()}':
            throwsA(isA<FormatException>()),
        _receiptJson(publishedSha256: "A" * 64):
            throwsA(isA<FormatException>()),
        _receiptJson(absent: true, observedSha256: "b" * 64):
            throwsA(isA<FormatException>()),
        _receiptJson(
          mechanism: "exclusiveLease",
          leaseEvidenceSha256: null,
        ): throwsA(isA<FormatException>()),
      };

      for (final entry in cases.entries) {
        final tempDir =
            await Directory.systemTemp.createTemp("receipt_parser_");
        try {
          final file = File(path.join(tempDir.path, "receipt.json"));
          await file.writeAsString(entry.key);
          await expectLater(readStrictIndexPublishReceipt(file), entry.value);
        } finally {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}

class _CommandCall {
  const _CommandCall({
    required this.executable,
    required this.arguments,
    required this.environment,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

PublishManifest testPublishManifest({required String localRoot}) {
  return PublishManifest(
    schemaVersion: 1,
    baseUrl: Uri.parse("https://updates.example.com/"),
    localRoot: localRoot,
    appArchive: PublishManifestFile(
      path: "app-archive.json",
      url: Uri.parse("https://updates.example.com/app-archive.json"),
    ),
    release: PublishManifestRelease(
      version: "2.0.1",
      buildNumber: 201,
      platform: "macos",
      channel: "stable",
      path: "releases/2.0.1/macos/release.json",
      url: Uri.parse(
        "https://updates.example.com/releases/2.0.1/macos/release.json",
      ),
    ),
    artifact: PublishManifestArtifact(
      path: "releases/2.0.1/macos/Example-2.0.1-macos.zip",
      url: Uri.parse(
        "https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip",
      ),
      sha256:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      length: 12,
    ),
  );
}

Future<void> _writePayload(
  Directory localRoot,
  PublishManifest manifest,
) async {
  await File(path.join(localRoot.path, ".desktop_updater_publish.json"))
      .create(recursive: true);
  await manifest.writeTo(
    File(path.join(localRoot.path, ".desktop_updater_publish.json")),
  );
  await File(path.join(localRoot.path, manifest.appArchive.path))
      .writeAsString("index");
  await File(path.join(localRoot.path, manifest.release.path))
      .create(recursive: true);
  await File(path.join(localRoot.path, manifest.release.path))
      .writeAsString("release");
  await File(path.join(localRoot.path, manifest.artifact.path))
      .create(recursive: true);
  await File(path.join(localRoot.path, manifest.artifact.path))
      .writeAsString("artifact");
}

String _receiptJson({
  bool absent = true,
  String? observedSha256,
  String publishedSha256 =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  String mechanism = "conditionalWrite",
  String? leaseEvidenceSha256,
  String extra = "",
}) {
  return """
{
  "schemaVersion": 1,
  $extra
  "observedPriorRevision": {
    "absent": $absent,
    "sha256": ${observedSha256 == null ? "null" : '"$observedSha256"'},
    "etag": null
  },
  "publishedSha256": "$publishedSha256",
  "mechanism": "$mechanism",
  "leaseEvidenceSha256": ${leaseEvidenceSha256 == null ? "null" : '"$leaseEvidenceSha256"'}
}
""";
}
