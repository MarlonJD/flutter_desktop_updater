import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_installer_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/macos/dmg_packager.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/macos/pkg_packager.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";
import "package:flutter_test/flutter_test.dart";
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
        overrides: const ReleasePublishOverrides(),
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
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: packager,
      );

      await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
        output: StringBuffer(),
      );

      expect(packager.requests, hasLength(1));
      expect(packager.requests.single.appName, "Egas Manager.app");
      expect(
        packager.requests.single.artifactUrl.toString(),
        "https://updates.example.com/releases/2.1.0/macos/"
        "Egas%20Manager-2.1.0-macos.zip",
      );
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
    await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: generated
    appId: com.example.app
    outputBaseName: CustomSetup
""");
    try {
      final manifest = await publisher.publish(
        projectRoot: root,
        platform: "windows",
        overrides: const ReleasePublishOverrides(),
        output: output,
      );

      expect(manifest.artifact.kind, "innoInstaller");
      expect(manifest.artifact.path, "releases/2.1.0/windows/CustomSetup.exe");
      expect(
        manifest.artifact.url.toString(),
        "https://updates.example.com/releases/2.1.0/windows/CustomSetup.exe",
      );
      expect(
        innoPackager.requests.single.artifactUrl.toString(),
        "https://updates.example.com/releases/2.1.0/windows/CustomSetup.exe",
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
        "releases/2.1.0/windows/CustomSetup.exe",
      );
      expect(
        writtenManifest.artifact.url.toString(),
        "https://updates.example.com/releases/2.1.0/windows/CustomSetup.exe",
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
      );

      final manifest = await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
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
      );

      final manifest = await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
        output: output,
      );

      expect(zipPackager.requests, isEmpty);
      expect(pkgPackager.requests, hasLength(1));
      expect(
          pkgPackager.configs.single.packageIdentifier, "com.example.app.pkg");
      expect(pkgPackager.requests.single.installStrategy, "pkgInstaller");
      expect(pkgPackager.requests.single.minimumUpdaterVersion, "2.6.0");
      expect(manifest.artifact.kind, "pkgInstaller");
      expect(manifest.artifact.path, endsWith(".pkg"));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("release hooks run around packaging with environment contract",
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
        overrides: const ReleasePublishOverrides(),
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
        endsWith(path.join("releases", "2.1.0", "windows", "release.json")),
      );
      expect(
        hookCalls.last.environment["DESKTOP_UPDATER_PUBLISH_MANIFEST"],
        endsWith(".desktop_updater_publish.json"),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
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
  const _FakeBuildProcess({
    this.stdoutText = "",
    this.stderrText = "",
  });

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
      path.join(request.outputDirectory.path, "Egas-Manager-2.1.0-windows.zip"),
    );
    await artifact.writeAsString("zip");
    final release =
        File(path.join(request.outputDirectory.path, "release.json"));
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
    await release.writeAsString("{}");
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
    final release =
        File(path.join(request.outputDirectory.path, "release.json"));
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
      install: const ReleaseInstall(
        strategy: "innoInstaller",
        inno: ReleaseInnoInstall(
          silentArgs: ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
          inheritInstallDirectory: true,
          logFileName: "desktop_updater_inno_install.log",
          relaunchAfterInstall: true,
          requiresElevation: "auto",
          authenticode: ReleaseAuthenticodePolicy(required: false),
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
    final release =
        File(path.join(request.outputDirectory.path, "release.json"));
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
    final release =
        File(path.join(request.outputDirectory.path, "release.json"));
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
          launchMode: "installerApp",
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
  if (executable == "/usr/bin/xcrun" && arguments.contains("notarytool")) {
    return ProcessResult(
      0,
      0,
      '{"status":"Accepted","id":"notary-test"}',
      "",
    );
  }
  return ProcessResult(0, 0, "", "");
}
