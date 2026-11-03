import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_installer_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/macos/dmg_packager.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/macos/macos_release_trust.dart";
import "package:desktop_updater/src/release_cli/macos/pkg_packager.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";
import "package:desktop_updater/src/release_cli/sign_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:path/path.dart" as path;

void main() {
  test("windows publish build uses shell-aware flutter process", () async {
    final root = await _createWindowsFixture();
    final commands = <String>[];
    final buildCalls = <_BuildProcessCall>[];
    final packager = _RecordingPackager(commands);
    final output = StringBuffer();
    try {
      final publisher = ReleasePublisher(
        packager: packager,
        startBuildProcess: (
          executable,
          arguments, {
          workingDirectory,
          runInShell = false,
        }) async {
          buildCalls.add(
            _BuildProcessCall(
              executable: executable,
              arguments: arguments,
              workingDirectory: workingDirectory,
              runInShell: runInShell,
            ),
          );
          return const _FakeBuildProcess(
            stdoutText: "build stdout\n",
            stderrText: "build stderr\n",
          );
        },
      );

      await publisher.publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(initializeFeed: true),
        output: output,
      );

      expect(buildCalls, hasLength(1));
      final call = buildCalls.single;
      expect(call.executable, "flutter");
      expect(call.arguments, ["build", "windows", "--release"]);
      expect(call.workingDirectory, root.path);
      expect(call.runInShell, isTrue);
      expect(output.toString(), contains("build stdout"));
      expect(output.toString(), contains("build stderr"));
      expect(commands.single, startsWith("PACKAGE "));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("publish forwards dart defines to flutter build", () async {
    final root = await _createWindowsFixture();
    final commands = <String>[];
    final buildCalls = <_BuildProcessCall>[];
    final packager = _RecordingPackager(commands);
    try {
      final publisher = ReleasePublisher(
        packager: packager,
        startBuildProcess: (
          executable,
          arguments, {
          workingDirectory,
          runInShell = false,
        }) async {
          buildCalls.add(
            _BuildProcessCall(
              executable: executable,
              arguments: arguments,
              workingDirectory: workingDirectory,
              runInShell: runInShell,
            ),
          );
          return const _FakeBuildProcess();
        },
      );

      await publisher.publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(
          dartDefines: ["MY_VAR=value", "FEATURE_FLAG=true"],
        ),
        output: StringBuffer(),
      );

      expect(buildCalls, hasLength(1));
      expect(buildCalls.single.arguments, [
        "build",
        "windows",
        "--release",
        "--dart-define=MY_VAR=value",
        "--dart-define=FEATURE_FLAG=true",
      ]);
      expect(commands.single, startsWith("PACKAGE "));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("publish forwards version overrides to flutter build", () async {
    final root = await _createWindowsFixture();
    final buildCalls = <_BuildProcessCall>[];
    try {
      final publisher = ReleasePublisher(
        packager: _RecordingPackager(<String>[]),
        startBuildProcess: (
          executable,
          arguments, {
          workingDirectory,
          runInShell = false,
        }) async {
          buildCalls.add(
            _BuildProcessCall(
              executable: executable,
              arguments: arguments,
              workingDirectory: workingDirectory,
              runInShell: runInShell,
            ),
          );
          return const _FakeBuildProcess();
        },
      );

      await publisher.publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(
          version: "9.1.0",
          buildNumber: 901,
        ),
        output: StringBuffer(),
      );

      expect(buildCalls.single.arguments, [
        "build",
        "windows",
        "--release",
        "--build-name=9.1.0",
        "--build-number=901",
      ]);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    "manual publish packages the complete artifact directory without Flutter",
    () async {
      final root = await Directory.systemTemp.createTemp("manual_publish_");
      final artifactRoot = Directory(path.join(root.path, "prebuilt", "app"));
      await artifactRoot.create(recursive: true);
      await File(path.join(artifactRoot.path, "Example.exe"))
          .writeAsString("binary");
      await File(path.join(artifactRoot.path, "runtime.dll"))
          .writeAsString("runtime");
      await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com/
""");
      final packager = _RecordingPackager(<String>[]);
      try {
        final publisher = ReleasePublisher(
          packager: packager,
          startBuildProcess: (executable, arguments,
              {workingDirectory, runInShell = false}) {
            fail("Manual publishing must not start Flutter.");
          },
        );

        await publisher.publish(
          projectRoot: root,
          platform: "windows",
          overrides: ReleasePublishOverrides(
            projectType: "manual",
            artifactRoot: artifactRoot.path,
            appName: "Example",
            packageId: "com.example.app",
            version: "4.2.0",
            buildNumber: 42,
            executableRelativePath: "Example.exe",
          ),
          output: StringBuffer(),
        );

        expect(packager.requests, hasLength(1));
        final request = packager.requests.single;
        expect(request.input.path, artifactRoot.path);
        expect(request.appName, "Example");
        expect(request.packageId, "com.example.app");
        expect(request.version, "4.2.0");
        expect(request.buildNumber, 42);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    "CMake publish accepts a complete installed tree without Flutter",
    () async {
      final root = await Directory.systemTemp.createTemp("cmake_publish_");
      final installed = Directory(path.join(root.path, "installed"));
      await File(path.join(installed.path, "bin", "example"))
          .create(recursive: true);
      await File(path.join(root.path, "CMakeLists.txt")).writeAsString("");
      await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com/
""");
      final packager = _RecordingPackager(<String>[]);
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: packager,
          runProcess: (executable, arguments) {
            fail("A preinstalled CMake tree must not start a process.");
          },
          startBuildProcess: (executable, arguments,
              {workingDirectory, runInShell = false}) {
            fail("CMake publishing must not start Flutter.");
          },
        );

        await publisher.publish(
          projectRoot: root,
          platform: "linux",
          overrides: ReleasePublishOverrides(
            projectType: "cmake",
            artifactRoot: installed.path,
            appName: "Example",
            packageId: "com.example.app",
            version: "2.4.0",
            executableRelativePath: "bin/example",
          ),
          output: StringBuffer(),
        );

        expect(packager.requests, hasLength(1));
        expect(packager.requests.single.input.path, installed.path);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  for (final platform in ["linux", "macos"]) {
    test("$platform publish build does not force shell resolution", () async {
      final root = await _createFixture(platform);
      final commands = <String>[];
      final buildCalls = <_BuildProcessCall>[];
      final packager = _RecordingPackager(commands);
      try {
        final publisher = ReleasePublisher(
          packager: packager,
          startBuildProcess: (
            executable,
            arguments, {
            workingDirectory,
            runInShell = false,
          }) async {
            buildCalls.add(
              _BuildProcessCall(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                runInShell: runInShell,
              ),
            );
            return const _FakeBuildProcess();
          },
        );

        await publisher.publish(
          projectRoot: root,
          platform: platform,
          overrides: const ReleasePublishOverrides(
            packageId: "com.example.egasManager",
          ),
          output: StringBuffer(),
        );

        expect(buildCalls, hasLength(1));
        final call = buildCalls.single;
        expect(call.executable, "flutter");
        expect(call.arguments, ["build", platform, "--release"]);
        expect(call.workingDirectory, root.path);
        expect(call.runInShell, isFalse);
        expect(commands.single, startsWith("PACKAGE "));
      } finally {
        await root.delete(recursive: true);
      }
    });
  }

  test("macOS publish keeps .app bundle name in release descriptor", () async {
    final root = await _createFixture("macos");
    final commands = <String>[];
    final packager = _RecordingPackager(commands);
    try {
      final publisher = ReleasePublisher(skipBuild: true, packager: packager);

      await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(initializeFeed: true),
        output: StringBuffer(),
      );

      expect(packager.requests, hasLength(1));
      expect(packager.requests.single.appName, "Egas Manager.app");
      expect(
        packager.requests.single.artifactUrl.toString(),
        "https://updates.example.com/releases/stable/2.1.0/no-build/macos/"
        "Egas%20Manager-2.1.0-macos.zip",
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    "channel and build variants preserve prior release bytes and reject duplicates",
    () async {
      final root = await _createWindowsFixture();
      final packager = _RecordingPackager(<String>[]);
      final publisher = ReleasePublisher(skipBuild: true, packager: packager);
      final output = StringBuffer();
      try {
        Future<PublishManifest> publish({
          required String channel,
          required int buildNumber,
        }) =>
            publisher.publish(
              projectRoot: root,
              platform: "windows",
              overrides: ReleasePublishOverrides(
                channel: channel,
                version: "2.1.0",
                buildNumber: buildNumber,
                initializeFeed: true,
              ),
              output: output,
            );

        final stableBuildOne = await publish(channel: "stable", buildNumber: 1);
        final stableDescriptor = File(
          path.join(
            root.path,
            "dist",
            "desktop_updater",
            stableBuildOne.release.path,
          ),
        );
        final stableArtifact = File(
          path.join(
            root.path,
            "dist",
            "desktop_updater",
            stableBuildOne.artifact.path,
          ),
        );
        final stableDescriptorBytes = await stableDescriptor.readAsBytes();
        final stableArtifactBytes = await stableArtifact.readAsBytes();

        final stableBuildTwo = await publish(channel: "stable", buildNumber: 2);
        final betaBuildOne = await publish(channel: "beta", buildNumber: 1);

        expect(stableBuildOne.release.url, isNot(stableBuildTwo.release.url));
        expect(stableBuildOne.release.url, isNot(betaBuildOne.release.url));
        expect(stableBuildOne.artifact.url, isNot(stableBuildTwo.artifact.url));
        expect(stableBuildOne.artifact.url, isNot(betaBuildOne.artifact.url));
        expect(stableBuildOne.appArchive.url, stableBuildTwo.appArchive.url);
        expect(stableBuildOne.appArchive.url, betaBuildOne.appArchive.url);
        expect(await stableDescriptor.readAsBytes(), stableDescriptorBytes);
        expect(await stableArtifact.readAsBytes(), stableArtifactBytes);

        final archive = ReleaseIndex.fromJson(
          jsonDecode(
            await File(
              path.join(
                root.path,
                "dist",
                "desktop_updater",
                "app-archive.json",
              ),
            ).readAsString(),
          ) as Map<String, dynamic>,
        );
        expect(
          archive.items
              .map((item) => "${item.channel}:${item.buildNumber}")
              .toSet(),
          {"stable:1", "stable:2", "beta:1"},
        );

        await expectLater(
          publish(channel: "stable", buildNumber: 1),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              "message",
              contains("local app-archive.json"),
            ),
          ),
        );
        expect(packager.requests, hasLength(3));
        expect(await stableDescriptor.readAsBytes(), stableDescriptorBytes);
        expect(await stableArtifact.readAsBytes(), stableArtifactBytes);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test("publisher refuses an occupied local release directory before packaging",
      () async {
    final root = await _createWindowsFixture();
    final packager = _RecordingPackager(<String>[]);
    final releaseDirectory = Directory(
      path.join(
        root.path,
        "dist",
        "desktop_updater",
        "releases",
        "stable",
        "2.1.0",
        "no-build",
        "windows",
      ),
    );
    await releaseDirectory.create(recursive: true);
    try {
      await expectLater(
        ReleasePublisher(skipBuild: true, packager: packager).publish(
          projectRoot: root,
          platform: "windows",
          overrides: const ReleasePublishOverrides(initializeFeed: true),
          output: StringBuffer(),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            "message",
            contains("Release output directory already exists"),
          ),
        ),
      );
      expect(packager.requests, isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("windows publish uses Inno installer package when configured", () async {
    final root = await _createWindowsFixture();
    final output = StringBuffer();
    final innoPackager = _FakeInnoPackager();
    final publisher = ReleasePublisher(
      skipBuild: true,
      packager: _RecordingPackager(<String>[]),
      innoPackager: innoPackager,
    );
    await File(path.join(root.path, "desktop_updater.yaml")).writeAsString(r"""
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: generated
    appId: com.example.app
    outputBaseName: CustomSetup
    privilegesRequired: admin
    protectedHelperInstallDir: C:\Program Files\DesktopUpdaterHelperGenerationV1--egas_manager--2.1.0
    requiresElevation: always
    authenticodeThumbprints:
      - 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
""");
    try {
      final manifest = await publisher.publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(initializeFeed: true),
        output: output,
      );

      expect(manifest.artifact.kind, "innoInstaller");
      expect(manifest.artifact.path,
          "releases/stable/2.1.0/no-build/windows/CustomSetup.exe");
      expect(
        manifest.artifact.url.toString(),
        "https://updates.example.com/releases/stable/2.1.0/no-build/windows/CustomSetup.exe",
      );
      expect(
        innoPackager.requests.single.artifactUrl.toString(),
        "https://updates.example.com/releases/stable/2.1.0/no-build/windows/CustomSetup.exe",
      );
      expect(innoPackager.requests.single.minimumUpdaterVersion, "2.5.0");
      expect(innoPackager.outputBaseNames.single, "CustomSetup");
      final writtenManifest = await PublishManifest.readFrom(
        File(
          path.join(
            root.path,
            "dist",
            "desktop_updater",
            ".desktop_updater_publish.json",
          ),
        ),
      );
      expect(
        writtenManifest.artifact.path,
        "releases/stable/2.1.0/no-build/windows/CustomSetup.exe",
      );
      expect(
        writtenManifest.artifact.url.toString(),
        "https://updates.example.com/releases/stable/2.1.0/no-build/windows/CustomSetup.exe",
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("Flutter custom Inno publish resolves the built application executable",
      () async {
    final root = await _createWindowsFixture();
    final cmake = File(path.join(root.path, "windows", "CMakeLists.txt"));
    await cmake.parent.create(recursive: true);
    await cmake.writeAsString('set(BINARY_NAME "flutter_client")\n');
    final script =
        File(path.join(root.path, "packages", "windows", "setup.iss"));
    await script.parent.create(recursive: true);
    const scriptSource =
        "[Setup]\nOutputBaseFilename=应用-v2.1.0(2)-windows-setup\n";
    await script.writeAsString(scriptSource);
    await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: script
    script: ${script.path}
    outputBaseName: 应用-v2.1.0(2)-windows-setup
    privilegesRequired: admin
    requiresElevation: always
    authenticodeThumbprints:
      - 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
""");
    var buildCalls = 0;
    var compileCalls = 0;
    const executableBytes = [77, 90, 1, 2, 3];
    try {
      final publisher = ReleasePublisher(
        startBuildProcess: (
          executable,
          arguments, {
          workingDirectory,
          runInShell = false,
        }) async {
          buildCalls++;
          final release = Directory(
            path.join(
              root.path,
              "build",
              "windows",
              "x64",
              "runner",
              "Release",
            ),
          );
          await release.create(recursive: true);
          await File(path.join(release.path, "flutter_client.exe"))
              .writeAsBytes(executableBytes);
          await File(
            path.join(release.path, "desktop_updater_install_helper.exe"),
          ).writeAsString("helper");
          return const _FakeBuildProcess();
        },
        innoPackager: InnoInstallerPackager(
          compileInno: ({required scriptFile, required outputExe}) async {
            compileCalls++;
            expect(await scriptFile.readAsString(), scriptSource);
            await outputExe.writeAsBytes([1, 2, 3]);
          },
        ),
      );

      final manifest = await publisher.publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(initializeFeed: true),
        output: StringBuffer(),
      );

      expect(buildCalls, 1);
      expect(compileCalls, 1);
      expect(manifest.artifact.kind, "innoInstaller");
      expect(
        path.basename(manifest.artifact.path),
        "应用-v2.1.0(2)-windows-setup.exe",
      );
      final releaseFile = File(
        path.join(root.path, "dist", "desktop_updater", manifest.release.path),
      );
      final descriptor = ReleaseDescriptor.fromJson(
        jsonDecode(await releaseFile.readAsString()) as Map<String, dynamic>,
      );
      expect(
        descriptor.install.inno!.installedExecutableRelativePath,
        "flutter_client.exe",
      );
      expect(
        descriptor.install.inno!.installedExecutableSha256,
        crypto.sha256.convert(executableBytes).toString(),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("macOS publish uses DMG packager when configured", () async {
    final root = await _createFixture("macos");
    final output = StringBuffer();
    final dmgPackager = _FakeDmgPackager();
    final zipPackager = _RecordingPackager(<String>[]);
    await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com/
macos:
  artifact:
    kind: dmg
""");
    try {
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: zipPackager,
        dmgPackager: dmgPackager,
        isMacOSHost: false,
      );

      final manifest = await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(buildNumber: 201),
        output: output,
      );

      expect(zipPackager.requests, isEmpty);
      expect(dmgPackager.requests, hasLength(1));
      expect(dmgPackager.configs.single.volumeName, "Egas Manager");
      expect(dmgPackager.configs.single.appBundleName, "Egas Manager.app");
      expect(dmgPackager.requests.single.installStrategy, "wholeBundleReplace");
      expect(dmgPackager.requests.single.minimumUpdaterVersion, "2.6.0");
      expect(manifest.artifact.kind, "dmg");
      expect(manifest.artifact.path, endsWith(".dmg"));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("custom DMG filenames bind artifact, descriptor, and manifest URLs",
      () async {
    final root = await _createFixture("macos");
    addTearDown(() => root.delete(recursive: true));
    await File(path.join(root.path, "desktop_updater.yaml")).writeAsString('''
updates:
  baseUrl: https://updates.example.com/
macos:
  artifact:
    kind: dmg
  dmg:
    fileName: "Egas v{version}({buildNumber})-{platform}.dmg"
''');
    final commands = <List<String>>[];
    final manifest = await ReleasePublisher(
      skipBuild: true,
      isMacOSHost: false,
      dmgPackager: DmgPackager(runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments]);
        if (executable == "/usr/bin/hdiutil" && arguments.first == "create") {
          await File(arguments.last).writeAsString("dmg fixture");
        }
        return ProcessResult(0, 0, "", "");
      }),
    ).publish(
      projectRoot: root,
      platform: "macos",
      overrides: const ReleasePublishOverrides(buildNumber: 201),
      output: StringBuffer(),
    );
    const fileName = "Egas v2.1.0(201)-macos.dmg";
    const relative = "releases/stable/2.1.0/build-201/macos/$fileName";
    expect(manifest.artifact.path, relative);
    expect(manifest.artifact.url.pathSegments.last, fileName);
    expect(manifest.artifact.url.toString(), contains("Egas%20v2.1.0"));
    final output = Directory(path.join(root.path, "dist", "desktop_updater"));
    final artifact = File(path.joinAll([output.path, ...relative.split("/")]));
    expect(await artifact.readAsString(), "dmg fixture");
    final descriptor = ReleaseDescriptor.fromJson(jsonDecode(await File(
      path.join(artifact.parent.path, "release.json"),
    ).readAsString()) as Map<String, dynamic>);
    expect(descriptor.artifact.url, manifest.artifact.url);
    expect(descriptor.artifact.length, await artifact.length());
    expect(descriptor.install.macosDmg!.appBundleName, "Egas Manager.app");
    final written = await PublishManifest.readFrom(
      File(path.join(output.path, ".desktop_updater_publish.json")),
    );
    expect(written.artifact.path, relative);
    expect(written.artifact.url, descriptor.artifact.url);
    expect(
        commands.singleWhere((args) => args.first == "/usr/bin/hdiutil").last,
        artifact.path);
  });

  test("macOS publish uses PKG packager when configured", () async {
    final root = await _createFixture("macos");
    final output = StringBuffer();
    final pkgPackager = _FakePkgPackager();
    final zipPackager = _RecordingPackager(<String>[]);
    await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com/
macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
  artifact:
    kind: pkg
  pkg:
    packageIdentifier: com.example.app.pkg
    installLocation: /Applications
    signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)"
""");
    try {
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: zipPackager,
        pkgPackager: pkgPackager,
        runProcess: _fakeMacOSNotarizationProcess,
        isMacOSHost: false,
        macOSReleaseTrust: _StubMacOSReleaseTrust(),
      );

      final manifest = await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(buildNumber: 201),
        output: output,
      );

      expect(zipPackager.requests, isEmpty);
      expect(pkgPackager.requests, hasLength(1));
      expect(
        pkgPackager.configs.single.packageIdentifier,
        "com.example.app.pkg",
      );
      expect(pkgPackager.requests.single.installStrategy, "pkgInstaller");
      expect(pkgPackager.requests.single.minimumUpdaterVersion, "2.7.0");
      expect(manifest.artifact.kind, "pkgInstaller");
      expect(manifest.artifact.path, endsWith(".pkg"));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    "release hooks run around packaging with environment contract",
    () async {
      final root = await _createHookFixture();
      final commands = <String>[];
      final hookCalls = <_HookCall>[];
      final packager = _RecordingPackager(commands);
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: packager,
          runHookCommand: (command, {required environment}) async {
            hookCalls.add(_HookCall(command, environment));
            commands.add(
              "HOOK ${environment["DESKTOP_UPDATER_HOOK_PHASE"]} $command",
            );
            return ProcessResult(0, 0, "hook stdout\n", "");
          },
        );

        await publisher.publish(
          projectRoot: root,
          platform: "windows",
          overrides: const ReleasePublishOverrides(initializeFeed: true),
          output: StringBuffer(),
        );

        expect(commands, [
          "HOOK prePackage ./tool/sign_windows_release.ps1",
          startsWith("PACKAGE "),
          "HOOK postPackage ./tool/sign_release_json.sh",
        ]);
        expect(hookCalls, hasLength(2));
        expect(
          hookCalls.first.environment["DESKTOP_UPDATER_PLATFORM"],
          "windows",
        );
        expect(
          hookCalls.first.environment["DESKTOP_UPDATER_PROJECT_ROOT"],
          root.path,
        );
        expect(
          hookCalls.first.environment["DESKTOP_UPDATER_BASE_URL"],
          "https://updates.example.com/",
        );
        expect(
          hookCalls.first.environment["DESKTOP_UPDATER_RELEASE_FILE"],
          endsWith(path.join("releases", "stable", "2.1.0", "no-build",
              "windows", "release.json")),
        );
        expect(
          hookCalls.last.environment["DESKTOP_UPDATER_PUBLISH_MANIFEST"],
          endsWith(".desktop_updater_publish.json"),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    "publisher signs the final app archive after post-package hooks",
    () async {
      final root = await _createWindowsFixture();
      await _configureDescriptorSigningHook(root);
      final packager = _RecordingPackager(<String>[]);
      final seed = List<int>.generate(32, (index) => index);
      final keyPair = await Ed25519().newKeyPairFromSeed(seed);
      final publicKey = await keyPair.extractPublicKey();
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: packager,
          httpClient: _missingHostedIndexClient(),
          runHookCommand: _descriptorSigningHook(
            seed: seed,
            publicKeyId: "stable-2026",
          ),
        );

        await publisher.publish(
          projectRoot: root,
          platform: "windows",
          overrides: const ReleasePublishOverrides(initializeFeed: true),
          signing: ReleaseSigningOptions(
            publicKeyId: "stable-2026",
            privateKeyBase64: base64Encode(seed),
            trustedReleasePublicKeys: {
              "stable-2026": base64Encode(publicKey.bytes),
            },
          ),
          output: StringBuffer(),
        );

        final archiveFile = File(
          path.join(root.path, "dist", "desktop_updater", "app-archive.json"),
        );
        final index = ReleaseIndex.fromJson(
          jsonDecode(await archiveFile.readAsString()) as Map<String, dynamic>,
        );
        expect(index.signature?.publicKeyId, "stable-2026");
        expect(
          await Ed25519ReleaseIndexSignatureVerifier({
            "stable-2026": base64Encode(publicKey.bytes),
          }).verify(index),
          isTrue,
        );
        final descriptor = ReleaseDescriptor.fromJson(
          jsonDecode(
            await File(
              path.join(
                root.path,
                "dist",
                "desktop_updater",
                "releases",
                "stable",
                "2.1.0",
                "no-build",
                "windows",
                "release.json",
              ),
            ).readAsString(),
          ) as Map<String, dynamic>,
        );
        expect(
          await Ed25519ReleaseSignatureVerifier({
            "stable-2026": base64Encode(publicKey.bytes),
          }).verify(descriptor),
          isTrue,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test("signed publisher signs an unsigned descriptor before upload", () async {
    final root = await _createWindowsFixture();
    final output = StringBuffer();
    final seed = List<int>.generate(32, (index) => index);
    final publicKeys = await _publicKeysForSeed(seed);
    try {
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: _RecordingPackager(<String>[]),
        httpClient: _missingHostedIndexClient(),
      );

      await publisher.publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(initializeFeed: true),
        signing: ReleaseSigningOptions(
          publicKeyId: "stable-2026",
          privateKeyBase64: base64Encode(seed),
          trustedReleasePublicKeys: publicKeys,
        ),
        output: output,
      );
      expect(output.toString(), contains("Signed final app-archive.json."));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    "signed publisher overwrites hook-authored descriptor signatures",
    () async {
      final root = await _createWindowsFixture();
      await _configureDescriptorSigningHook(root);
      final output = StringBuffer();
      final seed = List<int>.generate(32, (index) => index);
      final differentSeed = List<int>.generate(32, (index) => index + 32);
      final publicKeys = await _publicKeysForSeed(seed);
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: _RecordingPackager(<String>[]),
          httpClient: _missingHostedIndexClient(),
          runHookCommand: _descriptorSigningHook(
            seed: differentSeed,
            publicKeyId: "stable-2026",
          ),
        );

        await publisher.publish(
          projectRoot: root,
          platform: "windows",
          overrides: const ReleasePublishOverrides(initializeFeed: true),
          signing: ReleaseSigningOptions(
            publicKeyId: "stable-2026",
            privateKeyBase64: base64Encode(seed),
            trustedReleasePublicKeys: publicKeys,
          ),
          output: output,
        );
        expect(output.toString(), contains("Signed final app-archive.json."));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    "signed custom command publish requires hosted versioned validation",
    () async {
      final root = await _createWindowsFixture();
      await _configureDescriptorSigningHook(root, customCommand: true);
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: _RecordingPackager(<String>[]),
          runHookCommand: _descriptorSigningHook(
            seed: seed,
            publicKeyId: "stable-2026",
          ),
        );

        await expectLater(
          publisher.publish(
            projectRoot: root,
            platform: "windows",
            overrides: const ReleasePublishOverrides(),
            signing: ReleaseSigningOptions(
              publicKeyId: "stable-2026",
              privateKeyBase64: base64Encode(seed),
              trustedReleasePublicKeys: publicKeys,
            ),
            output: StringBuffer(),
          ),
          throwsA(isA<Exception>()),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    "signed publisher rejects an identity already in hosted history before packaging",
    () async {
      final root = await _createWindowsFixture();
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      final packager = _RecordingPackager(<String>[]);
      final hostedArchive = await _writeSignedAppArchive(
        root: root,
        relativePath: "hosted-duplicate-app-archive.json",
        seed: seed,
        items: [
          ReleaseIndexItem(
            version: "2.1.0",
            buildNumber: null,
            platform: "windows",
            channel: "stable",
            mandatory: false,
            release: Uri.parse(
              "https://updates.example.com/releases/stable/2.1.0/no-build/windows/release.json",
            ),
          ),
        ],
      );
      final hostedBytes = await hostedArchive.readAsBytes();
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: packager,
          httpClient: MockClient(
            (_) async => http.Response.bytes(hostedBytes, 200),
          ),
        );

        await expectLater(
          publisher.publish(
            projectRoot: root,
            platform: "windows",
            overrides: const ReleasePublishOverrides(),
            signing: ReleaseSigningOptions(
              publicKeyId: "stable-2026",
              privateKeyBase64: base64Encode(seed),
              trustedReleasePublicKeys: publicKeys,
            ),
            output: StringBuffer(),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              "message",
              contains("signed publication history"),
            ),
          ),
        );
        expect(packager.requests, isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    "signed publisher preserves verified hosted app archive history",
    () async {
      final root = await _createWindowsFixture();
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      final hostedArchive = await _writeSignedAppArchive(
        root: root,
        relativePath: "hosted-app-archive.json",
        seed: seed,
        items: [
          _macOSHistoryItem(),
          ReleaseIndexItem(
            version: "2.0.0",
            buildNumber: 200,
            platform: "windows",
            channel: "stable",
            mandatory: false,
            release: Uri.parse(
              "https://updates.example.com/releases/2.0.0/windows/release.json",
            ),
          ),
        ],
      );
      final hostedBytes = await hostedArchive.readAsBytes();
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: _RecordingPackager(<String>[]),
          httpClient: MockClient(
            (_) async => http.Response.bytes(
              hostedBytes,
              200,
              headers: {"etag": '"prior"'},
            ),
          ),
        );

        await publisher.publish(
          projectRoot: root,
          platform: "windows",
          overrides: const ReleasePublishOverrides(),
          signing: ReleaseSigningOptions(
            publicKeyId: "stable-2026",
            privateKeyBase64: base64Encode(seed),
            trustedReleasePublicKeys: publicKeys,
          ),
          output: StringBuffer(),
        );

        final finalIndex = ReleaseIndex.fromJson(
          jsonDecode(
            await File(
              path.join(
                root.path,
                "dist",
                "desktop_updater",
                "app-archive.json",
              ),
            ).readAsString(),
          ) as Map<String, dynamic>,
        );
        expect(finalIndex.items.map((item) => item.version), [
          "2.1.0",
          "2.0.0",
          "2.1.0",
        ]);
        expect(finalIndex.items.map((item) => item.platform), [
          "macos",
          "windows",
          "windows",
        ]);
        expect(
          await Ed25519ReleaseIndexSignatureVerifier(publicKeys)
              .verify(finalIndex),
          isTrue,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  for (final outputPath in ["dist/desktop_updater", "release output 中文"]) {
    for (final signed in [true, false]) {
      test(
        "feed initialization protects unselected local history "
        "(signed: $signed, output: $outputPath) before building",
        () async {
          final root = await _createWindowsFixture();
          final seed = List<int>.generate(32, (index) => index);
          final publicKeys = await _publicKeysForSeed(seed);
          final packager = _RecordingPackager(<String>[]);
          var buildCalls = 0;
          try {
            final archive = await _writeSignedAppArchive(
              root: root,
              relativePath: path.join(outputPath, "app-archive.json"),
              seed: seed,
              items: [_macOSHistoryItem()],
            );
            if (!signed) {
              final json = jsonDecode(await archive.readAsString())
                  as Map<String, dynamic>;
              json.remove("signature");
              await _writeJsonFileForTest(archive, json);
            }
            final originalBytes = await archive.readAsBytes();
            final publisher = ReleasePublisher(
              packager: packager,
              httpClient: _missingHostedIndexClient(),
              startBuildProcess: (
                executable,
                arguments, {
                workingDirectory,
                runInShell = false,
              }) async {
                buildCalls += 1;
                return const _FakeBuildProcess();
              },
            );

            await expectLater(
              publisher.publish(
                projectRoot: root,
                platform: "windows",
                overrides: ReleasePublishOverrides(
                  initializeFeed: true,
                  outputPath: outputPath,
                ),
                signing: ReleaseSigningOptions(
                  publicKeyId: "stable-2026",
                  privateKeyBase64: base64Encode(seed),
                  trustedReleasePublicKeys: publicKeys,
                ),
                output: StringBuffer(),
              ),
              throwsA(
                isA<FormatException>().having(
                  (error) => error.message,
                  "message",
                  allOf(contains("local"), contains("--existing-app-archive")),
                ),
              ),
            );
            expect(buildCalls, 0);
            expect(packager.requests, isEmpty);
            expect(await archive.readAsBytes(), originalBytes);
            expect(
              await Directory(path.join(archive.parent.path, "releases"))
                  .exists(),
              isFalse,
            );
            expect(
              await File(path.join(
                archive.parent.path,
                ".desktop_updater_publish.json",
              )).exists(),
              isFalse,
            );
          } finally {
            await root.delete(recursive: true);
          }
        },
      );
    }

    test(
      "feed initialization extends explicit signed history at its output path "
      "($outputPath)",
      () async {
        final root = await _createWindowsFixture();
        final seed = List<int>.generate(32, (index) => index);
        final publicKeys = await _publicKeysForSeed(seed);
        final archivePath = path.join(outputPath, "app-archive.json");
        try {
          final macOSItem = _macOSHistoryItem();
          final archive = await _writeSignedAppArchive(
            root: root,
            relativePath: archivePath,
            seed: seed,
            items: [macOSItem],
          );
          final publisher = ReleasePublisher(
            skipBuild: true,
            packager: _RecordingPackager(<String>[]),
            httpClient: _missingHostedIndexClient(),
          );

          await publisher.publish(
            projectRoot: root,
            platform: "windows",
            overrides: ReleasePublishOverrides(
              initializeFeed: true,
              outputPath: outputPath,
              existingAppArchive: archivePath,
            ),
            signing: ReleaseSigningOptions(
              publicKeyId: "stable-2026",
              privateKeyBase64: base64Encode(seed),
              trustedReleasePublicKeys: publicKeys,
            ),
            output: StringBuffer(),
          );

          final index = ReleaseIndex.fromJson(
            jsonDecode(await archive.readAsString()) as Map<String, dynamic>,
          );
          expect(
              index.items.map((item) => item.platform), ["macos", "windows"]);
          expect(index.items.first.toJson(), macOSItem.toJson());
          expect(
            await Ed25519ReleaseIndexSignatureVerifier(publicKeys)
                .verify(index),
            isTrue,
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
  }

  test("feed initialization allows an empty local archive", () async {
    final root = await _createWindowsFixture();
    final seed = List<int>.generate(32, (index) => index);
    final publicKeys = await _publicKeysForSeed(seed);
    try {
      final archive = await _writeSignedAppArchive(
        root: root,
        relativePath: "dist/desktop_updater/app-archive.json",
        seed: seed,
        items: [],
      );
      await ReleasePublisher(
        skipBuild: true,
        packager: _RecordingPackager(<String>[]),
        httpClient: _missingHostedIndexClient(),
      ).publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(initializeFeed: true),
        signing: ReleaseSigningOptions(
          publicKeyId: "stable-2026",
          privateKeyBase64: base64Encode(seed),
          trustedReleasePublicKeys: publicKeys,
        ),
        output: StringBuffer(),
      );
      final index = ReleaseIndex.fromJson(
        jsonDecode(await archive.readAsString()) as Map<String, dynamic>,
      );
      expect(index.items.single.platform, "windows");
      expect(
        await Ed25519ReleaseIndexSignatureVerifier(publicKeys).verify(index),
        isTrue,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  for (final conflict in ["history", "formatting", "initialization"]) {
    test("publisher rejects hosted archive conflict: $conflict", () async {
      final root = await _createWindowsFixture();
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      final packager = _RecordingPackager(<String>[]);
      try {
        final archive = await _writeSignedAppArchive(
          root: root,
          relativePath: "dist/desktop_updater/app-archive.json",
          seed: seed,
          items: [_macOSHistoryItem()],
        );
        final originalBytes = await archive.readAsBytes();
        final hosted = await _writeSignedAppArchive(
          root: root,
          relativePath: "hosted.json",
          seed: seed,
          items: [],
        );
        final hostedBytes = conflict == "history"
            ? await hosted.readAsBytes()
            : utf8.encode(jsonEncode(jsonDecode(utf8.decode(originalBytes))));
        await expectLater(
          ReleasePublisher(
            skipBuild: true,
            packager: packager,
            httpClient: MockClient(
              (_) async => http.Response.bytes(hostedBytes, 200),
            ),
          ).publish(
            projectRoot: root,
            platform: "windows",
            overrides: ReleasePublishOverrides(
              initializeFeed: conflict == "initialization",
              existingAppArchive: "dist/desktop_updater/app-archive.json",
            ),
            signing: ReleaseSigningOptions(
              publicKeyId: "stable-2026",
              privateKeyBase64: base64Encode(seed),
              trustedReleasePublicKeys: publicKeys,
            ),
            output: StringBuffer(),
          ),
          throwsA(isA<FormatException>().having(
            (error) => error.message,
            "message",
            allOf(
              contains(conflict == "initialization"
                  ? "omit --initialize-feed"
                  : "does not match the hosted"),
              contains("https://updates.example.com/app-archive.json"),
            ),
          )),
        );
        expect(packager.requests, isEmpty);
        expect(await archive.readAsBytes(), originalBytes);
      } finally {
        await root.delete(recursive: true);
      }
    });
  }

  for (final platform in ["windows", "macos", "linux"]) {
    for (final hosted in [false, true]) {
      for (final pathKind in [
        "native relative",
        "forward relative",
        "absolute"
      ]) {
        test(
            "signed history survives $platform publication (hosted: $hosted, $pathKind)",
            () async {
          final root = await _createFixture(platform);
          final seed = List<int>.generate(32, (index) => index);
          final publicKeys = await _publicKeysForSeed(seed);
          const outputPath = "release output 中文/copied dist";
          try {
            final history = [
              for (var build = 1; build <= 3; build++)
                ReleaseIndexItem(
                  version: "1.0.0",
                  buildNumber: build,
                  platform: "macos",
                  channel: "stable",
                  mandatory: false,
                  release: Uri.parse(
                      "https://updates.example.com/releases/stable/1.0.0/build-$build/macos/release.json"),
                )
            ];
            final archive = await _writeSignedAppArchive(
              root: root,
              relativePath: path.join(outputPath, "app-archive.json"),
              seed: seed,
              items: history,
            );
            // Windows line endings and JSON formatting do not change the
            // canonical signature. Hosted snapshot equality still uses bytes.
            await archive.writeAsString(
                (await archive.readAsString()).replaceAll("\n", "\r\n"));
            final snapshot = await archive.readAsBytes();
            final sourcePath = switch (pathKind) {
              "absolute" => archive.absolute.path,
              "forward relative" => "$outputPath/app-archive.json",
              _ => path.join(
                  "release output 中文", "copied dist", "app-archive.json"),
            };
            await ReleasePublisher(
              skipBuild: true,
              packager: _RecordingPackager(<String>[]),
              macOSReleaseTrust: _StubMacOSReleaseTrust(),
              httpClient: MockClient((_) async => hosted
                  ? http.Response.bytes(snapshot, 200,
                      headers: {"etag": '"snapshot"'})
                  : http.Response("absent", 404)),
            ).publish(
              projectRoot: root,
              platform: platform,
              overrides: ReleasePublishOverrides(
                initializeFeed: !hosted,
                outputPath: outputPath,
                existingAppArchive: sourcePath,
                packageId: "com.example.archive-history",
              ),
              signing: ReleaseSigningOptions(
                publicKeyId: "stable-2026",
                privateKeyBase64: base64Encode(seed),
                trustedReleasePublicKeys: publicKeys,
              ),
              output: StringBuffer(),
            );
            final index = ReleaseIndex.fromJson(
                jsonDecode(await archive.readAsString())
                    as Map<String, dynamic>);
            expect(
                index.items
                    .where((item) => item.version == "1.0.0")
                    .map((item) => item.toJson()),
                history.map((item) => item.toJson()));
            expect(index.items, hasLength(4));
            expect(
                index.items
                    .singleWhere((item) => item.version == "2.1.0")
                    .platform,
                platform);
            expect(
                await Ed25519ReleaseIndexSignatureVerifier(publicKeys)
                    .verify(index),
                isTrue);
          } finally {
            await root.delete(recursive: true);
          }
        });
      }
    }
  }

  for (final source in ["hosted", "local initial", "local hosted"]) {
    final failures = <String, (void Function(Map<String, dynamic>), String)>{
      "missing signature": (
        (json) => json.remove("signature"),
        "missing signature"
      ),
      "unsupported algorithm": (
        (json) => json["signature"]["algorithm"] = "rsa",
        "unsupported signature algorithm",
      ),
      "missing key id": (
        (json) => json["signature"]["publicKeyId"] = " ",
        "missing publicKeyId",
      ),
      "unknown key": (
        (json) => json["signature"]["publicKeyId"] = "other-machine-key",
        "unknown publicKeyId \"other-machine-key\"",
      ),
      "empty signature": (
        (json) => json["signature"]["value"] = "",
        "malformed Ed25519 signature",
      ),
      "invalid base64": (
        (json) => json["signature"]["value"] = "not!base64",
        "malformed Ed25519 signature",
      ),
      "wrong signature length": (
        (json) => json["signature"]["value"] = base64Encode([1, 2, 3]),
        "malformed Ed25519 signature",
      ),
      "wrong signature": (
        (json) => json["signature"]["value"] = base64Encode(List.filled(64, 0)),
        "signature does not verify with the trusted public key",
      ),
      "tampered content": (
        (json) => json["appName"] = "Edited after signing",
        "signature does not verify with the trusted public key",
      ),
      "wrong public key": (
        (json) {},
        "signature does not verify with the trusted public key",
      ),
      "invalid schema": (
        (json) => json["schemaVersion"] = 2,
        "invalid schema-v3 archive"
      ),
      "invalid field type": (
        (json) => json["items"] = "items",
        "invalid schema-v3 archive"
      ),
      "invalid signature type": (
        (json) => json["signature"] = "signature",
        "invalid schema-v3 archive"
      ),
      "invalid JSON": ((json) {}, "invalid UTF-8 JSON"),
      "invalid UTF-8": ((json) {}, "invalid UTF-8 JSON"),
      "non-object JSON": ((json) {}, "must be a JSON object"),
    };
    for (final failure in failures.entries) {
      test(
          "archive validation identifies $source ${failure.key} before mutation",
          () async {
        final root = await _createHookFixture();
        final seed = List<int>.generate(32, (index) => index);
        final publicKeys = await _publicKeysForSeed(
          failure.key == "wrong public key" ? seed.reversed.toList() : seed,
        );
        final packager = _RecordingPackager(<String>[]);
        var builds = 0;
        var hooks = 0;
        try {
          final archive = await _writeSignedAppArchive(
            root: root,
            relativePath: path.join("release output 中文", "app-archive.json"),
            seed: seed,
            items: [_macOSHistoryItem()],
          );
          final validBytes = await archive.readAsBytes();
          final hostedBytes =
              source == "local hosted" && failure.key == "wrong public key"
                  ? await (await _writeSignedAppArchive(
                      root: root,
                      relativePath: "hosted.json",
                      seed: seed.reversed.toList(),
                      items: [_macOSHistoryItem()],
                    ))
                      .readAsBytes()
                  : validBytes;
          final json =
              jsonDecode(utf8.decode(validBytes)) as Map<String, dynamic>;
          failure.value.$1(json);
          final invalidBytes = switch (failure.key) {
            "invalid JSON" => utf8.encode('{"private": "do not echo",'),
            "invalid UTF-8" => [0xff],
            "non-object JSON" => utf8.encode("[]"),
            _ => utf8.encode(jsonEncode(json)),
          };
          if (source != "hosted") await archive.writeAsBytes(invalidBytes);
          final before = await archive.readAsBytes();
          final manifest = File(
              path.join(archive.parent.path, ".desktop_updater_publish.json"));
          await manifest.writeAsString("previous manifest");
          await expectLater(
            ReleasePublisher(
              packager: packager,
              startBuildProcess: (executable, arguments,
                  {workingDirectory, runInShell = false}) async {
                builds++;
                return const _FakeBuildProcess();
              },
              runHookCommand: (_, {required environment}) async {
                hooks++;
                return ProcessResult(0, 0, "", "");
              },
              httpClient: MockClient((_) async => source == "local initial"
                  ? http.Response("absent", 404)
                  : http.Response.bytes(
                      source == "hosted" ? invalidBytes : hostedBytes, 200)),
            ).publish(
              projectRoot: root,
              platform: "windows",
              overrides: ReleasePublishOverrides(
                initializeFeed: source != "local hosted",
                outputPath: "release output 中文",
                existingAppArchive:
                    path.relative(archive.path, from: root.path),
              ),
              signing: ReleaseSigningOptions(
                publicKeyId: "stable-2026",
                privateKeyBase64: base64Encode(seed),
                trustedReleasePublicKeys: publicKeys,
              ),
              output: StringBuffer(),
            ),
            throwsA(isA<FormatException>().having(
              (error) => error.message,
              "source-aware diagnostic",
              allOf([
                contains(source == "hosted"
                    ? "Hosted app-archive.json"
                    : "Local --existing-app-archive"),
                contains(source == "hosted"
                    ? "https://updates.example.com/app-archive.json"
                    : archive.absolute.path),
                contains(failure.value.$2),
                if ([
                  "empty signature",
                  "invalid base64",
                  "wrong signature length",
                  "wrong signature",
                  "wrong public key",
                  "tampered content",
                  "unsupported algorithm"
                ].contains(failure.key))
                  contains("stable-2026"),
                isNot(contains("do not echo")),
              ]),
            )),
          );
          expect(builds, 0);
          expect(hooks, 0);
          expect(packager.requests, isEmpty);
          expect(await archive.readAsBytes(), before);
          expect(await manifest.readAsString(), "previous manifest");
          expect(
              await Directory(path.join(archive.parent.path, "releases"))
                  .exists(),
              isFalse);
        } finally {
          await root.delete(recursive: true);
        }
      });
    }
  }

  test(
    "signed publisher requires explicit feed initialization when absent",
    () async {
      final root = await _createWindowsFixture();
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      final packager = _RecordingPackager(<String>[]);
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: packager,
          httpClient: _missingHostedIndexClient(),
        );

        await expectLater(
          publisher.publish(
            projectRoot: root,
            platform: "windows",
            overrides: const ReleasePublishOverrides(),
            signing: ReleaseSigningOptions(
              publicKeyId: "stable-2026",
              privateKeyBase64: base64Encode(seed),
              trustedReleasePublicKeys: publicKeys,
            ),
            output: StringBuffer(),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              "message",
              contains("--initialize-feed"),
            ),
          ),
        );
        expect(packager.requests, isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    "signed custom command publish rechecks frozen hosted revision",
    () async {
      final root = await _createWindowsFixture();
      final webRoot = await Directory.systemTemp.createTemp("publish_web_");
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      await _configureCustomCommandUpload(root, webRoot);
      final hostedArchive = await _writeSignedAppArchive(
        root: webRoot,
        relativePath: "app-archive.json",
        seed: seed,
        items: [
          ReleaseIndexItem(
            version: "2.0.0",
            buildNumber: 200,
            platform: "windows",
            channel: "stable",
            mandatory: false,
            release: Uri.parse(
              "https://updates.example.com/releases/2.0.0/windows/release.json",
            ),
          ),
        ],
      );
      await hostedArchive.copy(path.join(root.path, "hosted-copy.json"));
      try {
        final output = StringBuffer();
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: _RecordingPackager(<String>[]),
          httpClient: _webRootClient(webRoot, hostedArchiveEtag: '"prior"'),
        );

        await publisher.publish(
          projectRoot: root,
          platform: "windows",
          overrides: const ReleasePublishOverrides(
            existingAppArchive: "hosted-copy.json",
          ),
          signing: ReleaseSigningOptions(
            publicKeyId: "stable-2026",
            privateKeyBase64: base64Encode(seed),
            trustedReleasePublicKeys: publicKeys,
          ),
          output: output,
        );

        expect(
          output.toString(),
          contains("Publishing app-archive.json last..."),
        );
        expect(output.toString(), contains("OK: Published and validated."));
        final finalIndex = ReleaseIndex.fromJson(
          jsonDecode(
            await File(path.join(webRoot.path, "app-archive.json"))
                .readAsString(),
          ) as Map<String, dynamic>,
        );
        expect(finalIndex.items.map((item) => item.version), [
          "2.0.0",
          "2.1.0",
        ]);
      } finally {
        await root.delete(recursive: true);
        await webRoot.delete(recursive: true);
      }
    },
  );

  test(
    "signed manual publish rechecks frozen hosted revision before returning",
    () async {
      final root = await _createWindowsFixture();
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      final hostedArchive = await _writeSignedAppArchive(
        root: root,
        relativePath: "hosted-app-archive.json",
        seed: seed,
        items: [
          ReleaseIndexItem(
            version: "2.0.0",
            buildNumber: 200,
            platform: "windows",
            channel: "stable",
            mandatory: false,
            release: Uri.parse(
              "https://updates.example.com/releases/2.0.0/windows/release.json",
            ),
          ),
        ],
      );
      final changedArchive = await _writeSignedAppArchive(
        root: root,
        relativePath: "changed-app-archive.json",
        seed: seed,
        items: [
          ReleaseIndexItem(
            version: "2.0.1",
            buildNumber: 201,
            platform: "windows",
            channel: "stable",
            mandatory: false,
            release: Uri.parse(
              "https://updates.example.com/releases/2.0.1/windows/release.json",
            ),
          ),
        ],
      );
      var appArchiveRequests = 0;
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: _RecordingPackager(<String>[]),
          httpClient: MockClient((request) async {
            if (request.url.path == "/app-archive.json") {
              appArchiveRequests += 1;
              final source =
                  appArchiveRequests == 1 ? hostedArchive : changedArchive;
              return http.Response.bytes(
                await source.readAsBytes(),
                200,
                request: request,
                headers: {"etag": '"$appArchiveRequests"'},
              );
            }
            return http.Response("not found", 404, request: request);
          }),
        );

        await expectLater(
          publisher.publish(
            projectRoot: root,
            platform: "windows",
            overrides: const ReleasePublishOverrides(),
            signing: ReleaseSigningOptions(
              publicKeyId: "stable-2026",
              privateKeyBase64: base64Encode(seed),
              trustedReleasePublicKeys: publicKeys,
            ),
            output: StringBuffer(),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              "message",
              contains("changed before publish"),
            ),
          ),
        );
        expect(appArchiveRequests, 2);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    "signed publisher ignores post-package hook-authored index history",
    () async {
      final root = await _createWindowsFixture();
      await _configureIndexMutationHook(root);
      final seed = List<int>.generate(32, (index) => index);
      final publicKeys = await _publicKeysForSeed(seed);
      try {
        final publisher = ReleasePublisher(
          skipBuild: true,
          packager: _RecordingPackager(<String>[]),
          httpClient: _missingHostedIndexClient(),
          runHookCommand: (_, {required environment}) async {
            final appArchive = File(
              environment["DESKTOP_UPDATER_APP_ARCHIVE_FILE"]!,
            );
            await _writeJsonFileForTest(
              appArchive,
              ReleaseIndex(
                schemaVersion: 3,
                appName: "Egas-Manager",
                items: [
                  ReleaseIndexItem(
                    version: "9.9.9",
                    buildNumber: 999,
                    platform: "windows",
                    channel: "stable",
                    mandatory: true,
                    release: Uri.parse(
                      "https://attacker.example.com/release.json",
                    ),
                  ),
                ],
              ).toJson(),
            );
            return ProcessResult(0, 0, "", "");
          },
        );

        await publisher.publish(
          projectRoot: root,
          platform: "windows",
          overrides: const ReleasePublishOverrides(initializeFeed: true),
          signing: ReleaseSigningOptions(
            publicKeyId: "stable-2026",
            privateKeyBase64: base64Encode(seed),
            trustedReleasePublicKeys: publicKeys,
          ),
          output: StringBuffer(),
        );

        final index = ReleaseIndex.fromJson(
          jsonDecode(
            await File(
              path.join(
                root.path,
                "dist",
                "desktop_updater",
                "app-archive.json",
              ),
            ).readAsString(),
          ) as Map<String, dynamic>,
        );
        expect(index.items.map((item) => item.version), ["2.1.0"]);
        expect(index.items.single.release.host, "updates.example.com");
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}

ReleaseIndexItem _macOSHistoryItem() => ReleaseIndexItem(
      version: "2.1.0",
      buildNumber: null,
      platform: "macos",
      channel: "stable",
      mandatory: false,
      release: Uri.parse(
        "https://updates.example.com/releases/stable/2.1.0/no-build/macos/release.json",
      ),
    );

Future<void> _configureDescriptorSigningHook(
  Directory root, {
  bool customCommand = false,
}) {
  return File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com
hooks:
  postPackage:
    - command: ./tool/sign_release_json.sh
      platforms: [windows]
${customCommand ? "customCommand:\n  command: exit 0" : ""}
""");
}

ReleaseHookCommandRunner _descriptorSigningHook({
  required List<int> seed,
  required String publicKeyId,
}) {
  return (_, {required environment}) async {
    await ReleaseDescriptorSigner().sign(
      releaseFile: File(environment["DESKTOP_UPDATER_RELEASE_FILE"]!),
      publicKeyId: publicKeyId,
      privateKeyBase64: base64Encode(seed),
    );
    return ProcessResult(0, 0, "", "");
  };
}

Future<Map<String, String>> _publicKeysForSeed(List<int> seed) async {
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  return <String, String>{"stable-2026": base64Encode(publicKey.bytes)};
}

MockClient _missingHostedIndexClient() {
  return MockClient((_) async => http.Response("not found", 404));
}

MockClient _webRootClient(
  Directory webRoot, {
  required String hostedArchiveEtag,
}) {
  return MockClient((request) async {
    final relativePath = Uri.decodeComponent(
      request.url.path.replaceFirst(RegExp(r"^/+"), ""),
    );
    final file = File(path.join(webRoot.path, relativePath));
    if (!await file.exists()) {
      return http.Response("not found", 404, request: request);
    }
    return http.Response.bytes(
      await file.readAsBytes(),
      200,
      request: request,
      headers: relativePath == "app-archive.json"
          ? {"etag": hostedArchiveEtag}
          : const {},
    );
  });
}

Future<File> _writeSignedAppArchive({
  required Directory root,
  required String relativePath,
  required List<int> seed,
  required List<ReleaseIndexItem> items,
}) async {
  final file = File(path.join(root.path, relativePath));
  await file.parent.create(recursive: true);
  await _writeJsonFileForTest(
    file,
    ReleaseIndex(
      schemaVersion: 3,
      appName: "Egas-Manager",
      items: items,
    ).toJson(),
  );
  await ReleaseIndexSigner().sign(
    appArchiveFile: file,
    publicKeyId: "stable-2026",
    privateKeyBase64: base64Encode(seed),
  );
  return file;
}

Future<void> _configureCustomCommandUpload(
  Directory root,
  Directory webRoot,
) async {
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com
customCommand:
  command: dart test/e2e/fixtures/upload_commands/copy_updates.dart ${r"$DESKTOP_UPDATER_LOCAL_ROOT"} ${webRoot.path}
""");
}

Future<void> _configureIndexMutationHook(Directory root) async {
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com
hooks:
  postPackage:
    - command: ./tool/mutate_app_archive.sh
      platforms: [windows]
""");
}

Future<void> _writeJsonFileForTest(File file, Map<String, dynamic> json) async {
  await file.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert(json)}\n",
  );
}

Future<Directory> _createWindowsFixture() async {
  return _createFixture("windows");
}

Future<Directory> _createFixture(String platform) async {
  final root = await Directory.systemTemp.createTemp("publish_build_");
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: egas_manager
version: 2.1.0
""");
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com
""");
  if (platform == "linux") {
    final linux = Directory(path.join(root.path, "linux"));
    await linux.create(recursive: true);
    await File(path.join(linux.path, "CMakeLists.txt")).writeAsString("""
set(APPLICATION_ID "com.example.egasManager")
""");
  }
  return root;
}

Future<Directory> _createHookFixture() async {
  final root = await Directory.systemTemp.createTemp("publish_hooks_");
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: egas_manager
version: 2.1.0
""");
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com

hooks:
  prePackage:
    - command: ./tool/sign_windows_release.ps1
      platforms: [windows]
  postPackage:
    - command: ./tool/sign_release_json.sh
      platforms: [windows]
""");
  return root;
}

class _BuildProcessCall {
  const _BuildProcessCall({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.runInShell,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final bool runInShell;
}

class _HookCall {
  const _HookCall(this.command, this.environment);

  final String command;
  final Map<String, String> environment;
}

class _FakeBuildProcess implements BuildProcess {
  const _FakeBuildProcess({this.stdoutText = "", this.stderrText = ""});

  final String stdoutText;
  final String stderrText;

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(stdoutText));

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(stderrText));

  @override
  Future<int> get exitCode async => 0;
}

class _RecordingPackager implements ReleasePackager {
  _RecordingPackager(this.commands);

  final List<String> commands;
  final List<ReleasePackageRequest> requests = [];

  @override
  Future<ReleasePackageResult> package(ReleasePackageRequest request) async {
    requests.add(request);
    commands.add("PACKAGE ${request.input.path}");
    await request.outputDirectory.create(recursive: true);
    final artifact = File(
      path.join(
        request.outputDirectory.path,
        request.artifactUrl.pathSegments.last,
      ),
    );
    await artifact.writeAsString("zip");
    final release = File(
      path.join(request.outputDirectory.path, "release.json"),
    );
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "zip",
        url: request.artifactUrl,
        sha256: "a" * 64,
        length: await artifact.length(),
      ),
      install: ReleaseInstall(strategy: request.installStrategy),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.utc(2026, 6, 12),
    );
    await release.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );
    return ReleasePackageResult(
      artifact: artifact,
      releaseFile: release,
      descriptor: descriptor,
    );
  }
}

class _FakeInnoPackager extends InnoInstallerPackager {
  _FakeInnoPackager();

  final List<ReleasePackageRequest> requests = [];
  final List<String?> outputBaseNames = [];

  @override
  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required InnoPublishConfig config,
    String? outputBaseName,
  }) async {
    requests.add(request);
    outputBaseNames.add(outputBaseName);
    await request.outputDirectory.create(recursive: true);
    final artifactName = outputBaseName == null
        ? "Egas-Manager-2.1.0-windows.exe"
        : "$outputBaseName.exe";
    final artifact = File(
      path.join(request.outputDirectory.path, artifactName),
    );
    await artifact.writeAsString("exe");
    final release = File(
      path.join(request.outputDirectory.path, "release.json"),
    );
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "innoInstaller",
        url: request.artifactUrl,
        sha256: "b" * 64,
        length: await artifact.length(),
      ),
      install: ReleaseInstall(
        strategy: "innoInstaller",
        inno: ReleaseInnoInstall(
          silentArgs: ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
          inheritInstallDirectory: true,
          installedExecutableRelativePath:
              request.executableRelativePath ?? "Example.exe",
          installedExecutableSha256: "cd" * 32,
          logFileName: "desktop_updater_inno_install.log",
          relaunchAfterInstall: true,
          requiresElevation: "always",
          authenticode: ReleaseAuthenticodePolicy(
            required: true,
            sha256Thumbprints: [
              "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
            ],
          ),
        ),
      ),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.utc(2026, 6, 12),
    );
    await release.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );
    return ReleasePackageResult(
      artifact: artifact,
      releaseFile: release,
      descriptor: descriptor,
    );
  }
}

class _FakeDmgPackager extends DmgPackager {
  _FakeDmgPackager();

  final List<ReleasePackageRequest> requests = [];
  final List<MacOSDmgPublishConfig> configs = [];

  @override
  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required MacOSDmgPublishConfig config,
    MacOSPublishConfig? publishConfig,
  }) async {
    requests.add(request);
    configs.add(config);
    await request.outputDirectory.create(recursive: true);
    final artifact = File(
      path.join(request.outputDirectory.path, "Egas-Manager-2.1.0-macos.dmg"),
    );
    await artifact.writeAsString("dmg");
    final release = File(
      path.join(request.outputDirectory.path, "release.json"),
    );
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "dmg",
        url: request.artifactUrl,
        sha256: "c" * 64,
        length: await artifact.length(),
      ),
      install: ReleaseInstall(
        strategy: "wholeBundleReplace",
        macosDmg: ReleaseMacOSDmgInstall(
          appBundleName: config.appBundleName,
          verifyPrimarySignature: true,
        ),
      ),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.utc(2026, 6, 12),
    );
    await release.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );
    return ReleasePackageResult(
      artifact: artifact,
      releaseFile: release,
      descriptor: descriptor,
    );
  }
}

class _StubMacOSReleaseTrust extends MacOSReleaseTrust {
  @override
  Future<void> verifyInstallReadiness({
    required MacOSReleaseInventory inventory,
  }) async {}

  @override
  Future<MacOSReleaseInventory> preflight({
    required Directory app,
    String? expectedApplicationIdentifier,
  }) async {
    final identifier = expectedApplicationIdentifier ?? "com.example.app";
    return MacOSReleaseInventory(
      app: app,
      applicationIdentifier: identifier,
      targets: [
        MacOSCodeTarget(
          path: app.path,
          kind: MacOSCodeTargetKind.application,
          identifier: identifier,
          bundleIdentifier: identifier,
        ),
      ],
    );
  }

  @override
  Future<void> signAndVerify({
    required MacOSReleaseInventory inventory,
    required String identity,
  }) async {}

  @override
  Future<MacOSNotarySubmission> submit({
    required File archive,
    required String profile,
    String? keychain,
  }) async {
    return const MacOSNotarySubmission(
      id: "stub-notary-test",
      status: "Accepted",
    );
  }

  @override
  Future<void> stapleAndAssess({
    required FileSystemEntity artifact,
    required bool gatekeeperExecute,
    required bool gatekeeperInstall,
  }) async {}

  @override
  Future<void> auditFinalArtifact({
    required File artifact,
    required String kind,
    required String appBundleName,
    required String expectedApplicationIdentifier,
  }) async {}
}

class _FakePkgPackager extends PkgPackager {
  _FakePkgPackager();

  final List<ReleasePackageRequest> requests = [];
  final List<MacOSPkgPublishConfig> configs = [];

  @override
  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required MacOSPkgPublishConfig config,
    MacOSPublishConfig? publishConfig,
  }) async {
    requests.add(request);
    configs.add(config);
    await request.outputDirectory.create(recursive: true);
    final artifact = File(
      path.join(request.outputDirectory.path, "Egas-Manager-2.1.0-macos.pkg"),
    );
    await artifact.writeAsString("pkg");
    final release = File(
      path.join(request.outputDirectory.path, "release.json"),
    );
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "pkgInstaller",
        url: request.artifactUrl,
        sha256: "d" * 64,
        length: await artifact.length(),
      ),
      install: ReleaseInstall(
        strategy: "pkgInstaller",
        macosPkg: ReleaseMacOSPkgInstall(
          launchMode: "privilegedInstallerTool",
          expectedPackageIds: [config.packageIdentifier],
          relaunchAfterInstall: false,
        ),
      ),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.utc(2026, 6, 12),
    );
    await release.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );
    return ReleasePackageResult(
      artifact: artifact,
      releaseFile: release,
      descriptor: descriptor,
    );
  }
}

Future<ProcessResult> _fakeMacOSNotarizationProcess(
  String executable,
  List<String> arguments,
) async {
  if (executable == "/usr/bin/ditto" && arguments.first == "-c") {
    await File(arguments.last).writeAsBytes(<int>[1, 2, 3]);
  }
  if (executable == "/usr/bin/xcrun" && arguments.contains("notarytool")) {
    return ProcessResult(0, 0, '{"status":"Accepted","id":"notary-test"}', "");
  }
  return ProcessResult(0, 0, "", "");
}
