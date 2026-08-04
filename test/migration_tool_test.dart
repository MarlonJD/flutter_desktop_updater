import "dart:io";

import "package:desktop_updater/src/migrate/migration_tool.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("dry-run reports safe edits without changing files", () async {
    final fixture = await _createMigrationFixture();
    addTearDown(() => fixture.deleteSync(recursive: true));

    final dartFile = File(path.join(fixture.path, "lib", "main.dart"));
    final originalDart = await dartFile.readAsString();

    final result = await migrateDesktopUpdaterProject(
      root: fixture,
      apply: false,
    );

    expect(result.changedFiles, isEmpty);
    expect(result.pendingEdits, hasLength(2));
    expect(
      result.pendingEdits.map((edit) => edit.kind),
      containsAll(<MigrationEditKind>[
        MigrationEditKind.pubspecConstraint,
        MigrationEditKind.safeRename,
      ]),
    );
    expect(
      result.findings.map((finding) => finding.kind),
      containsAll(<MigrationFindingKind>[
        MigrationFindingKind.legacyGetter,
        MigrationFindingKind.oldCliCommand,
      ]),
    );
    expect(await dartFile.readAsString(), originalDart);
  });

  test("apply rewrites pubspec and safe Dart renames", () async {
    final fixture = await _createMigrationFixture();
    addTearDown(() => fixture.deleteSync(recursive: true));

    final result = await migrateDesktopUpdaterProject(
      root: fixture,
      apply: true,
    );

    expect(
      result.changedFiles.map((file) => path.basename(file.path)),
      containsAll(<String>["pubspec.yaml", "main.dart"]),
    );

    final pubspec = await File(
      path.join(fixture.path, "pubspec.yaml"),
    ).readAsString();
    expect(pubspec, contains("desktop_updater: ^2.0.0"));
    expect(pubspec, isNot(contains("desktop_updater: ^1.3.0")));

    final dartCode = await File(
      path.join(fixture.path, "lib", "main.dart"),
    ).readAsString();
    expect(dartCode, contains("skipInitialVersionCheck: true"));
    expect(dartCode, contains("manual.skipInitialVersionCheck"));
    expect(dartCode, isNot(contains("skipCheckVersion")));
    expect(dartCode, isNot(contains("getSkipCheckVersion")));
  });

  test("skips generated Dart files", () async {
    final fixture = await _createMigrationFixture();
    addTearDown(() => fixture.deleteSync(recursive: true));
    final generated = File(path.join(fixture.path, "lib", "model.g.dart"));
    await generated.writeAsString("""
import "package:desktop_updater/updater_controller.dart";

final controller = DesktopUpdaterController(skipCheckVersion: true);
""");

    final result = await migrateDesktopUpdaterProject(
      root: fixture,
      apply: true,
    );

    expect(
      result.changedFiles.map((file) => file.path),
      isNot(contains(generated.path)),
    );
    expect(await generated.readAsString(), contains("skipCheckVersion"));
  });

  test("skips migrator implementation when run from package root", () async {
    final fixture = await _createMigrationFixture(name: "desktop_updater");
    addTearDown(() => fixture.deleteSync(recursive: true));

    final migrator = File(
      path.join(fixture.path, "lib", "src", "migrate", "migration_tool.dart"),
    );
    await migrator.parent.create(recursive: true);
    await migrator.writeAsString("""
const safeReplacement = "skipCheckVersion:";
const legacyFinding = "needUpdate";
""");

    final migratorTest = File(
      path.join(fixture.path, "test", "migration_tool_test.dart"),
    );
    await migratorTest.parent.create(recursive: true);
    await migratorTest.writeAsString("""
const fixtureCode = "skipCheckVersion:";
""");

    final result = await migrateDesktopUpdaterProject(
      root: fixture,
      apply: false,
    );

    final reportedFiles = <String>{
      for (final edit in result.pendingEdits) edit.location.file.path,
      for (final finding in result.findings) finding.location.file.path,
    };
    expect(reportedFiles, isNot(contains(migrator.path)));
    expect(reportedFiles, isNot(contains(migratorTest.path)));
  });

  test("version-aware migration lanes enforce the source-major matrix",
      () async {
    final cases = <({
      int from,
      String constraint,
      String? target,
      bool mismatch,
    })>[
      (from: 1, constraint: "^1.4.0", target: "^2.0.0", mismatch: false),
      (from: 1, constraint: "^2.0.0", target: null, mismatch: false),
      (from: 1, constraint: "^2.7.0", target: null, mismatch: true),
      (from: 1, constraint: "^3.0.0", target: null, mismatch: true),
      (from: 2, constraint: "^1.9.0", target: null, mismatch: true),
      (from: 2, constraint: "^2.7.0", target: "^3.0.0", mismatch: false),
      (from: 2, constraint: "^3.0.0", target: null, mismatch: false),
    ];

    for (final migration in cases) {
      final fixture = await _createVersionFixture(migration.constraint);
      addTearDown(() => fixture.deleteSync(recursive: true));
      final pubspec = File(path.join(fixture.path, "pubspec.yaml"));
      final original = await pubspec.readAsString();

      final result = await migrateDesktopUpdaterProject(
        root: fixture,
        fromMajor: migration.from,
        apply: true,
      );

      expect(
        result.hasSourceMajorMismatch,
        migration.mismatch,
        reason: "--from ${migration.from} with ${migration.constraint}",
      );
      if (migration.mismatch) {
        expect(await pubspec.readAsString(), original);
        expect(result.changedFiles, isEmpty);
      } else if (migration.target != null) {
        expect(await pubspec.readAsString(), contains(migration.target!));
      } else {
        expect(await pubspec.readAsString(), original);
        expect(result.changedFiles, isEmpty);
      }
    }
  });

  test("2.x migration reports removed contract inputs without inventing values",
      () async {
    final fixture = await _createVersionFixture("^2.7.0");
    addTearDown(() => fixture.deleteSync(recursive: true));
    await File(path.join(fixture.path, "lib", "main.dart")).writeAsString("""
void migrate() {
  const diagnosticsLogPath = "native.log";
  scheduleInstallAndRelaunch();
}
""");

    final result = await migrateDesktopUpdaterProject(
      root: fixture,
      fromMajor: 2,
      apply: true,
    );

    expect(result.hasSourceMajorMismatch, isFalse);
    expect(result.findings.map((finding) => finding.kind),
        contains(MigrationFindingKind.manualReview));
    expect(
      result.changedFiles.map((file) => path.basename(file.path)),
      contains("pubspec.yaml"),
    );
    final dartCode =
        await File(path.join(fixture.path, "lib", "main.dart")).readAsString();
    expect(dartCode, contains("scheduleInstallAndRelaunch"));
    expect(dartCode, contains("diagnosticsLogPath"));
  });
}

Future<Directory> _createMigrationFixture({String name = "fixture_app"}) async {
  final root = await Directory.systemTemp.createTemp(
    "desktop_updater_migrate_test_",
  );
  await Directory(path.join(root.path, "lib")).create(recursive: true);
  await Directory(path.join(root.path, "tool")).create(recursive: true);

  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: $name
dependencies:
  flutter:
    sdk: flutter
  desktop_updater: ^1.3.0
""");

  await File(path.join(root.path, "lib", "main.dart")).writeAsString("""
import "package:desktop_updater/updater_controller.dart";

void configure(DesktopUpdaterController controller) {
  final manual = DesktopUpdaterController(
    skipCheckVersion: true,
  );
  if (controller.needUpdate && controller.isDownloaded) {
    print(controller.downloadProgress);
  }
  print(manual.getSkipCheckVersion);
}
""");

  await File(path.join(root.path, "tool", "release.sh")).writeAsString("""
dart run desktop_updater:release macos
dart run desktop_updater:archive macos
""");

  return root;
}

Future<Directory> _createVersionFixture(String constraint) async {
  final root = await Directory.systemTemp.createTemp(
    "desktop_updater_migrate_matrix_",
  );
  await Directory(path.join(root.path, "lib")).create(recursive: true);
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: fixture_app
dependencies:
  desktop_updater: $constraint
""");
  return root;
}
