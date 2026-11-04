import "dart:io";

import "package:desktop_updater/src/release_cli/inno/inno_output_name.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  for (final template in <String, String>{
    "v{version}({buildNumber})-{platform}": "v1.0.0(3)-windows",
    "{appName} v{version} ({buildNumber})-{platform}": "应用 v1.0.0 (3)-windows",
    "{version}-{version}-{platform}": "1.0.0-1.0.0-windows",
  }.entries) {
    test("expands generated output name ${template.key}", () async {
      expect(
        await resolveInnoOutputBaseName(
          config: InnoPublishConfig(
            kind: "inno",
            mode: "generated",
            outputBaseName: template.key,
          ),
          appName: "应用.exe",
          version: "1.0.0",
          buildNumber: 3,
          platform: "windows",
        ),
        template.value,
      );
    });
  }

  test("rejects a build number placeholder when metadata has no build number",
      () async {
    await expectLater(
      resolveInnoOutputBaseName(
        config: const InnoPublishConfig(
          kind: "inno",
          mode: "generated",
          outputBaseName: "v{version}({buildNumber})-{platform}",
        ),
        appName: "Example",
        version: "1.0.0",
        platform: "windows",
      ),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        "message",
        contains("release has no build number"),
      )),
    );
  });

  for (final name in [
    "{unknown}",
    "{version",
    "../{version}",
    r"folder\{version}",
    "{version}:setup",
    "{version}\nsetup",
  ]) {
    test("rejects unsafe or unknown filename template $name", () async {
      await expectLater(
        resolveInnoOutputBaseName(
          config: InnoPublishConfig(
            kind: "inno",
            mode: "generated",
            outputBaseName: name,
          ),
          appName: "Example",
          version: "1.0.0",
          platform: "windows",
        ),
        throwsFormatException,
      );
    });
  }

  test("validates substituted metadata before using the filename", () async {
    await expectLater(
      resolveInnoOutputBaseName(
        config: const InnoPublishConfig(
          kind: "inno",
          mode: "generated",
          outputBaseName: "{version}-{platform}",
        ),
        appName: "Example",
        version: "../outside",
        platform: "windows",
      ),
      throwsFormatException,
    );
  });

  for (final dynamicName in [false, true]) {
    test("expands script output name (dynamic: $dynamicName)", () async {
      final root = await Directory.systemTemp.createTemp("inno_output_name_");
      addTearDown(() => root.delete(recursive: true));
      final script = File(path.join(root.path, "setup.iss"));
      await script.writeAsString("""
#define SetupBaseName "v1.0.0(3)-windows"
[Setup]
OutputBaseFilename=${dynamicName ? "{#SetupBaseName}" : "v1.0.0(3)-windows"}
""");
      expect(
        await resolveInnoOutputBaseName(
          config: InnoPublishConfig(
            kind: "inno",
            mode: "script",
            script: script.path,
            outputBaseName: "v{version}({buildNumber})-{platform}",
          ),
          appName: "Example",
          version: "1.0.0",
          buildNumber: 3,
          platform: "windows",
        ),
        "v1.0.0(3)-windows",
      );
    });
  }

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
