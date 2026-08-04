import "dart:io";

import "package:desktop_updater/src/cli/desktop_updater_cli.dart";
import "package:desktop_updater/src/package_version.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  late Directory projectRoot;

  setUp(() async {
    projectRoot = await Directory.systemTemp.createTemp(
      "desktop_updater_cli_",
    );
  });

  tearDown(() async {
    await projectRoot.delete(recursive: true);
  });

  test("top-level help documents only the supported commands", () async {
    final output = StringBuffer();

    final exitCode = await runDesktopUpdaterCli(
      const ["--help"],
      projectRoot: projectRoot,
      output: output,
    );

    expect(exitCode, 0);
    expect(output.toString(), contains("desktop-updater <command>"));
    for (final command in ["release", "package", "verify", "app-archive"]) {
      expect(output.toString(), contains(command));
    }
  });

  test("version reports the checked package version", () async {
    final output = StringBuffer();

    final exitCode = await runDesktopUpdaterCli(
      const ["--version"],
      projectRoot: projectRoot,
      output: output,
    );

    expect(exitCode, 0);
    expect(
      output.toString().trim(),
      "desktop-updater $desktopUpdaterPackageVersion",
    );
  });

  for (final testCase in const [
    (args: ["release", "publish", "--help"], expected: "project-type"),
    (args: ["package", "--help"], expected: "--input"),
    (args: ["verify", "--help"], expected: "--release"),
    (args: ["app-archive", "--help"], expected: "upsert"),
  ]) {
    test("${testCase.args.join(" ")} delegates to the existing command",
        () async {
      final output = StringBuffer();

      final exitCode = await runDesktopUpdaterCli(
        testCase.args,
        projectRoot: projectRoot,
        output: output,
      );

      expect(exitCode, 0);
      expect(output.toString(), contains(testCase.expected));
    });
  }

  test("package help keeps input and does not invent app-path", () async {
    final output = StringBuffer();

    final exitCode = await runDesktopUpdaterCli(
      const ["package", "--help"],
      projectRoot: projectRoot,
      output: output,
    );

    expect(exitCode, 0);
    expect(output.toString(), contains("--input"));
    expect(output.toString(), isNot(contains("--app-path")));
  });

  test("unknown commands return a usage error", () async {
    final output = StringBuffer();

    final exitCode = await runDesktopUpdaterCli(
      const ["unknown"],
      projectRoot: projectRoot,
      output: output,
    );

    expect(exitCode, 64);
    expect(output.toString(), contains("Unsupported command: unknown"));
  });

  test("CI builds the native-host standalone CLI candidate matrix", () async {
    final workflow = await File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsString();

    for (final artifactName in [
      "desktop-updater-macos-arm64",
      "desktop-updater-macos-x64",
      "desktop-updater-windows-x64.exe",
      "desktop-updater-linux-x64",
    ]) {
      expect(workflow, contains(artifactName));
    }
    expect(workflow, contains("macos-15"));
    expect(workflow, contains("macos-15-intel"));
    expect(workflow, contains("dart compile exe bin/desktop_updater.dart"));
    expect(workflow, contains("SHA256SUMS"));
    expect(workflow, contains("candidate-only"));
    expect(workflow, contains("actions/upload-artifact@v4"));
  });
}
