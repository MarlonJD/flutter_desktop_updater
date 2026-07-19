import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../tool/macos_pkg_artifact_audit.dart" as audit;

void main() {
  test("macOS PKG artifact audit exposes the fail-closed trust contract", () {
    final auditFile = File("tool/macos_pkg_artifact_audit.dart");
    expect(
      auditFile.existsSync(),
      isTrue,
      reason: "the current-head artifact audit tool must exist",
    );
    if (!auditFile.existsSync()) return;

    final source = auditFile.readAsStringSync();
    for (final option in [
      "--source-app",
      "--pkg",
      "--expected-team-id",
      "--expected-version",
      "--expected-build",
      "--expected-bundle-id",
      "--expected-receipt-id",
      "--git-commit",
      "--notarization-submission-id",
      "--evidence",
    ]) {
      expect(source, contains(option), reason: option);
    }

    expect(source, contains("component.pkg"));
    expect(source, contains("Payload"));
    expect(source, contains("Contents"));
    expect(source, contains("MacOS"));
    expect(source, contains("DesktopUpdaterInstallHelper"));
    expect(source, contains('"--verify"'));
    expect(source, contains('"--deep"'));
    expect(source, contains('"--strict"'));
    expect(source, contains('"--expand-full"'));
    expect(source, contains('"--check-signature"'));
    expect(
      source,
      matches(RegExp(r'"--type",\s*"execute"', multiLine: true)),
    );
    expect(
      source,
      matches(RegExp(r'"--type",\s*"install"', multiLine: true)),
    );
    expect(
      RegExp(r'"stapler",\s*"validate"', multiLine: true).allMatches(source),
      hasLength(greaterThanOrEqualTo(2)),
    );
    expect(source, contains("followLinks: false"));
    expect(source, contains("_validateEvidenceDocument"));
  });

  test("macOS PKG artifact audit declares only sanitized success evidence", () {
    final auditFile = File("tool/macos_pkg_artifact_audit.dart");
    if (!auditFile.existsSync()) return;
    final source = auditFile.readAsStringSync();

    for (final field in [
      '"schemaVersion"',
      '"status"',
      '"gitCommit"',
      '"artifactSHA256"',
      '"bundleIdentifier"',
      '"receiptIdentifier"',
      '"version"',
      '"build"',
      '"teamIdentifier"',
      '"sourceAppSignatureValid"',
      '"payloadAppSignatureValid"',
      '"payloadHelperSignatureValid"',
      '"packageSignatureValid"',
      '"appStapleValid"',
      '"packageStapleValid"',
      '"gatekeeperExecuteAccepted"',
      '"gatekeeperInstallAccepted"',
      '"notarizationSubmissionId"',
    ]) {
      expect(source, contains(field), reason: field);
    }
    expect(source, contains('"verified locally"'));
    expect(source, contains('"candidate-only"'));
    expect(source, contains('"failureClass"'));
    expect(source, contains("_forbiddenEvidenceKeys"));
    expect(source, contains("_absolutePathPattern"));
  });

  test("macOS PKG artifact audit writes exact verified evidence", () async {
    final fixture = await _createFixture("pkg_artifact_audit_success_");
    addTearDown(fixture.dispose);
    final commands = <(String, List<String>)>[];

    final result = await audit.runMacOSPkgArtifactAudit(
      fixture.request,
      hostIsMacOS: true,
      runProcess: (executable, arguments) async {
        commands.add((executable, List<String>.of(arguments)));
        await fixture.materializeExpansion(executable, arguments);
        return fixture.successResult(executable, arguments);
      },
    );

    expect(result.verified, isTrue);
    expect(result.failureClass, isNull);
    final evidenceSource = await fixture.evidence.readAsString();
    final evidence = jsonDecode(evidenceSource) as Map<String, dynamic>;
    expect(evidence.keys.toSet(), {
      "schemaVersion",
      "status",
      "gitCommit",
      "artifactSHA256",
      "bundleIdentifier",
      "receiptIdentifier",
      "version",
      "build",
      "teamIdentifier",
      "sourceAppSignatureValid",
      "payloadAppSignatureValid",
      "payloadHelperSignatureValid",
      "packageSignatureValid",
      "appStapleValid",
      "packageStapleValid",
      "gatekeeperExecuteAccepted",
      "gatekeeperInstallAccepted",
      "notarizationSubmissionId",
    });
    expect(evidence["schemaVersion"], 1);
    expect(evidence["status"], "verified locally");
    expect(evidence["gitCommit"], _gitCommit);
    expect(
      evidence["artifactSHA256"],
      crypto.sha256.convert(await fixture.pkg.readAsBytes()).toString(),
    );
    expect(evidence["bundleIdentifier"], "net.monolib.updater");
    expect(evidence["receiptIdentifier"], "net.monolib.updater.pkg");
    expect(evidence["version"], "2.7.1");
    expect(evidence["build"], "271");
    expect(evidence["teamIdentifier"], "UPK4SC93AN");
    expect(evidence["notarizationSubmissionId"], _submissionId);
    expect(evidence.values.whereType<bool>(), everyElement(isTrue));
    expect(evidenceSource, isNot(contains(fixture.root.path)));

    final strictPaths = commands
        .where(
          (command) =>
              command.$1 == "/usr/bin/codesign" &&
              command.$2.isNotEmpty &&
              command.$2.first == "--verify",
        )
        .map((command) => command.$2.last)
        .toSet();
    expect(strictPaths, hasLength(6));
    expect(
      strictPaths.where((value) => value.endsWith("MacOSRuntimeCompile")),
      hasLength(2),
    );
    expect(
      strictPaths.where(
        (value) => value.endsWith("DesktopUpdaterInstallHelper"),
      ),
      hasLength(2),
    );
    expect(
      commands,
      contains(
        predicate<(String, List<String>)>(
          (command) =>
              command.$1 == "/usr/sbin/pkgutil" &&
              command.$2.isNotEmpty &&
              command.$2.first == "--expand-full",
        ),
      ),
    );
    expect(
      commands,
      contains(
        predicate<(String, List<String>)>(
          (command) =>
              command.$1 == "/usr/sbin/spctl" && command.$2.contains("execute"),
        ),
      ),
    );
    expect(
      commands,
      contains(
        predicate<(String, List<String>)>(
          (command) =>
              command.$1 == "/usr/sbin/spctl" && command.$2.contains("install"),
        ),
      ),
    );
  });

  test("macOS PKG artifact audit sanitizes a payload helper failure", () async {
    final fixture = await _createFixture("pkg_artifact_audit_failure_");
    addTearDown(fixture.dispose);
    final commands = <(String, List<String>)>[];

    final result = await audit.runMacOSPkgArtifactAudit(
      fixture.request,
      hostIsMacOS: true,
      runProcess: (executable, arguments) async {
        commands.add((executable, List<String>.of(arguments)));
        await fixture.materializeExpansion(executable, arguments);
        if (executable == "/usr/bin/codesign" &&
            arguments.isNotEmpty &&
            arguments.first == "--verify" &&
            arguments.last.endsWith("DesktopUpdaterInstallHelper") &&
            arguments.last
                .contains("${path.separator}expanded${path.separator}")) {
          return ProcessResult(
            0,
            23,
            "identity: Developer ID Application: Private Example",
            "invalid signature at "
                "/Users/private/Library/Keychains/login.keychain-db",
          );
        }
        return fixture.successResult(executable, arguments);
      },
    );

    expect(result.status, "candidate-only");
    expect(result.failureClass, "payload-helper-signature-invalid");
    final evidenceSource = await fixture.evidence.readAsString();
    final evidence = jsonDecode(evidenceSource) as Map<String, dynamic>;
    expect(evidence, {
      "schemaVersion": 1,
      "status": "candidate-only",
      "failureClass": "payload-helper-signature-invalid",
    });
    expect(evidenceSource, isNot(contains("/Users/private")));
    expect(evidenceSource, isNot(contains("Developer ID Application")));
    expect(evidenceSource, isNot(contains("Keychains")));
    expect(
      commands.any(
        (command) =>
            command.$1 == "/usr/sbin/spctl" ||
            command.$2.contains("--check-signature"),
      ),
      isFalse,
    );
  });

  test("macOS PKG artifact audit classifies a receipt mismatch", () async {
    final fixture = await _createFixture(
      "pkg_artifact_audit_receipt_",
      packageReceiptId: "net.monolib.unexpected.pkg",
    );
    addTearDown(fixture.dispose);

    final result = await audit.runMacOSPkgArtifactAudit(
      fixture.request,
      hostIsMacOS: true,
      runProcess: (executable, arguments) async {
        await fixture.materializeExpansion(executable, arguments);
        return fixture.successResult(executable, arguments);
      },
    );

    expect(result.failureClass, "package-receipt-identifier-mismatch");
  });

  test("macOS PKG artifact audit classifies a package version mismatch",
      () async {
    final fixture = await _createFixture(
      "pkg_artifact_audit_version_",
      packageVersion: "9.9.9",
    );
    addTearDown(fixture.dispose);

    final result = await audit.runMacOSPkgArtifactAudit(
      fixture.request,
      hostIsMacOS: true,
      runProcess: (executable, arguments) async {
        await fixture.materializeExpansion(executable, arguments);
        return fixture.successResult(executable, arguments);
      },
    );

    expect(result.failureClass, "package-version-mismatch");
  });
}

const _gitCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const _submissionId = "123e4567-e89b-12d3-a456-426614174000";

Future<_AuditFixture> _createFixture(
  String prefix, {
  String packageReceiptId = "net.monolib.updater.pkg",
  String packageVersion = "2.7.1",
}) async {
  final root = await Directory.systemTemp.createTemp(prefix);
  final app = Directory(path.join(root.path, "Example.app"));
  await _writeApplication(app);
  final pkg = File(path.join(root.path, "Example.pkg"));
  await pkg.writeAsBytes([1, 3, 3, 7]);
  final evidence = File(path.join(root.path, "reports", "artifact-trust.json"));
  return _AuditFixture(
    root: root,
    app: app,
    pkg: pkg,
    evidence: evidence,
    packageReceiptId: packageReceiptId,
    packageVersion: packageVersion,
  );
}

Future<void> _writeApplication(Directory app) async {
  final info = File(path.join(app.path, "Contents", "Info.plist"));
  final main = File(
    path.join(app.path, "Contents", "MacOS", "MacOSRuntimeCompile"),
  );
  final helper = File(
    path.join(
      app.path,
      "Contents",
      "Helpers",
      "DesktopUpdaterInstallHelper",
    ),
  );
  await info.parent.create(recursive: true);
  await main.parent.create(recursive: true);
  await helper.parent.create(recursive: true);
  await info.writeAsString("plist");
  await main.writeAsString("main");
  await helper.writeAsString("helper");
}

class _AuditFixture {
  const _AuditFixture({
    required this.root,
    required this.app,
    required this.pkg,
    required this.evidence,
    required this.packageReceiptId,
    required this.packageVersion,
  });

  final Directory root;
  final Directory app;
  final File pkg;
  final File evidence;
  final String packageReceiptId;
  final String packageVersion;

  audit.MacOSPkgArtifactAuditRequest get request =>
      audit.MacOSPkgArtifactAuditRequest(
        sourceApp: app,
        pkg: pkg,
        expectedTeamId: "UPK4SC93AN",
        expectedVersion: "2.7.1",
        expectedBuild: "271",
        expectedBundleId: "net.monolib.updater",
        expectedReceiptId: "net.monolib.updater.pkg",
        gitCommit: _gitCommit,
        notarizationSubmissionId: _submissionId,
        evidence: evidence,
      );

  Future<void> materializeExpansion(
    String executable,
    List<String> arguments,
  ) async {
    if (executable != "/usr/sbin/pkgutil" ||
        arguments.isEmpty ||
        arguments.first != "--expand-full") {
      return;
    }
    final expanded = Directory(arguments.last);
    final payloadApp = Directory(
      path.join(
        expanded.path,
        "component.pkg",
        "Payload",
        path.basename(app.path),
      ),
    );
    await _writeApplication(payloadApp);
    await File(
      path.join(expanded.path, "component.pkg", "PackageInfo"),
    ).writeAsString(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<pkg-info overwrite-permissions="true" relocatable="false" '
      'identifier="$packageReceiptId" postinstall-action="none" '
      'version="$packageVersion" format-version="2" '
      'generator-version="InstallCmds-864.12" '
      'install-location="/Applications" auth="root">'
      '<payload numberOfFiles="17" installKBytes="2521"/>'
      '</pkg-info>',
    );
  }

  ProcessResult successResult(String executable, List<String> arguments) {
    if (executable == "/usr/bin/plutil") {
      return ProcessResult(
        0,
        0,
        jsonEncode({
          "CFBundleIdentifier": "net.monolib.updater",
          "CFBundleExecutable": "MacOSRuntimeCompile",
          "CFBundleShortVersionString": "2.7.1",
          "CFBundleVersion": "271",
        }),
        "",
      );
    }
    if (executable == "/usr/bin/codesign" &&
        arguments.isNotEmpty &&
        arguments.first == "-dvvv") {
      return ProcessResult(
        0,
        0,
        "",
        "TeamIdentifier=UPK4SC93AN\nflags=0x10000(runtime)\n",
      );
    }
    if (executable == "/usr/sbin/pkgutil" &&
        arguments.isNotEmpty &&
        arguments.first == "--check-signature") {
      return ProcessResult(
        0,
        0,
        "Developer ID Installer: Example (UPK4SC93AN)",
        "",
      );
    }
    return ProcessResult(0, 0, "", "");
  }

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}
