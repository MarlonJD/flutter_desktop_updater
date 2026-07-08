import "dart:io";

import "package:desktop_updater/src/macos_update.dart";

class AppleTrustCommands {
  const AppleTrustCommands({this.runProcess = defaultProcessRunner});

  final ProcessRunner runProcess;

  Future<void> codesignApp({
    required Directory app,
    required String identity,
  }) async {
    await _runChecked("/usr/bin/codesign", [
      "--force",
      "--options",
      "runtime",
      "--timestamp",
      "--sign",
      identity,
      app.path,
    ]);
  }

  Future<void> codesignArtifact({
    required FileSystemEntity artifact,
    required String identity,
  }) async {
    await _runChecked("/usr/bin/codesign", [
      "--force",
      "--timestamp",
      "--sign",
      identity,
      artifact.path,
    ]);
  }

  Future<void> verifyApp(Directory app) async {
    await _runChecked("/usr/bin/codesign", [
      "--verify",
      "--deep",
      "--strict",
      "--verbose=2",
      app.path,
    ]);
    await _runChecked("/usr/bin/codesign", ["-dvvv", app.path]);
  }

  Future<void> submitForNotarization({
    required File archive,
    required String notaryProfile,
    String? keychain,
  }) async {
    await _runChecked("/usr/bin/xcrun", [
      "notarytool",
      "submit",
      archive.path,
      "--keychain-profile",
      notaryProfile,
      if (keychain != null) ...["--keychain", keychain],
      "--wait",
    ]);
  }

  Future<void> staple(FileSystemEntity artifact) async {
    await _runChecked("/usr/bin/xcrun", [
      "stapler",
      "staple",
      artifact.path,
    ]);
  }

  Future<void> validateStaple(FileSystemEntity artifact) async {
    await _runChecked("/usr/bin/xcrun", [
      "stapler",
      "validate",
      artifact.path,
    ]);
  }

  Future<void> assessExecute(Directory app) async {
    await _runChecked("/usr/sbin/spctl", [
      "--assess",
      "--type",
      "execute",
      "--verbose=2",
      app.path,
    ]);
  }

  Future<void> assessInstall(File pkg) async {
    await _runChecked("/usr/sbin/spctl", [
      "--assess",
      "--type",
      "install",
      "--verbose=2",
      pkg.path,
    ]);
  }

  Future<void> assessDmg(File dmg) async {
    await _runChecked("/usr/sbin/spctl", [
      "--assess",
      "--type",
      "open",
      "--context",
      "context:primary-signature",
      "--verbose=2",
      dmg.path,
    ]);
  }

  Future<void> checkPkgSignature(File pkg) async {
    await _runChecked("/usr/sbin/pkgutil", [
      "--check-signature",
      pkg.path,
    ]);
  }

  Future<ProcessResult> _runChecked(
    String executable,
    List<String> arguments,
  ) async {
    final result = await runProcess(executable, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        "Command failed with exit ${result.exitCode}: ${result.stderr}${result.stdout}",
        result.exitCode,
      );
    }
    return result;
  }
}
