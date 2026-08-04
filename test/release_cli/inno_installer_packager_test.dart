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
    await writeProtectedHelperInputs(input);
    await writeProtectedHelperCMakeCache(root);
    final output = Directory(path.join(root.path, "out"));
    String? identityDuringCompile;

    final packager = InnoInstallerPackager(
      compileInno: ({required scriptFile, required outputExe}) async {
        final identity = File(
          path.join(
            output.path,
            "Example-2.5.0-windows-setup.install-identity.json",
          ),
        );
        identityDuringCompile = await identity.readAsString();
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
        privilegesRequired: "admin",
        protectedHelperInstallDir:
            r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
      ),
    );

    expect(result.artifact.path, endsWith("-setup.exe"));
    final json = jsonDecode(await result.releaseFile.readAsString())
        as Map<String, dynamic>;
    final descriptor = ReleaseDescriptor.fromJson(json);
    expect(descriptor.artifact.kind, "innoInstaller");
    expect(descriptor.install.strategy, "innoInstaller");
    expect(descriptor.install.inno!.silentArgs, contains("/VERYSILENT"));
    final script = await File(
      path.join(output.path, "Example-2.5.0-windows-setup.iss"),
    ).readAsString();
    expect(script, contains("DesktopUpdaterExpectedHelperSha256"));
    expect(script, contains("DesktopUpdaterExpectedPolicySha256"));
    expect(script, contains(".desktop_updater_install_identity.json"));
    expect(
      identityDuringCompile,
      '{"packageId":"com.example.app","schemaVersion":1}',
    );
    expect(
      await File(
        path.join(
          output.path,
          "Example-2.5.0-windows-setup.install-identity.json",
        ),
      ).readAsString(),
      '{"packageId":"com.example.app","schemaVersion":1}',
    );
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
    await writeProtectedHelperInputs(input);
    await writeProtectedHelperCMakeCache(root);
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
        privilegesRequired: "admin",
        protectedHelperInstallDir:
            r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
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

  test("rejects a generated installer without protected helper inputs",
      () async {
    final root = await Directory.systemTemp.createTemp("inno_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final input = Directory(path.join(root.path, "Release"));
    await input.create();
    await File(path.join(input.path, "Example.exe")).writeAsString("exe");
    await writeProtectedHelperCMakeCache(root);
    var compilerCalled = false;
    final packager = InnoInstallerPackager(
      compileInno: ({required scriptFile, required outputExe}) async {
        compilerCalled = true;
      },
    );

    await expectLater(
      packager.package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: Directory(path.join(root.path, "out")),
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
          privilegesRequired: "admin",
          protectedHelperInstallDir:
              r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
        ),
      ),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          "message",
          contains("desktop_updater_install_helper.exe"),
        ),
      ),
    );
    expect(compilerCalled, isFalse);
  });

  test("rejects a helper directory that differs from the compiled client",
      () async {
    final root = await Directory.systemTemp.createTemp("inno_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final input = Directory(path.join(root.path, "Release"));
    await input.create();
    await File(path.join(input.path, "Example.exe")).writeAsString("exe");
    await writeProtectedHelperInputs(input);
    await writeProtectedHelperCMakeCache(
      root,
      installDir:
          r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.4.0",
    );
    var compilerCalled = false;
    final packager = InnoInstallerPackager(
      compileInno: ({required scriptFile, required outputExe}) async {
        compilerCalled = true;
      },
    );

    await expectLater(
      packager.package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: Directory(path.join(root.path, "out")),
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
          privilegesRequired: "admin",
          protectedHelperInstallDir:
              r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR"),
        ),
      ),
    );
    expect(compilerCalled, isFalse);
  });

  test("rejects a CMake cache without the protected helper compile path",
      () async {
    final root = await Directory.systemTemp.createTemp("inno_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final input = Directory(path.join(root.path, "Release"));
    await input.create();
    await File(path.join(input.path, "Example.exe")).writeAsString("exe");
    await writeProtectedHelperInputs(input);
    await File(path.join(root.path, "CMakeCache.txt"))
        .writeAsString("CMAKE_BUILD_TYPE:STRING=Release\n");
    var compilerCalled = false;
    final packager = InnoInstallerPackager(
      compileInno: ({required scriptFile, required outputExe}) async {
        compilerCalled = true;
      },
    );

    await expectLater(
      packager.package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: Directory(path.join(root.path, "out")),
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
          privilegesRequired: "admin",
          protectedHelperInstallDir:
              r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("does not define"),
        ),
      ),
    );
    expect(compilerCalled, isFalse);
  });

  test("rejects an app payload that already owns the reserved identity marker",
      () async {
    final root = await Directory.systemTemp.createTemp("inno_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final input = Directory(path.join(root.path, "Release"));
    await input.create();
    await File(path.join(input.path, "Example.exe")).writeAsString("exe");
    await File(
      path.join(input.path, ".DESKTOP_UPDATER_INSTALL_IDENTITY.JSON"),
    ).writeAsString("untrusted");
    await writeProtectedHelperInputs(input);
    await writeProtectedHelperCMakeCache(root);
    var compilerCalled = false;

    await expectLater(
      InnoInstallerPackager(
        compileInno: ({required scriptFile, required outputExe}) async {
          compilerCalled = true;
        },
      ).package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: Directory(path.join(root.path, "out")),
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
          privilegesRequired: "admin",
          protectedHelperInstallDir:
              r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("reserved installed identity marker"),
        ),
      ),
    );
    expect(compilerCalled, isFalse);
  });
}

Future<void> writeProtectedHelperInputs(Directory input) async {
  await File(path.join(input.path, "desktop_updater_install_helper.exe"))
      .writeAsString("signed-helper-fixture");
  await File(path.join(input.path, "desktop_updater_helper_policy.json"))
      .writeAsString('{"fixture":"sealed-policy"}');
}

Future<void> writeProtectedHelperCMakeCache(
  Directory root, {
  String installDir =
      r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
}) async {
  await File(path.join(root.path, "CMakeCache.txt")).writeAsString(
    "DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR:PATH=$installDir\n",
  );
}
