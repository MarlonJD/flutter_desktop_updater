import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
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

  @override
  Future<ReleasePackageResult> package(ReleasePackageRequest request) async {
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
