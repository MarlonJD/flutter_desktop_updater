import "dart:io";

import "package:desktop_updater/src/release_cli/inno/inno_output_name.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("uses configured outputBaseName", () async {
    final name = await resolveInnoOutputBaseName(
      config: const InnoPublishConfig(
        kind: "inno",
        mode: "generated",
        outputBaseName: "ExampleSetup",
      ),
      appName: "Example",
      version: "2.4.6",
      platform: "windows",
    );

    expect(name, "ExampleSetup");
  });

  test("uses generated default outputBaseName", () async {
    final name = await resolveInnoOutputBaseName(
      config: const InnoPublishConfig(kind: "inno", mode: "generated"),
      appName: "Example.exe",
      version: "2.4.6",
      platform: "windows",
    );

    expect(name, "Example-2.4.6-windows-setup");
  });

  test("reads literal OutputBaseFilename from script mode", () async {
    final root = await Directory.systemTemp.createTemp("inno_output_name_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final script = File(path.join(root.path, "setup.iss"));
    await script.writeAsString("""
[Setup]
OutputBaseFilename=ScriptSetup
""");

    final name = await resolveInnoOutputBaseName(
      config: InnoPublishConfig(
        kind: "inno",
        mode: "script",
        script: script.path,
      ),
      appName: "Example",
      version: "2.4.6",
      platform: "windows",
    );

    expect(name, "ScriptSetup");
  });

  test("rejects configured outputBaseName that conflicts with script",
      () async {
    final root = await Directory.systemTemp.createTemp("inno_output_name_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final script = File(path.join(root.path, "setup.iss"));
    await script.writeAsString("""
[Setup]
OutputBaseFilename=ScriptSetup
""");

    expect(
      () => resolveInnoOutputBaseName(
        config: InnoPublishConfig(
          kind: "inno",
          mode: "script",
          script: script.path,
          outputBaseName: "ConfigSetup",
        ),
        appName: "Example",
        version: "2.4.6",
        platform: "windows",
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("windows.installer.outputBaseName does not match"),
        ),
      ),
    );
  });

  test("requires outputBaseName when script output name is dynamic", () async {
    final root = await Directory.systemTemp.createTemp("inno_output_name_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final script = File(path.join(root.path, "setup.iss"));
    await script.writeAsString("""
#define SetupBaseName "ScriptSetup"
[Setup]
OutputBaseFilename={#SetupBaseName}
""");

    expect(
      () => resolveInnoOutputBaseName(
        config: InnoPublishConfig(
          kind: "inno",
          mode: "script",
          script: script.path,
        ),
        appName: "Example",
        version: "2.4.6",
        platform: "windows",
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("windows.installer.outputBaseName is required"),
        ),
      ),
    );
  });

  test("uses configured outputBaseName when script output name is dynamic",
      () async {
    final root = await Directory.systemTemp.createTemp("inno_output_name_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final script = File(path.join(root.path, "setup.iss"));
    await script.writeAsString("""
#define SetupBaseName "ScriptSetup"
[Setup]
OutputBaseFilename={#SetupBaseName}
""");

    final name = await resolveInnoOutputBaseName(
      config: InnoPublishConfig(
        kind: "inno",
        mode: "script",
        script: script.path,
        outputBaseName: "ConfigSetup",
      ),
      appName: "Example",
      version: "2.4.6",
      platform: "windows",
    );

    expect(name, "ConfigSetup");
  });
}
