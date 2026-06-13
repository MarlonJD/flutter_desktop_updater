import "dart:io";

import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("missing desktop_updater.yaml prints a minimum config warning",
      () async {
    final root = await _createProject(writeConfig: false);
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "macos"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 0);
      expect(
        output.toString(),
        contains("WARNING: desktop_updater.yaml was not found."),
      );
      expect(output.toString(), contains("Minimum desktop_updater.yaml:"));
      expect(output.toString(), contains("updates:"));
      expect(
          output.toString(), contains("baseUrl: https://updates.example.com"));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("missing updates.baseUrl is a blocking config error", () async {
    final root = await _createProject(
      config: """
updates:
  channel: stable
""",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "linux"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 64);
      expect(
          output.toString(), contains("ERROR: updates.baseUrl is required."));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("http baseUrl warns without blocking", () async {
    final root = await _createProject(
      config: """
updates:
  baseUrl: http://updates.example.com
""",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "linux"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 0);
      expect(
        output.toString(),
        contains("WARNING: updates.baseUrl uses http://."),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("no upload provider reports manual upload expectation", () async {
    final root = await _createProject(config: _minimalConfig);
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "linux"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 0);
      expect(
        output.toString(),
        contains(
          "INFO: No upload provider configured; release publish will prepare a manual upload package.",
        ),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("windows without pre-package signing hook warns only", () async {
    final root = await _createProject(config: _minimalConfig);
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "windows"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 0);
      expect(
        output.toString(),
        contains(
          "WARNING: Windows production releases should configure a hooks.prePackage command for Authenticode signing.",
        ),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("linux direct zip without signed release.json hook warns only",
      () async {
    final root = await _createProject(config: _minimalConfig);
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "linux"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 0);
      expect(
        output.toString(),
        contains(
          "WARNING: Linux direct zip releases should sign release.json with a hooks.postPackage command or another pinned descriptor signature policy.",
        ),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("macos unsigned internal flow warns only", () async {
    final root = await _createProject(config: _minimalConfig);
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "macos"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 0);
      expect(
        output.toString(),
        contains(
          "WARNING: macOS production releases should enable macos.notarize or run an app-owned notarization gate before packaging.",
        ),
      );
      expect(output.toString(), contains("allowUnsignedMacOSUpdates"));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("semantic invalid config exits 64", () async {
    final root = await _createProject(
      config: """
updates:
  baseUrl: https://updates.example.com

s3:
  bucket: update-bucket

sftp:
  host: updates.example.com
  remotePath: /updates
  username: deploy
""",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "linux"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 64);
      expect(
        output.toString(),
        contains("ERROR: Only one upload provider can be configured."),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("unexpected config filesystem failure exits 1", () async {
    final root = await _createProject(writeConfig: false);
    final configDirectory =
        Directory(path.join(root.path, "desktop_updater.yaml"));
    await configDirectory.create();
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["doctor", "--platform", "linux"],
        projectRoot: root,
        output: output,
      );

      expect(exitCode, 1);
      expect(
        output.toString(),
        contains("ERROR: Unexpected release doctor failure:"),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}

const _minimalConfig = """
updates:
  baseUrl: https://updates.example.com
""";

Future<Directory> _createProject({
  String config = _minimalConfig,
  bool writeConfig = true,
}) async {
  final root = await Directory.systemTemp.createTemp("release_doctor_");
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: release_doctor_fixture
version: 2.0.1+201
""");
  if (writeConfig) {
    await File(path.join(root.path, "desktop_updater.yaml"))
        .writeAsString(config);
  }
  return root;
}
