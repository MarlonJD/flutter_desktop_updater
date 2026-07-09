import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_installer_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("packages an Inno installer descriptor", () async {
    final root = await Directory.systemTemp.createTemp("inno_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final input = Directory(path.join(root.path, "Release"));
    await input.create();
    await File(path.join(input.path, "Example.exe")).writeAsString("exe");
    final output = Directory(path.join(root.path, "out"));

    final packager = InnoInstallerPackager(
      compileInno: ({required scriptFile, required outputExe}) async {
        await outputExe.writeAsBytes([1, 2, 3]);
      },
    );

    final result = await packager.package(
      ReleasePackageRequest(
        input: input,
        outputDirectory: output,
        packageId: "com.example.app",
        appName: "Example",
        version: "2.5.0",
        buildNumber: 250,
        platform: "windows",
        channel: "stable",
        artifactUrl: Uri.parse("https://cdn.example.com/Example-setup.exe"),
        installStrategy: "innoInstaller",
        minimumUpdaterVersion: "2.5.0",
      ),
      config: const InnoPublishConfig(
        kind: "inno",
        mode: "generated",
        appId: "com.example.app",
      ),
    );

    expect(result.artifact.path, endsWith("-setup.exe"));
    final json = jsonDecode(await result.releaseFile.readAsString())
        as Map<String, dynamic>;
    final descriptor = ReleaseDescriptor.fromJson(json);
    expect(descriptor.artifact.kind, "innoInstaller");
    expect(descriptor.install.strategy, "innoInstaller");
    expect(descriptor.install.inno!.silentArgs, contains("/VERYSILENT"));
  });

  test("uses custom output base name in generated mode", () async {
    final root = await Directory.systemTemp.createTemp("inno_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final input = Directory(path.join(root.path, "Release"));
    await input.create();
    await File(path.join(input.path, "Example.exe")).writeAsString("exe");
    final output = Directory(path.join(root.path, "out"));

    final packager = InnoInstallerPackager(
      compileInno: ({required scriptFile, required outputExe}) async {
        await outputExe.writeAsBytes([1, 2, 3]);
      },
    );

    final result = await packager.package(
      ReleasePackageRequest(
        input: input,
        outputDirectory: output,
        packageId: "com.example.app",
        appName: "Example",
        version: "2.5.0",
        buildNumber: 250,
        platform: "windows",
        channel: "stable",
        artifactUrl: Uri.parse("https://cdn.example.com/CustomSetup.exe"),
        installStrategy: "innoInstaller",
        minimumUpdaterVersion: "2.5.0",
      ),
      config: const InnoPublishConfig(
        kind: "inno",
        mode: "generated",
        appId: "com.example.app",
      ),
      outputBaseName: "CustomSetup",
    );

    expect(path.basename(result.artifact.path), "CustomSetup.exe");
    expect(
      await result.releaseFile.readAsString(),
      contains('"url": "https://cdn.example.com/CustomSetup.exe"'),
    );
    expect(
      await File(path.join(output.path, "CustomSetup.iss")).readAsString(),
      contains("OutputBaseFilename=CustomSetup"),
    );
  });
}
