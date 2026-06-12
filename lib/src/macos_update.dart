// ignore_for_file: public_member_api_docs

import "dart:io";

import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class MacOSAppIdentity {
  const MacOSAppIdentity({
    required this.bundleIdentifier,
    required this.teamIdentifier,
  });

  final String bundleIdentifier;
  final String teamIdentifier;
}

Future<ProcessResult> defaultProcessRunner(
  String executable,
  List<String> arguments,
) {
  return Process.run(executable, arguments);
}

Future<MacOSAppIdentity> readMacOSAppIdentity({
  required Directory appDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  return MacOSAppIdentity(
    bundleIdentifier: await readBundleIdentifier(
      appDirectory: appDirectory,
      runProcess: runProcess,
    ),
    teamIdentifier: await readCodeSignTeamIdentifier(
      appDirectory: appDirectory,
      runProcess: runProcess,
    ),
  );
}

void verifyReleaseManifestIdentity({
  required ReleaseManifest manifest,
  required MacOSAppIdentity identity,
}) {
  if (manifest.bundleIdentifier != identity.bundleIdentifier) {
    throw StateError(
      "Release manifest bundleIdentifier mismatch: expected "
      "${identity.bundleIdentifier}, got ${manifest.bundleIdentifier}",
    );
  }
  if (manifest.teamIdentifier != identity.teamIdentifier) {
    throw StateError(
      "Release manifest teamIdentifier mismatch: expected "
      "${identity.teamIdentifier}, got ${manifest.teamIdentifier}",
    );
  }
}

Future<void> verifyMacOSNativeGates({
  required Directory appDirectory,
  required String expectedBundleIdentifier,
  required String expectedTeamIdentifier,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  await _runChecked(
    "/usr/bin/codesign",
    ["--verify", "--deep", "--strict", "--verbose=2", appDirectory.path],
    runProcess,
  );
  await _runChecked(
    "/usr/sbin/spctl",
    ["--assess", "--type", "execute", "--verbose=2", appDirectory.path],
    runProcess,
  );
  await _runChecked(
    "/usr/bin/xcrun",
    ["stapler", "validate", appDirectory.path],
    runProcess,
  );

  final bundleIdentifier = await readBundleIdentifier(
    appDirectory: appDirectory,
    runProcess: runProcess,
  );
  if (bundleIdentifier != expectedBundleIdentifier) {
    throw StateError(
      "CFBundleIdentifier mismatch: expected $expectedBundleIdentifier, "
      "got $bundleIdentifier",
    );
  }

  final teamIdentifier = await readCodeSignTeamIdentifier(
    appDirectory: appDirectory,
    runProcess: runProcess,
  );
  if (teamIdentifier != expectedTeamIdentifier) {
    throw StateError(
      "TeamIdentifier mismatch: expected $expectedTeamIdentifier, "
      "got $teamIdentifier",
    );
  }
}

Future<String> readBundleIdentifier({
  required Directory appDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  final result = await _runChecked(
    "/usr/bin/plutil",
    [
      "-extract",
      "CFBundleIdentifier",
      "raw",
      "-o",
      "-",
      path.join(appDirectory.path, "Contents", "Info.plist"),
    ],
    runProcess,
  );
  return result.stdout.toString().trim();
}

Future<String> readCodeSignTeamIdentifier({
  required Directory appDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  final result = await _runChecked(
    "/usr/bin/codesign",
    ["-dv", "--verbose=4", appDirectory.path],
    runProcess,
  );
  final output = "${result.stdout}\n${result.stderr}";
  final match =
      RegExp(r"^TeamIdentifier=(.+)$", multiLine: true).firstMatch(output);
  final teamIdentifier = match?.group(1)?.trim();
  if (teamIdentifier == null || teamIdentifier.isEmpty) {
    throw StateError("codesign output did not contain TeamIdentifier.");
  }
  return teamIdentifier;
}

Future<void> runDittoCreateZip({
  required String appPath,
  required String archivePath,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  await _runChecked(
    "/usr/bin/ditto",
    ["-c", "-k", "--keepParent", "--sequesterRsrc", appPath, archivePath],
    runProcess,
  );
}

Future<void> runDittoExtractZip({
  required String archivePath,
  required String destination,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  await _runChecked(
    "/usr/bin/ditto",
    ["-x", "-k", archivePath, destination],
    runProcess,
  );
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments,
  ProcessRunner runProcess,
) async {
  final result = await runProcess(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "Command failed with exit ${result.exitCode}: "
      "${result.stderr}${result.stdout}",
      result.exitCode,
    );
  }
  return result;
}
