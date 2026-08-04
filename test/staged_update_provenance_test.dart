import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

const _nonce = "123e4567-e89b-42d3-a456-426614174000";
const _descriptorSha =
    "1111111111111111111111111111111111111111111111111111111111111111";
const _artifactSha =
    "2222222222222222222222222222222222222222222222222222222222222222";

void main() {
  test("creates an exclusive updater-owned child and preserves its parent",
      () async {
    final parent = await Directory.systemTemp.createTemp("owned_stage_parent_");
    final sentinel = File(path.join(parent.path, "sentinel.txt"));
    await sentinel.writeAsString("caller owned");
    try {
      final stage = await createOwnedStagingDirectory(
        parent: parent,
        nonce: _nonce,
      );

      expect(path.dirname(stage.path), await parent.resolveSymbolicLinks());
      expect(path.basename(stage.path), "desktop_updater_stage_$_nonce");
      expect(sentinel.readAsStringSync(), "caller owned");
      await expectLater(
        createOwnedStagingDirectory(parent: parent, nonce: _nonce),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await parent.delete(recursive: true);
    }
  });

  test("rejects a symbolic-link staging parent", () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp("owned_stage_link_");
    final realParent = await Directory(path.join(root.path, "real")).create();
    final linkedParent = Link(path.join(root.path, "linked"));
    await linkedParent.create(realParent.path);
    try {
      await expectLater(
        createOwnedStagingDirectory(parent: Directory(linkedParent.path)),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("writes canonical sorted inventory and verifies marker digest",
      () async {
    final parent = await Directory.systemTemp.createTemp("stage_inventory_");
    try {
      final stage = await createOwnedStagingDirectory(
        parent: parent,
        nonce: _nonce,
      );
      await Directory(path.join(stage.path, "bin")).create();
      await File(path.join(stage.path, "z.txt")).writeAsString("last");
      await File(path.join(stage.path, "bin", "app"))
          .writeAsString("executable");
      if (!Platform.isWindows) {
        await Link(path.join(stage.path, "current")).create("bin/app");
      }

      final state = await writeStagedUpdateProvenance(
        stageRoot: stage,
        nonce: _nonce,
        packageId: "com.example.app",
        descriptorSha256: _descriptorSha,
        artifactSha256: _artifactSha,
      );
      final verified = await verifyStagedUpdateProvenance(
        stageRoot: stage,
        expectedMarkerSha256: state.markerSha256,
      );

      expect(verified.nonce, _nonce);
      expect(verified.packageId, "com.example.app");
      expect(verified.descriptorSha256, _descriptorSha);
      expect(verified.artifactSha256, _artifactSha);
      final paths = verified.entries.map((entry) => entry.path).toList();
      expect(paths, [...paths]..sort(_compareUtf8));
      expect(
        paths,
        Platform.isWindows
            ? ["bin", "bin/app", "z.txt"]
            : ["bin", "bin/app", "current", "z.txt"],
      );
      expect(
        verified.entries.firstWhere((entry) => entry.path == "bin").toJson(),
        {"kind": "directory", "length": 0, "path": "bin"},
      );
      if (!Platform.isWindows) {
        expect(
          verified.entries
              .firstWhere((entry) => entry.path == "current")
              .toJson(),
          {
            "kind": "symlink",
            "length": 0,
            "path": "current",
            "target": "bin/app",
          },
        );
      }
      expect(
        File(path.join(stage.path, stagedUpdateProvenanceFileName))
            .readAsStringSync(),
        state.provenance.canonicalJson,
      );
    } finally {
      await parent.delete(recursive: true);
    }
  });

  for (final mutation in <String, Future<void> Function(Directory)>{
    "ZIP artifact byte": (stage) async {
      await File(path.join(stage.path, ".desktop_updater_artifact.zip"))
          .writeAsBytes([1, 9, 3]);
    },
    "Inno installer byte": (stage) async {
      await File(path.join(stage.path, "installer.exe"))
          .writeAsBytes([4, 9, 6]);
    },
    "PKG installer byte": (stage) async {
      await File(path.join(stage.path, "installer.pkg"))
          .writeAsBytes([7, 9, 9]);
    },
    "release manifest": (stage) async {
      await File(
              path.join(stage.path, ".desktop_updater_release_manifest.json"))
          .writeAsString('{"tampered":true}');
    },
    "provenance inventory": (stage) async {
      final marker = File(
        path.join(stage.path, stagedUpdateProvenanceFileName),
      );
      final value =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      (value["entries"] as List).removeLast();
      await marker.writeAsString(jsonEncode(value));
    },
    if (!Platform.isWindows)
      "symbolic-link target": (stage) async {
        final link = Link(path.join(stage.path, "current"));
        await link.delete();
        await link.create("other.bin");
      },
  }.entries) {
    test("rejects ${mutation.key} tampering before handoff", () async {
      final parent = await Directory.systemTemp.createTemp("stage_tamper_");
      try {
        final stage = await _writeFixtureStage(parent);
        final marker = await readStagedUpdateProvenance(stageRoot: stage);
        await mutation.value(stage);

        await expectLater(
          verifyStagedUpdateProvenance(
            stageRoot: stage,
            expectedMarkerSha256: marker.markerSha256,
          ),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await parent.delete(recursive: true);
      }
    });
  }

  test("cleanup deletes only the marker-bound nonce child", () async {
    final parent = await Directory.systemTemp.createTemp("owned_cleanup_");
    final sentinel = File(path.join(parent.path, "sentinel.txt"));
    await sentinel.writeAsString("preserve");
    try {
      final stage = await _writeFixtureStage(parent);
      await expectLater(
        deleteOwnedStagingDirectory(
          parent: parent,
          stageRoot: stage,
          nonce: "223e4567-e89b-42d3-a456-426614174000",
        ),
        throwsA(isA<FormatException>()),
      );
      expect(stage.existsSync(), isTrue);
      expect(sentinel.readAsStringSync(), "preserve");

      await deleteOwnedStagingDirectory(
        parent: parent,
        stageRoot: stage,
        nonce: _nonce,
      );
      expect(stage.existsSync(), isFalse);
      expect(parent.existsSync(), isTrue);
      expect(sentinel.readAsStringSync(), "preserve");
    } finally {
      await parent.delete(recursive: true);
    }
  });
}

Future<Directory> _writeFixtureStage(Directory parent) async {
  final stage = await createOwnedStagingDirectory(
    parent: parent,
    nonce: _nonce,
  );
  await File(path.join(stage.path, "payload.bin")).writeAsBytes([1, 2, 3]);
  await File(path.join(stage.path, ".desktop_updater_artifact.zip"))
      .writeAsBytes([1, 2, 3]);
  await File(path.join(stage.path, "installer.exe")).writeAsBytes([4, 5, 6]);
  await File(path.join(stage.path, "installer.pkg")).writeAsBytes([7, 8, 9]);
  await File(path.join(stage.path, ".desktop_updater_release_manifest.json"))
      .writeAsString('{"schemaVersion":3}');
  await File(path.join(stage.path, "other.bin")).writeAsBytes([4]);
  if (!Platform.isWindows) {
    await Link(path.join(stage.path, "current")).create("payload.bin");
  }
  await writeStagedUpdateProvenance(
    stageRoot: stage,
    nonce: _nonce,
    packageId: "com.example.app",
    descriptorSha256: _descriptorSha,
    artifactSha256: _artifactSha,
  );
  return stage;
}

int _compareUtf8(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final common = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < common; index += 1) {
    final comparison = leftBytes[index].compareTo(rightBytes[index]);
    if (comparison != 0) return comparison;
  }
  return leftBytes.length.compareTo(rightBytes.length);
}
