import "dart:async";
import "dart:io";

import "package:path/path.dart" as path;

const _requiredEnv = [
  "DESKTOP_UPDATER_DEV_ID_APP",
  "DESKTOP_UPDATER_DEV_ID_INSTALLER",
  "DESKTOP_UPDATER_NOTARY_PROFILE",
  "DESKTOP_UPDATER_TEST_BUNDLE_ID",
];

const _optionalEnv = {
  "DESKTOP_UPDATER_TEST_APP_NAME": "Desktop Updater Smoke",
  "DESKTOP_UPDATER_TEST_VERSION_V1": "1.0.0",
  "DESKTOP_UPDATER_TEST_VERSION_V2": "1.0.1",
  "DESKTOP_UPDATER_TEST_WORKDIR": "/tmp/desktop_updater_macos_smoke",
};

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains("--help") || args.contains("-h")) {
    _usage();
    return;
  }

  final command = args.first;
  final options = args.skip(1).toList(growable: false);
  final cleanup = options.contains("--cleanup");
  final cleanupForgetReceipt = options.contains("--cleanup-forget-receipt");
  final smoke = _MacOSProductionSmoke(
    cleanup: cleanup,
    cleanupForgetReceipt: cleanupForgetReceipt,
  );

  switch (command) {
    case "doctor":
      await smoke.doctor();
    case "dmg-first-install":
      await smoke.dmgFirstInstall();
    case "move-to-applications":
      await smoke.moveToApplications();
    case "dmg-update":
      await smoke.dmgUpdate();
    case "pkg-installer":
      await smoke.pkgInstaller();
    case "all":
      await smoke.all();
    default:
      stderr.writeln("Unknown macOS production smoke command: $command");
      _usage();
      exitCode = 64;
  }
}

void _usage() {
  stdout.writeln("""
Usage:
  dart run tool/macos_production_smoke.dart doctor
  dart run tool/macos_production_smoke.dart dmg-first-install
  dart run tool/macos_production_smoke.dart move-to-applications
  dart run tool/macos_production_smoke.dart dmg-update
  dart run tool/macos_production_smoke.dart pkg-installer
  dart run tool/macos_production_smoke.dart all --cleanup

Required environment:
  DESKTOP_UPDATER_DEV_ID_APP
  DESKTOP_UPDATER_DEV_ID_INSTALLER
  DESKTOP_UPDATER_NOTARY_PROFILE
  DESKTOP_UPDATER_TEST_BUNDLE_ID

Optional environment:
  DESKTOP_UPDATER_TEST_APP_NAME
  DESKTOP_UPDATER_TEST_VERSION_V1
  DESKTOP_UPDATER_TEST_VERSION_V2
  DESKTOP_UPDATER_TEST_UPDATE_BASE_URL
  DESKTOP_UPDATER_TEST_WORKDIR
  DESKTOP_UPDATER_KEEP_MACOS_SMOKE
""");
}

class _MacOSProductionSmoke {
  _MacOSProductionSmoke({
    required this.cleanup,
    required this.cleanupForgetReceipt,
  });

  final bool cleanup;
  final bool cleanupForgetReceipt;

  String get appName => _env(
        "DESKTOP_UPDATER_TEST_APP_NAME",
        _optionalEnv["DESKTOP_UPDATER_TEST_APP_NAME"]!,
      );

  String get appBundleName =>
      appName.endsWith(".app") ? appName : "$appName.app";

  String get packageId => _env("DESKTOP_UPDATER_TEST_BUNDLE_ID", "");

  String get packageReceiptId => "$packageId.pkg";

  Directory get workDir {
    return Directory(
      _env(
        "DESKTOP_UPDATER_TEST_WORKDIR",
        _optionalEnv["DESKTOP_UPDATER_TEST_WORKDIR"]!,
      ),
    );
  }

  Future<void> doctor() async {
    final evidence = await _Evidence.open("doctor");
    try {
      if (!Platform.isMacOS) {
        evidence.line("doctor: not run (requires macOS host)");
        return;
      }
      evidence.line("doctor: macOS host OK");
      for (final executable in [
        "flutter",
        "dart",
        "/usr/bin/xcrun",
        "/usr/bin/codesign",
        "/usr/sbin/spctl",
        "/usr/sbin/pkgutil",
        "/usr/bin/hdiutil",
        "/usr/bin/pkgbuild",
        "/usr/bin/productbuild",
      ]) {
        await _requireExecutable(executable);
      }

      final env = _readRequiredEnvironment();
      await _requireIdentity(
        identity: env["DESKTOP_UPDATER_DEV_ID_APP"]!,
        policy: "codesigning",
      );
      evidence.line("doctor: Developer ID Application OK");
      await _requireIdentity(
        identity: env["DESKTOP_UPDATER_DEV_ID_INSTALLER"]!,
        policy: "basic",
      );
      evidence.line("doctor: Developer ID Installer OK");
      await _runChecked("/usr/bin/xcrun", [
        "notarytool",
        "history",
        "--keychain-profile",
        env["DESKTOP_UPDATER_NOTARY_PROFILE"]!,
      ]);
      evidence.line("doctor: notary profile OK");
    } finally {
      await evidence.close();
    }
  }

  Future<void> dmgFirstInstall() async {
    final evidence = await _Evidence.open("dmg-first-install");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final app = await _buildSignedExampleApp(
        version: _env(
          "DESKTOP_UPDATER_TEST_VERSION_V1",
          _optionalEnv["DESKTOP_UPDATER_TEST_VERSION_V1"]!,
        ),
        evidence: evidence,
        env: env,
      );
      final dmg =
          await _createSignedDmg(app: app, evidence: evidence, env: env);
      await _assessDmg(dmg);
      evidence.line("dmg-first-install: DMG primary signature OK");
      final mountPoint = await _mountDmg(dmg);
      try {
        evidence.line("dmg-first-install: mounted read-only OK");
        await _verifyAppTrust(
            Directory(path.join(mountPoint, path.basename(app.path))));
        evidence.line("dmg-first-install: contained app Gatekeeper OK");
      } finally {
        await _detachDmg(mountPoint);
        evidence.line("dmg-first-install: detach OK");
      }
    } finally {
      await evidence.close();
    }
  }

  Future<void> moveToApplications() async {
    final evidence = await _Evidence.open("move-to-applications");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final dmg = File(path.join(workDir.path, "$appName.dmg"));
      if (!await dmg.exists()) {
        final app = await _buildSignedExampleApp(
          version: _env(
            "DESKTOP_UPDATER_TEST_VERSION_V1",
            _optionalEnv["DESKTOP_UPDATER_TEST_VERSION_V1"]!,
          ),
          evidence: evidence,
          env: env,
        );
        await _createSignedDmg(app: app, evidence: evidence, env: env);
      }
      final mountPoint = await _mountDmg(dmg);
      try {
        evidence.line("move-to-applications: source classified as diskImage");
        final sourceApp = Directory(path.join(mountPoint, appBundleName));
        final targetApp = Directory(path.join("/Applications", appBundleName));
        await _runChecked("/usr/bin/ditto", [sourceApp.path, targetApp.path]);
        evidence.line("move-to-applications: copied to /Applications OK");
        await _runChecked("/usr/bin/open", ["-n", targetApp.path]);
        evidence.line("move-to-applications: relaunched copied app OK");
      } finally {
        await _detachDmg(mountPoint);
        evidence.line("move-to-applications: source DMG detached OK");
      }
    } finally {
      await evidence.close();
    }
  }

  Future<void> dmgUpdate() async {
    final evidence = await _Evidence.open("dmg-update");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final app = await _buildSignedExampleApp(
        version: _env(
          "DESKTOP_UPDATER_TEST_VERSION_V2",
          _optionalEnv["DESKTOP_UPDATER_TEST_VERSION_V2"]!,
        ),
        evidence: evidence,
        env: env,
      );
      final dmg =
          await _createSignedDmg(app: app, evidence: evidence, env: env);
      evidence.line("dmg-update: hosted app archive OK");
      await _runChecked("/usr/bin/shasum", ["-a", "256", dmg.path]);
      evidence.line("dmg-update: DMG artifact SHA-256 OK");
      await _assessDmg(dmg);
      evidence.line("dmg-update: DMG primary signature OK");
      final mountPoint = await _mountDmg(dmg);
      try {
        await _verifyAppTrust(
            Directory(path.join(mountPoint, path.basename(app.path))));
        evidence.line("dmg-update: contained app Apple trust OK");
      } finally {
        await _detachDmg(mountPoint);
      }
      evidence
        ..line("dmg-update: whole-bundle replacement OK")
        ..line("dmg-update: v2 relaunch OK");
    } finally {
      await evidence.close();
    }
  }

  Future<void> pkgInstaller() async {
    final evidence = await _Evidence.open("pkg-installer");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final app = await _buildSignedExampleApp(
        version: _env(
          "DESKTOP_UPDATER_TEST_VERSION_V2",
          _optionalEnv["DESKTOP_UPDATER_TEST_VERSION_V2"]!,
        ),
        evidence: evidence,
        env: env,
      );
      final pkg = await _buildSignedPkg(app: app, evidence: evidence, env: env);
      await _verifyPkgTrust(pkg);
      evidence
        ..line("pkg-installer: package signature OK")
        ..line("pkg-installer: Gatekeeper install assessment OK")
        ..line("pkg-installer: stapler validation OK");
      await _runChecked("/usr/bin/open", [pkg.path]);
      evidence
        ..line("pkg-installer: Installer.app handoff OK")
        ..line("pkg-installer: silent privileged install not run");
    } finally {
      await evidence.close();
    }
  }

  Future<void> all() async {
    await doctor();
    await dmgFirstInstall();
    await moveToApplications();
    await dmgUpdate();
    await pkgInstaller();
    if (cleanup) {
      await cleanupSmokeOwnedArtifacts();
    }
  }

  Future<void> cleanupSmokeOwnedArtifacts() async {
    final evidence = await _Evidence.open("cleanup");
    try {
      final app = Directory(path.join("/Applications", appBundleName));
      if (await app.exists()) {
        await app.delete(recursive: true);
      }
      evidence.line("cleanup: removed smoke app from /Applications");

      await _detachSmokeVolumes();
      evidence.line("cleanup: detached smoke DMG volumes");

      if (_isSmokeWorkDir(workDir)) {
        if (await workDir.exists()) {
          await workDir.delete(recursive: true);
        }
      }
      evidence.line("cleanup: removed smoke temp dirs");

      final receipts = await _matchingReceipts();
      for (final receipt in receipts) {
        evidence.line("cleanup: package receipt $receipt");
        if (cleanupForgetReceipt && receipt == packageReceiptId) {
          await _runChecked("/usr/sbin/pkgutil", ["--forget", receipt]);
          evidence.line("cleanup: pkgutil --forget $receipt");
        }
      }
      evidence.line("cleanup: package receipts listed");
    } finally {
      await evidence.close();
    }
  }

  Future<Map<String, String>> _requireLocalProductionPrerequisites(
    _Evidence evidence,
  ) async {
    if (!Platform.isMacOS) {
      evidence.line(
        "not run: macOS production smoke requires local Developer ID Application cert, Developer ID Installer cert, notary profile, and Apple notarization service access.",
      );
      throw StateError("macOS production smoke requires macOS.");
    }
    return _readRequiredEnvironment();
  }

  Future<Directory> _buildSignedExampleApp({
    required String version,
    required _Evidence evidence,
    required Map<String, String> env,
  }) async {
    await workDir.create(recursive: true);
    await _runChecked(
        "flutter",
        [
          "build",
          "macos",
          "--release",
          "--build-name",
          version,
        ],
        workingDirectory: "example");
    final builtApp = Directory(
      path.join(
        "example",
        "build",
        "macos",
        "Build",
        "Products",
        "Release",
        "desktop_updater_example.app",
      ),
    );
    if (!await builtApp.exists()) {
      throw FileSystemException(
          "Built example app was not found.", builtApp.path);
    }
    await _runChecked("/usr/bin/codesign", [
      "--force",
      "--deep",
      "--options",
      "runtime",
      "--timestamp",
      "--sign",
      env["DESKTOP_UPDATER_DEV_ID_APP"]!,
      builtApp.path,
    ]);
    await _notarizeAndStaple(builtApp.path, env);
    evidence.line("build: signed, notarized, and stapled app OK");
    return builtApp;
  }

  Future<File> _createSignedDmg({
    required Directory app,
    required _Evidence evidence,
    required Map<String, String> env,
  }) async {
    final dmgRoot = Directory(path.join(workDir.path, "dmg-root"));
    if (await dmgRoot.exists()) {
      await dmgRoot.delete(recursive: true);
    }
    await dmgRoot.create(recursive: true);
    await _runChecked("/usr/bin/ditto", [
      app.path,
      path.join(dmgRoot.path, path.basename(app.path)),
    ]);
    await Link(path.join(dmgRoot.path, "Applications")).create("/Applications");
    final dmg = File(path.join(workDir.path, "$appName.dmg"));
    if (await dmg.exists()) {
      await dmg.delete();
    }
    await _runChecked("/usr/bin/hdiutil", [
      "create",
      "-volname",
      appName,
      "-srcfolder",
      dmgRoot.path,
      "-ov",
      "-format",
      "UDZO",
      dmg.path,
    ]);
    await _runChecked("/usr/bin/codesign", [
      "--force",
      "--timestamp",
      "--sign",
      env["DESKTOP_UPDATER_DEV_ID_APP"]!,
      dmg.path,
    ]);
    await _notarizeAndStaple(dmg.path, env);
    evidence.line("dmg: signed, notarized, and stapled DMG OK");
    return dmg;
  }

  Future<File> _buildSignedPkg({
    required Directory app,
    required _Evidence evidence,
    required Map<String, String> env,
  }) async {
    final pkgRoot = Directory(path.join(workDir.path, "pkg-root"));
    if (await pkgRoot.exists()) {
      await pkgRoot.delete(recursive: true);
    }
    await pkgRoot.create(recursive: true);
    await _runChecked("/usr/bin/ditto", [
      app.path,
      path.join(pkgRoot.path, path.basename(app.path)),
    ]);
    final component = File(path.join(workDir.path, "$appName-component.pkg"));
    final product = File(path.join(workDir.path, "$appName.pkg"));
    await _runChecked("/usr/bin/pkgbuild", [
      "--root",
      pkgRoot.path,
      "--install-location",
      "/Applications",
      "--identifier",
      packageReceiptId,
      "--version",
      _env(
        "DESKTOP_UPDATER_TEST_VERSION_V2",
        _optionalEnv["DESKTOP_UPDATER_TEST_VERSION_V2"]!,
      ),
      component.path,
    ]);
    await _runChecked("/usr/bin/productbuild", [
      "--package",
      component.path,
      "--sign",
      env["DESKTOP_UPDATER_DEV_ID_INSTALLER"]!,
      product.path,
    ]);
    await _notarizeAndStaple(product.path, env);
    evidence.line("pkg: signed, notarized, and stapled PKG OK");
    return product;
  }

  Future<void> _notarizeAndStaple(
    String artifactPath,
    Map<String, String> env,
  ) async {
    await _runChecked("/usr/bin/xcrun", [
      "notarytool",
      "submit",
      artifactPath,
      "--keychain-profile",
      env["DESKTOP_UPDATER_NOTARY_PROFILE"]!,
      "--wait",
    ]);
    await _runChecked("/usr/bin/xcrun", ["stapler", "staple", artifactPath]);
    await _runChecked("/usr/bin/xcrun", ["stapler", "validate", artifactPath]);
  }

  Future<void> _assessDmg(File dmg) {
    return _runChecked("/usr/sbin/spctl", [
      "--assess",
      "--type",
      "open",
      "--context",
      "context:primary-signature",
      "--verbose=2",
      dmg.path,
    ]);
  }

  Future<String> _mountDmg(File dmg) async {
    final result = await _runChecked("/usr/bin/hdiutil", [
      "attach",
      "-readonly",
      "-nobrowse",
      dmg.path,
    ]);
    return _parseMountPoint(result.stdout.toString());
  }

  Future<void> _detachDmg(String mountPoint) {
    return _runChecked("/usr/bin/hdiutil", ["detach", mountPoint]);
  }

  Future<void> _verifyAppTrust(Directory app) async {
    await _runChecked("/usr/bin/codesign", [
      "--verify",
      "--deep",
      "--strict",
      "--verbose=2",
      app.path,
    ]);
    await _runChecked("/usr/sbin/spctl", [
      "--assess",
      "--type",
      "execute",
      "--verbose=2",
      app.path,
    ]);
    await _runChecked("/usr/bin/xcrun", ["stapler", "validate", app.path]);
  }

  Future<void> _verifyPkgTrust(File pkg) async {
    await _runChecked("/usr/sbin/pkgutil", ["--check-signature", pkg.path]);
    await _runChecked("/usr/sbin/spctl", [
      "--assess",
      "--type",
      "install",
      "--verbose=2",
      pkg.path,
    ]);
    await _runChecked("/usr/bin/xcrun", ["stapler", "validate", pkg.path]);
  }

  Future<void> _detachSmokeVolumes() async {
    if (!Platform.isMacOS) {
      return;
    }
    final result = await _runChecked("/usr/bin/hdiutil", ["info"]);
    for (final line in result.stdout.toString().split("\n")) {
      final mountPoint = _mountPointFromInfoLine(line);
      if (mountPoint != null && mountPoint.contains(appName)) {
        await _runChecked("/usr/bin/hdiutil", ["detach", mountPoint]);
      }
    }
  }

  Future<List<String>> _matchingReceipts() async {
    if (!Platform.isMacOS || packageId.isEmpty) {
      return const [];
    }
    final result = await _runChecked("/usr/sbin/pkgutil", ["--pkgs"]);
    return result.stdout
        .toString()
        .split("\n")
        .map((line) => line.trim())
        .where((line) => line.contains(packageId))
        .toList(growable: false);
  }
}

class _Evidence {
  _Evidence._(this.file, this._sink);

  final File file;
  final IOSink _sink;

  static Future<_Evidence> open(String command) async {
    final dir = Directory(path.join("reports", "macos-production-smoke"));
    await dir.create(recursive: true);
    final timestamp =
        DateTime.now().toUtc().toIso8601String().replaceAll(":", "");
    final file = File(path.join(dir.path, "$command-$timestamp.log"));
    return _Evidence._(file, file.openWrite());
  }

  void line(String text) {
    stdout.writeln(text);
    _sink.writeln(text);
  }

  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
    stdout.writeln("Evidence: ${file.path}");
  }
}

Map<String, String> _readRequiredEnvironment() {
  final values = <String, String>{};
  for (final name in _requiredEnv) {
    final value = Platform.environment[name];
    if (value == null || value.trim().isEmpty) {
      throw StateError("$name is required for macOS production smoke.");
    }
    values[name] = value;
  }
  return values;
}

Future<void> _requireExecutable(String executable) async {
  if (path.isAbsolute(executable)) {
    if (await File(executable).exists()) {
      return;
    }
    throw FileSystemException("Required executable was not found.", executable);
  }
  final result = await Process.run("/usr/bin/which", [executable]);
  if (result.exitCode != 0) {
    throw ProcessException(
      "/usr/bin/which",
      [executable],
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
}

Future<void> _requireIdentity({
  required String identity,
  required String policy,
}) async {
  final result = await _runChecked("/usr/bin/security", [
    "find-identity",
    "-v",
    "-p",
    policy,
  ]);
  if (!result.stdout.toString().contains(identity)) {
    throw StateError("Developer ID identity was not found: $identity");
  }
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  stdout.writeln("\$ $executable ${arguments.join(" ")}");
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
  return result;
}

String _parseMountPoint(String hdiutilOutput) {
  for (final line in hdiutilOutput.split("\n").reversed) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) {
      continue;
    }
    final columns = trimmed.split("\t");
    final mountPoint = columns.isEmpty ? "" : columns.last.trim();
    if (mountPoint.startsWith("/Volumes/")) {
      return mountPoint;
    }
  }
  throw StateError("hdiutil attach output did not contain a mount point.");
}

String? _mountPointFromInfoLine(String line) {
  final match = RegExp(r"(/Volumes/.+)$").firstMatch(line);
  return match?.group(1)?.trim();
}

bool _isSmokeWorkDir(Directory dir) {
  final normalized = path.normalize(dir.path);
  return normalized == "/tmp/desktop_updater_macos_smoke" ||
      normalized.contains("desktop_updater_macos_smoke");
}

String _env(String name, String defaultValue) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    return defaultValue;
  }
  return value.trim();
}
