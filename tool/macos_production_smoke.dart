import "dart:async";
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
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
  "DESKTOP_UPDATER_TEST_BUILD_V1": "100",
  "DESKTOP_UPDATER_TEST_BUILD_V2": "101",
  "DESKTOP_UPDATER_TEST_WORKDIR": "/tmp/desktop_updater_macos_smoke",
};

const _smokeOwnerFileName = "desktop_updater_smoke_owner.txt";
const _updateSentinelFileName = "desktop_updater_smoke.txt";

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

  try {
    switch (command) {
      case "doctor":
        await smoke.doctor();
      case "app-update":
        await smoke.appUpdate();
      case "dmg-first-install":
        await smoke.dmgFirstInstall();
      case "move-to-applications":
        await smoke.moveToApplications();
      case "dmg-update":
        await smoke.dmgUpdate();
      case "pkg-installer":
        await smoke.pkgInstaller();
      case "pkg-install-verify":
        await smoke.pkgInstallVerify();
      case "all":
        await smoke.all();
      default:
        stderr.writeln("Unknown macOS production smoke command: $command");
        _usage();
        exitCode = 64;
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

void _usage() {
  stdout.writeln("""
Usage:
  dart run tool/macos_production_smoke.dart doctor
  dart run tool/macos_production_smoke.dart app-update
  dart run tool/macos_production_smoke.dart dmg-first-install
  dart run tool/macos_production_smoke.dart move-to-applications
  dart run tool/macos_production_smoke.dart dmg-update
  dart run tool/macos_production_smoke.dart pkg-installer
  dart run tool/macos_production_smoke.dart pkg-install-verify
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
  DESKTOP_UPDATER_TEST_BUILD_V1
  DESKTOP_UPDATER_TEST_BUILD_V2
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

  String get versionV1 => _env(
        "DESKTOP_UPDATER_TEST_VERSION_V1",
        _optionalEnv["DESKTOP_UPDATER_TEST_VERSION_V1"]!,
      );

  String get versionV2 => _env(
        "DESKTOP_UPDATER_TEST_VERSION_V2",
        _optionalEnv["DESKTOP_UPDATER_TEST_VERSION_V2"]!,
      );

  String get buildV1 => _env(
        "DESKTOP_UPDATER_TEST_BUILD_V1",
        _optionalEnv["DESKTOP_UPDATER_TEST_BUILD_V1"]!,
      );

  String get buildV2 => _env(
        "DESKTOP_UPDATER_TEST_BUILD_V2",
        _optionalEnv["DESKTOP_UPDATER_TEST_BUILD_V2"]!,
      );

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
        "/usr/bin/osascript",
        "/usr/sbin/installer",
      ]) {
        await _requireExecutable(executable);
      }

      final env = _readRequiredEnvironment(evidence: evidence);
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
        version: versionV1,
        buildNumber: buildV1,
        includeUpdateSentinel: false,
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
          Directory(path.join(mountPoint, path.basename(app.path))),
        );
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
          version: versionV1,
          buildNumber: buildV1,
          includeUpdateSentinel: false,
          evidence: evidence,
          env: env,
        );
        await _createSignedDmg(app: app, evidence: evidence, env: env);
      }
      final mountPoint = await _mountDmg(dmg);
      try {
        evidence.line("move-to-applications: source classified as diskImage");
        final sourceApp = Directory(path.join(mountPoint, appBundleName));
        final targetApp = await _installSmokeAppToApplications(
          app: sourceApp,
          evidence: evidence,
        );
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

  Future<void> appUpdate() async {
    final evidence = await _Evidence.open("app-update");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final v1App = await _buildSignedExampleApp(
        version: versionV1,
        buildNumber: buildV1,
        includeUpdateSentinel: false,
        evidence: evidence,
        env: env,
      );
      final installedApp = await _installSmokeAppToApplications(
        app: v1App,
        evidence: evidence,
      );
      evidence.line("app-update: installed v1 app OK");
      final v2App = await _buildSignedExampleApp(
        version: versionV2,
        buildNumber: buildV2,
        includeUpdateSentinel: true,
        evidence: evidence,
        env: env,
      );
      await _runDirectAppUpdateSmoke(app: installedApp, stagedApp: v2App);
      evidence.line("app-update: whole-bundle replacement OK");
      await _verifyAppTrust(installedApp);
      await _waitForRelaunchedApp(installedApp);
      evidence.line("app-update: v2 relaunch OK");
      await _terminateSmokeApp(installedApp);
    } finally {
      await evidence.close();
    }
  }

  Future<void> dmgUpdate() async {
    final evidence = await _Evidence.open("dmg-update");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final v1App = await _buildSignedExampleApp(
        version: versionV1,
        buildNumber: buildV1,
        includeUpdateSentinel: false,
        evidence: evidence,
        env: env,
      );
      final installedApp = await _installSmokeAppToApplications(
        app: v1App,
        evidence: evidence,
      );
      final app = await _buildSignedExampleApp(
        version: versionV2,
        buildNumber: buildV2,
        includeUpdateSentinel: true,
        evidence: evidence,
        env: env,
      );
      final dmg =
          await _createSignedDmg(app: app, evidence: evidence, env: env);
      await _runChecked("/usr/bin/shasum", ["-a", "256", dmg.path]);
      evidence.line("dmg-update: DMG artifact SHA-256 OK");
      await _assessDmg(dmg);
      evidence.line("dmg-update: DMG primary signature OK");
      final mountPoint = await _mountDmg(dmg);
      try {
        await _verifyAppTrust(
          Directory(path.join(mountPoint, path.basename(app.path))),
        );
        evidence.line("dmg-update: contained app Apple trust OK");
      } finally {
        await _detachDmg(mountPoint);
      }
      await _withHostedRelease(
        artifact: dmg,
        artifactKind: "dmg",
        version: versionV2,
        buildNumber: buildV2,
        install: {
          "strategy": "wholeBundleReplace",
          "macosDmg": {
            "appBundleName": appBundleName,
            "verifyPrimarySignature": true,
          },
        },
        evidence: evidence,
        hostedEvidenceLine: "dmg-update: hosted app archive OK",
        body: (appArchiveUrl) {
          return _runHostedUpdateSmoke(
            app: installedApp,
            appArchiveUrl: appArchiveUrl,
            expectInstallerHandoff: false,
          );
        },
      );
      evidence.line("dmg-update: whole-bundle replacement OK");
      await _waitForRelaunchedApp(installedApp);
      evidence.line("dmg-update: v2 relaunch OK");
      await _terminateSmokeApp(installedApp);
    } finally {
      await evidence.close();
    }
  }

  Future<void> pkgInstaller() async {
    final evidence = await _Evidence.open("pkg-installer");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final v1App = await _buildSignedExampleApp(
        version: versionV1,
        buildNumber: buildV1,
        includeUpdateSentinel: false,
        evidence: evidence,
        env: env,
      );
      final installedApp = await _installSmokeAppToApplications(
        app: v1App,
        evidence: evidence,
      );
      final app = await _buildSignedExampleApp(
        version: versionV2,
        buildNumber: buildV2,
        includeUpdateSentinel: true,
        evidence: evidence,
        env: env,
      );
      final pkg = await _buildSignedPkg(app: app, evidence: evidence, env: env);
      await _verifyPkgTrust(pkg);
      evidence
        ..line("pkg-installer: package signature OK")
        ..line("pkg-installer: Gatekeeper install assessment OK")
        ..line("pkg-installer: stapler validation OK");
      await _withHostedRelease(
        artifact: pkg,
        artifactKind: "pkgInstaller",
        version: versionV2,
        buildNumber: buildV2,
        install: {
          "strategy": "pkgInstaller",
          "macosPkg": {
            "launchMode": "installerApp",
            "expectedPackageIds": [packageReceiptId],
            "relaunchAfterInstall": false,
          },
        },
        evidence: evidence,
        hostedEvidenceLine: "pkg-installer: staged PKG update flow OK",
        body: (appArchiveUrl) {
          return _runHostedUpdateSmoke(
            app: installedApp,
            appArchiveUrl: appArchiveUrl,
            expectInstallerHandoff: true,
          );
        },
      );
      evidence
        ..line("pkg-installer: Installer.app handoff OK")
        ..line("pkg-installer: silent privileged install not run");
    } finally {
      await evidence.close();
    }
  }

  Future<void> pkgInstallVerify() async {
    final evidence = await _Evidence.open("pkg-install-verify");
    try {
      final env = await _requireLocalProductionPrerequisites(evidence);
      final v1App = await _buildSignedExampleApp(
        version: versionV1,
        buildNumber: buildV1,
        includeUpdateSentinel: false,
        evidence: evidence,
        env: env,
      );
      final installedApp = await _installSmokeAppToApplications(
        app: v1App,
        evidence: evidence,
        administratorApprovedReplacement: true,
      );
      evidence.line("pkg-install-verify: installed v1 app OK");
      final app = await _buildSignedExampleApp(
        version: versionV2,
        buildNumber: buildV2,
        includeUpdateSentinel: true,
        evidence: evidence,
        env: env,
      );
      final pkg = await _buildSignedPkg(app: app, evidence: evidence, env: env);
      await _verifyPkgTrust(pkg);
      evidence
        ..line("pkg-install-verify: package signature OK")
        ..line("pkg-install-verify: Gatekeeper install assessment OK")
        ..line("pkg-install-verify: stapler validation OK");
      await _runAdministratorApprovedPkgInstall(pkg);
      evidence.line("pkg-install-verify: administrator-approved install OK");
      await _verifyPkgReceipt();
      evidence.line("pkg-install-verify: receipt OK");
      await _verifyInstalledUpdateSentinel(installedApp);
      evidence.line("pkg-install-verify: installed v2 app OK");
      await _verifyAppTrust(installedApp);
      evidence.line("pkg-install-verify: installed app Apple trust OK");
    } finally {
      await evidence.close();
    }
  }

  Future<void> all() async {
    await doctor();
    await appUpdate();
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
        if (await _isSmokeOwnedMacOSApp(app)) {
          await app.delete(recursive: true);
        } else {
          evidence.line(
            "cleanup: skipped non-smoke app at ${app.path}",
          );
        }
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
    return _readRequiredEnvironment(evidence: evidence);
  }

  Future<Directory> _buildSignedExampleApp({
    required String version,
    required String buildNumber,
    required bool includeUpdateSentinel,
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
        "--build-number",
        buildNumber,
      ],
      workingDirectory: "example",
    );
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
        "Built example app was not found.",
        builtApp.path,
      );
    }
    final smokeApp = Directory(
      path.join(workDir.path, "apps", version, appBundleName),
    );
    if (await smokeApp.exists()) {
      await smokeApp.delete(recursive: true);
    }
    await smokeApp.parent.create(recursive: true);
    await _runChecked("/usr/bin/ditto", [builtApp.path, smokeApp.path]);
    await _writeSmokeOwnerMarker(smokeApp);
    final updateSentinel = File(
      path.join(
        smokeApp.path,
        "Contents",
        "Resources",
        _updateSentinelFileName,
      ),
    );
    if (await updateSentinel.exists()) {
      await updateSentinel.delete();
    }
    if (includeUpdateSentinel) {
      await updateSentinel.writeAsString(
        "desktop_updater macOS production smoke $version+$buildNumber\n",
      );
    }
    await _runChecked("/usr/bin/codesign", [
      "--force",
      "--deep",
      "--options",
      "runtime",
      "--timestamp",
      "--sign",
      env["DESKTOP_UPDATER_DEV_ID_APP"]!,
      smokeApp.path,
    ]);
    await _notarizeAndStaple(smokeApp.path, env);
    evidence.line("build: signed, notarized, and stapled app OK");
    return smokeApp;
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

  Future<Directory> _installSmokeAppToApplications({
    required Directory app,
    required _Evidence evidence,
    bool administratorApprovedReplacement = false,
  }) async {
    final targetApp = Directory(path.join("/Applications", appBundleName));
    if (await targetApp.exists() && !await _isSmokeOwnedMacOSApp(targetApp)) {
      evidence.line(
        "blocked: refusing to replace non-smoke app at ${targetApp.path}",
      );
      throw StateError(
        "Refusing to replace non-smoke app at ${targetApp.path}.",
      );
    }
    if (await targetApp.exists()) {
      if (administratorApprovedReplacement) {
        await _removeSmokeOwnedAppWithAdministratorApproval(targetApp);
        evidence.line(
          "install: removed smoke-owned app with administrator approval",
        );
      } else {
        await targetApp.delete(recursive: true);
      }
    }
    await _runChecked("/usr/bin/ditto", [app.path, targetApp.path]);
    await _verifyAppTrust(targetApp);
    return targetApp;
  }

  Future<void> _withHostedRelease({
    required File artifact,
    required String artifactKind,
    required String version,
    required String buildNumber,
    required Map<String, Object?> install,
    required _Evidence evidence,
    required String hostedEvidenceLine,
    required Future<void> Function(Uri appArchiveUrl) body,
  }) async {
    final hostedRoot =
        Directory(path.join(workDir.path, "hosted", artifactKind));
    if (await hostedRoot.exists()) {
      await hostedRoot.delete(recursive: true);
    }
    await hostedRoot.create(recursive: true);

    final hostedArtifact = File(
      path.join(hostedRoot.path, path.basename(artifact.path)),
    );
    await artifact.copy(hostedArtifact.path);

    await _withStaticServer(hostedRoot, (baseUrl) async {
      final artifactUrl =
          _resolveUrl(baseUrl, path.basename(hostedArtifact.path));
      final releaseUrl = _resolveUrl(baseUrl, "release.json");
      final appArchiveUrl = _resolveUrl(baseUrl, "app-archive.json");
      final artifactSha256 = await _sha256File(hostedArtifact);
      await File(path.join(hostedRoot.path, "release.json")).writeAsString(
        const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "packageId": packageId,
          "appName": appBundleName,
          "version": version,
          "buildNumber": int.parse(buildNumber),
          "platform": "macos",
          "channel": "stable",
          "artifact": {
            "kind": artifactKind,
            "url": artifactUrl.toString(),
            "sha256": artifactSha256,
            "length": await hostedArtifact.length(),
          },
          "install": install,
          "minimumUpdaterVersion": "2.0.0",
          "generatedAt": DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await File(path.join(hostedRoot.path, "app-archive.json")).writeAsString(
        const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "appName": appName,
          "items": [
            {
              "version": version,
              "buildNumber": int.parse(buildNumber),
              "platform": "macos",
              "channel": "stable",
              "mandatory": false,
              "release": releaseUrl.toString(),
            },
          ],
        }),
      );
      evidence.line(hostedEvidenceLine);
      await body(appArchiveUrl);
    });
  }

  Future<void> _runHostedUpdateSmoke({
    required Directory app,
    required Uri appArchiveUrl,
    required bool expectInstallerHandoff,
  }) async {
    final diagnosticsLogPath = path.join(
      workDir.path,
      "hosted-smoke-diagnostics-${expectInstallerHandoff ? "pkg" : "dmg"}.jsonl",
    );
    await File(diagnosticsLogPath).parent.create(recursive: true);
    final arguments = [
      "run",
      "example/tool/hosted_update_smoke.dart",
      "--app",
      app.path,
      "--app-archive-url",
      appArchiveUrl.toString(),
      "--production-gates",
      "--diagnostics-log",
      diagnosticsLogPath,
      if (expectInstallerHandoff)
        "--expect-installer-handoff"
      else
        "--relaunch",
    ];
    await _runChecked("dart", arguments);
  }

  Future<void> _runDirectAppUpdateSmoke({
    required Directory app,
    required Directory stagedApp,
  }) async {
    final diagnosticsLogPath = path.join(
      workDir.path,
      "direct-app-smoke-diagnostics.jsonl",
    );
    await File(diagnosticsLogPath).parent.create(recursive: true);
    await _runChecked("dart", [
      "run",
      "example/tool/updater_smoke.dart",
      "--app",
      app.path,
      "--staged-app",
      stagedApp.path,
      "--production-gates",
      "--relaunch",
      "--diagnostics-log",
      diagnosticsLogPath,
    ]);
  }

  Future<void> _waitForRelaunchedApp(Directory app) async {
    final executable = _macOSExecutablePath(app);
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      final result = await Process.run("/usr/bin/pgrep", ["-f", executable]);
      if (result.exitCode == 0) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException("Timed out waiting for relaunched app: $executable");
  }

  Future<void> _terminateSmokeApp(Directory app) async {
    await Process.run("/usr/bin/pkill", ["-f", _macOSExecutablePath(app)]);
  }

  Future<void> _writeSmokeOwnerMarker(Directory app) async {
    final marker = File(
      path.join(app.path, "Contents", "Resources", _smokeOwnerFileName),
    );
    await marker.parent.create(recursive: true);
    await marker.writeAsString(
      "desktop_updater macOS production smoke\n"
      "appName=$appName\n"
      "packageId=$packageId\n",
    );
  }

  Future<bool> _isSmokeOwnedMacOSApp(Directory app) async {
    final marker = File(
      path.join(app.path, "Contents", "Resources", _smokeOwnerFileName),
    );
    if (!await marker.exists()) {
      return false;
    }
    final contents = await marker.readAsString();
    return contents.contains("desktop_updater macOS production smoke") &&
        contents.contains("packageId=$packageId");
  }

  String _macOSExecutablePath(Directory app) {
    return path.join(app.path, "Contents", "MacOS", "desktop_updater_example");
  }

  Future<void> _notarizeAndStaple(
    String artifactPath,
    Map<String, String> env,
  ) async {
    if (artifactPath.endsWith(".app")) {
      await _notarizeAndStapleApp(Directory(artifactPath), env);
      return;
    }
    await _submitForNotarization(artifactPath, env);
    await _stapleAndValidate(artifactPath);
  }

  Future<void> _notarizeAndStapleApp(
    Directory app,
    Map<String, String> env,
  ) async {
    final notaryZip = File(path.join(app.parent.path, "notary-upload.zip"));
    if (await notaryZip.exists()) {
      await notaryZip.delete();
    }
    await _runChecked(
      "/usr/bin/ditto",
      [
        "-c",
        "-k",
        "--keepParent",
        path.basename(app.path),
        notaryZip.path,
      ],
      workingDirectory: app.parent.path,
    );
    try {
      await _notarizeAndStapleZip(notaryZip, app.path, env);
    } finally {
      if (await notaryZip.exists()) {
        await notaryZip.delete();
      }
    }
  }

  Future<void> _notarizeAndStapleZip(
    File notaryZip,
    String stapleTargetPath,
    Map<String, String> env,
  ) async {
    await _submitForNotarization(notaryZip.path, env);
    await _stapleAndValidate(stapleTargetPath);
  }

  Future<void> _submitForNotarization(
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
  }

  Future<void> _stapleAndValidate(String artifactPath) async {
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

  Future<void> _runAdministratorApprovedPkgInstall(File pkg) {
    final installerCommand =
        "/usr/sbin/installer -pkg ${_shellQuote(pkg.path)} -target /";
    return _runChecked("/usr/bin/osascript", [
      "-e",
      "do shell script ${_appleScriptString(installerCommand)} "
          "with administrator privileges",
    ]);
  }

  Future<void> _removeSmokeOwnedAppWithAdministratorApproval(
    Directory app,
  ) async {
    if (!await _isSmokeOwnedMacOSApp(app)) {
      throw StateError("Refusing to remove non-smoke app at ${app.path}.");
    }
    final removeCommand = "/bin/rm -rf -- ${_shellQuote(app.path)}";
    await _runChecked("/usr/bin/osascript", [
      "-e",
      "do shell script ${_appleScriptString(removeCommand)} "
          "with administrator privileges",
    ]);
  }

  Future<void> _verifyPkgReceipt() async {
    await _runChecked("/usr/sbin/pkgutil", ["--pkg-info", packageReceiptId]);
  }

  Future<void> _verifyInstalledUpdateSentinel(Directory app) async {
    final sentinel = File(
      path.join(app.path, "Contents", "Resources", _updateSentinelFileName),
    );
    if (!await sentinel.exists()) {
      throw FileSystemException(
        "Installed app did not contain the update sentinel.",
        sentinel.path,
      );
    }
    final contents = await sentinel.readAsString();
    final expected = "$versionV2+$buildV2";
    if (!contents.contains(expected)) {
      throw StateError(
        "Installed app sentinel did not contain expected version $expected.",
      );
    }
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

Future<T> _withStaticServer<T>(
  Directory root,
  Future<T> Function(Uri baseUrl) body,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    final relativePath = path.normalize(
      path.joinAll(request.uri.pathSegments.map(Uri.decodeComponent)),
    );
    if (relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final file = File(path.join(root.path, relativePath));
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response.headers.contentLength = await file.length();
    if (file.path.endsWith(".json")) {
      request.response.headers.contentType = ContentType.json;
    }
    await file.openRead().pipe(request.response);
  });

  try {
    final baseUrl = Uri.parse("http://127.0.0.1:${server.port}/");
    return await body(baseUrl);
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}

Uri _resolveUrl(Uri baseUrl, String segment) {
  return baseUrl.resolveUri(Uri(pathSegments: [segment]));
}

Future<String> _sha256File(File file) async {
  final digest = await crypto.sha256.bind(file.openRead()).first;
  return digest.toString();
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

Map<String, String> _readRequiredEnvironment({_Evidence? evidence}) {
  final values = <String, String>{};
  for (final name in _requiredEnv) {
    final value = Platform.environment[name];
    if (value == null || value.trim().isEmpty) {
      evidence?.line("blocked: $name is required for macOS production smoke.");
      evidence?.line(
        "blocked: macOS production smoke requires local Developer ID Application cert, Developer ID Installer cert, notary profile, and Apple notarization service access.",
      );
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

String _shellQuote(String value) {
  const singleQuote = "'";
  const escapedSingleQuote = r"'\''";
  return "$singleQuote${value.replaceAll(singleQuote, escapedSingleQuote)}"
      "$singleQuote";
}

String _appleScriptString(String value) {
  final backslash = String.fromCharCode(0x5c);
  final doubleQuote = String.fromCharCode(0x22);
  return "$doubleQuote"
      "${value.replaceAll(backslash, "$backslash$backslash").replaceAll(
            doubleQuote,
            "$backslash$doubleQuote",
          )}"
      "$doubleQuote";
}
