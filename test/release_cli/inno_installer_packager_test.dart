import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_installer_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

const _testCertificateSha256 =
    "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";

void main() {
  for (final executableRelativePath in <String?>[null, "Missing.exe"]) {
    test("rejects unavailable application metadata: $executableRelativePath",
        () async {
      final root = await Directory.systemTemp.createTemp("inno_executable_");
      addTearDown(() => root.delete(recursive: true));
      final input = Directory(path.join(root.path, "Release"));
      await input.create();
      await File(path.join(input.path, "desktop_updater_install_helper.exe"))
          .writeAsString("helper");
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
            platform: "windows",
            channel: "stable",
            artifactUrl: Uri.parse("https://cdn.example.com/Example-setup.exe"),
            installStrategy: "innoInstaller",
            executableRelativePath: executableRelativePath,
          ),
          config: const InnoPublishConfig(
            kind: "inno",
            mode: "script",
            script: "setup.iss",
            privilegesRequired: "admin",
            requiresElevation: "always",
            authenticodeThumbprints: [_testCertificateSha256],
          ),
        ),
        throwsA(
          executableRelativePath == null
              ? isA<FormatException>().having(
                  (error) => error.message,
                  "message",
                  contains("--executable-relative-path"),
                )
              : isA<FileSystemException>().having(
                  (error) => error.path,
                  "path",
                  path.join(input.path, executableRelativePath),
                ),
        ),
      );
      expect(compilerCalled, isFalse);
      expect(await Directory(path.join(root.path, "out")).exists(), isFalse);
    });
  }

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
        executableRelativePath: "Example.exe",
        minimumUpdaterVersion: "2.5.0",
      ),
      config: const InnoPublishConfig(
        kind: "inno",
        mode: "generated",
        appId: "com.example.app",
        privilegesRequired: "admin",
        requiresElevation: "always",
        authenticodeThumbprints: [_testCertificateSha256],
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
    expect(
      descriptor.install.inno!.installedExecutableRelativePath,
      "Example.exe",
    );
    expect(
      descriptor.install.inno!.installedExecutableSha256,
      crypto.sha256.convert(utf8.encode("exe")).toString(),
    );
    final script = await File(
      path.join(output.path, "Example-2.5.0-windows-setup.iss"),
    ).readAsString();
    expect(script, contains("DesktopUpdaterExpectedHelperSha256"));
    expect(script, contains("DesktopUpdaterExpectedPolicySha256"));
    expect(script, contains(".desktop_updater_install_identity.json"));
    expect(script, contains('ValueName: "DisplayVersion"'));
    expect(script, contains('ValueData: "2.5.0"'));
    expect(script, contains('ValueName: "DesktopUpdaterBuildNumber"'));
    expect(script, contains('ValueData: "250"'));
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

  test("expands output base name in generated mode", () async {
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
        artifactUrl:
            Uri.parse("https://cdn.example.com/v2.5.0(250)-windows.exe"),
        installStrategy: "innoInstaller",
        executableRelativePath: "Example.exe",
        minimumUpdaterVersion: "2.5.0",
      ),
      config: const InnoPublishConfig(
        kind: "inno",
        mode: "generated",
        appId: "com.example.app",
        outputBaseName: "v{version}({buildNumber})-{platform}",
        privilegesRequired: "admin",
        requiresElevation: "always",
        authenticodeThumbprints: [_testCertificateSha256],
        protectedHelperInstallDir:
            r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
      ),
    );

    expect(path.basename(result.artifact.path), "v2.5.0(250)-windows.exe");
    expect(
      await result.releaseFile.readAsString(),
      contains('"url": "https://cdn.example.com/v2.5.0(250)-windows.exe"'),
    );
    expect(
      await File(path.join(output.path, "v2.5.0(250)-windows.iss"))
          .readAsString(),
      contains("OutputBaseFilename=v2.5.0(250)-windows"),
    );
  });

  final isccPath = Platform.environment["DESKTOP_UPDATER_TEST_ISCC_PATH"];
  for (final mode in ["generated", "script-literal", "script-dynamic"]) {
    test(
      "real ISCC compiles expanded output name ($mode)",
      () async {
        final root = await Directory.systemTemp.createTemp("inno_real_name_");
        addTearDown(() => root.delete(recursive: true));
        final input = Directory(path.join(root.path, "Release"));
        await input.create();
        // This lane compiles packaging fixtures; it never installs or claims
        // Authenticode trust for these deliberately synthetic payloads.
        await File(path.join(input.path, "Example.exe"))
            .writeAsBytes([77, 90, 1, 2, 3]);
        await writeProtectedHelperInputs(input);
        const helperDir =
            r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--1.0.0";
        await writeProtectedHelperCMakeCache(root, installDir: helperDir);
        final output = Directory(path.join(root.path, "output with spaces"));
        final script = File(path.join(root.path, "custom.iss"));
        final scriptName =
            mode == "script-dynamic" ? "{#SetupBaseName}" : "v1.0.0(3)-windows";
        await script.writeAsString("""
#define SetupBaseName "v1.0.0(3)-windows"
[Setup]
AppName=Example
AppVersion=1.0.0
DefaultDirName={autopf}\\Example
OutputDir=${output.path}
OutputBaseFilename=$scriptName
[Files]
Source: "${input.path}\\Example.exe"; DestDir: "{app}"
""");
        final result = await const InnoInstallerPackager().package(
          ReleasePackageRequest(
            input: input,
            outputDirectory: output,
            packageId: "com.example.app",
            appName: "Example",
            version: "1.0.0",
            buildNumber: 3,
            platform: "windows",
            channel: "stable",
            artifactUrl:
                Uri.parse("https://cdn.example.com/v1.0.0(3)-windows.exe"),
            installStrategy: "innoInstaller",
            executableRelativePath: "Example.exe",
          ),
          config: InnoPublishConfig(
            kind: "inno",
            mode: mode == "generated" ? "generated" : "script",
            script: mode == "generated" ? null : script.path,
            isccPath: isccPath,
            outputBaseName: "v{version}({buildNumber})-{platform}",
            privilegesRequired: "admin",
            requiresElevation: "always",
            authenticodeThumbprints: [_testCertificateSha256],
            protectedHelperInstallDir: mode == "generated" ? helperDir : null,
          ),
        );
        final bytes = await result.artifact.readAsBytes();
        expect(path.basename(result.artifact.path), "v1.0.0(3)-windows.exe");
        expect(bytes.length, greaterThan(1024));
        expect(bytes.take(2), [77, 90]);
        final descriptor = ReleaseDescriptor.fromJson(
          jsonDecode(await result.releaseFile.readAsString())
              as Map<String, dynamic>,
        );
        expect(descriptor.artifact.url.pathSegments.last,
            path.basename(result.artifact.path));
        expect(descriptor.artifact.length, bytes.length);
        expect(descriptor.artifact.sha256,
            crypto.sha256.convert(bytes).toString());
      },
      skip: !Platform.isWindows || isccPath == null,
    );
  }

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
          executableRelativePath: "Example.exe",
          minimumUpdaterVersion: "2.5.0",
        ),
        config: const InnoPublishConfig(
          kind: "inno",
          mode: "generated",
          appId: "com.example.app",
          privilegesRequired: "admin",
          requiresElevation: "always",
          authenticodeThumbprints: [_testCertificateSha256],
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
          executableRelativePath: "Example.exe",
          minimumUpdaterVersion: "2.5.0",
        ),
        config: const InnoPublishConfig(
          kind: "inno",
          mode: "generated",
          privilegesRequired: "admin",
          requiresElevation: "always",
          authenticodeThumbprints: [_testCertificateSha256],
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
          executableRelativePath: "Example.exe",
          minimumUpdaterVersion: "2.5.0",
        ),
        config: const InnoPublishConfig(
          kind: "inno",
          mode: "generated",
          privilegesRequired: "admin",
          requiresElevation: "always",
          authenticodeThumbprints: [_testCertificateSha256],
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
          executableRelativePath: "Example.exe",
          minimumUpdaterVersion: "2.5.0",
        ),
        config: const InnoPublishConfig(
          kind: "inno",
          mode: "generated",
          privilegesRequired: "admin",
          requiresElevation: "always",
          authenticodeThumbprints: [_testCertificateSha256],
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
