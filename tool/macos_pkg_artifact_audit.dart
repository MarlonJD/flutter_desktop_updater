import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:path/path.dart" as path;

typedef AuditProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

const _componentPackageName = "component.pkg";
const _payloadDirectoryName = "Payload";
const _helperExecutableName = "DesktopUpdaterInstallHelper";

class MacOSPkgArtifactAuditRequest {
  const MacOSPkgArtifactAuditRequest({
    required this.sourceApp,
    required this.pkg,
    required this.expectedTeamId,
    required this.expectedVersion,
    required this.expectedBuild,
    required this.expectedBundleId,
    required this.expectedReceiptId,
    required this.gitCommit,
    required this.notarizationSubmissionId,
    required this.evidence,
  });

  final Directory sourceApp;
  final File pkg;
  final String expectedTeamId;
  final String expectedVersion;
  final String expectedBuild;
  final String expectedBundleId;
  final String expectedReceiptId;
  final String gitCommit;
  final String notarizationSubmissionId;
  final File evidence;
}

class MacOSPkgArtifactAuditResult {
  const MacOSPkgArtifactAuditResult({
    required this.status,
    this.failureClass,
  });

  final String status;
  final String? failureClass;

  bool get verified => status == "verified locally";
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains("--help") || arguments.contains("-h")) {
    stdout.write(_usage);
    return;
  }
  final parser = _argumentParser();
  try {
    final parsed = parser.parse(arguments);
    final request = MacOSPkgArtifactAuditRequest(
      sourceApp: Directory(_requiredOption(parsed, "source-app")),
      pkg: File(_requiredOption(parsed, "pkg")),
      expectedTeamId: _requiredOption(parsed, "expected-team-id"),
      expectedVersion: _requiredOption(parsed, "expected-version"),
      expectedBuild: _requiredOption(parsed, "expected-build"),
      expectedBundleId: _requiredOption(parsed, "expected-bundle-id"),
      expectedReceiptId: _requiredOption(parsed, "expected-receipt-id"),
      gitCommit: _requiredOption(parsed, "git-commit"),
      notarizationSubmissionId:
          _requiredOption(parsed, "notarization-submission-id"),
      evidence: File(_requiredOption(parsed, "evidence")),
    );
    final result = await runMacOSPkgArtifactAudit(request);
    if (!result.verified) {
      stderr.writeln(
        "macOS PKG artifact audit failed: ${result.failureClass}",
      );
      exitCode = 1;
    }
  } on FormatException {
    stderr.writeln("Invalid macOS PKG artifact audit arguments.");
    stderr.write(_usage);
    exitCode = 64;
  } on Object {
    stderr.writeln("macOS PKG artifact audit failed: evidence-write-failed");
    exitCode = 1;
  }
}

const _usage = """
Usage: dart run tool/macos_pkg_artifact_audit.dart
  --source-app <path>
  --pkg <path>
  --expected-team-id <team-id>
  --expected-version <version>
  --expected-build <build>
  --expected-bundle-id <bundle-id>
  --expected-receipt-id <receipt-id>
  --git-commit <40-lowercase-hex>
  --notarization-submission-id <uuid>
  --evidence <path>
""";

ArgParser _argumentParser() {
  return ArgParser()
    ..addOption("source-app")
    ..addOption("pkg")
    ..addOption("expected-team-id")
    ..addOption("expected-version")
    ..addOption("expected-build")
    ..addOption("expected-bundle-id")
    ..addOption("expected-receipt-id")
    ..addOption("git-commit")
    ..addOption("notarization-submission-id")
    ..addOption("evidence");
}

String _requiredOption(ArgResults arguments, String name) {
  final value = arguments.option(name)?.trim();
  if (value == null || value.isEmpty) {
    throw FormatException("--$name is required");
  }
  return value;
}

Future<MacOSPkgArtifactAuditResult> runMacOSPkgArtifactAudit(
  MacOSPkgArtifactAuditRequest request, {
  AuditProcessRunner runProcess = _defaultProcessRunner,
  bool? hostIsMacOS,
}) async {
  try {
    await _validateRequest(
      request,
      hostIsMacOS: hostIsMacOS ?? Platform.isMacOS,
    );
    final artifactSHA256 =
        (await crypto.sha256.bind(request.pkg.openRead()).first).toString();
    await _executeTrustAudit(request, runProcess);
    final document = _successEvidence(request, artifactSHA256);
    await _writeEvidence(request.evidence, document);
    return const MacOSPkgArtifactAuditResult(status: "verified locally");
  } on _AuditFailure catch (failure) {
    return _recordFailure(request.evidence, failure.failureClass);
  } on Object {
    return _recordFailure(request.evidence, "unexpected-audit-failure");
  }
}

Future<MacOSPkgArtifactAuditResult> _recordFailure(
  File evidence,
  String failureClass,
) async {
  final document = _failureEvidence(failureClass);
  await _writeEvidence(evidence, document);
  return MacOSPkgArtifactAuditResult(
    status: "candidate-only",
    failureClass: failureClass,
  );
}

Future<void> _validateRequest(
  MacOSPkgArtifactAuditRequest request, {
  required bool hostIsMacOS,
}) async {
  if (!hostIsMacOS) {
    throw const _AuditFailure("host-unsupported");
  }
  if (!_teamIdPattern.hasMatch(request.expectedTeamId) ||
      !_versionPattern.hasMatch(request.expectedVersion) ||
      !_buildPattern.hasMatch(request.expectedBuild) ||
      !_identifierPattern.hasMatch(request.expectedBundleId) ||
      !_identifierPattern.hasMatch(request.expectedReceiptId) ||
      !_gitCommitPattern.hasMatch(request.gitCommit) ||
      !_uuidPattern.hasMatch(request.notarizationSubmissionId)) {
    throw const _AuditFailure("input-identifier-invalid");
  }
  if (!path.basename(request.sourceApp.path).endsWith(".app")) {
    throw const _AuditFailure("source-app-name-invalid");
  }
  await _requireExactDirectory(
    request.sourceApp.path,
    failureClass: "source-app-node-invalid",
  );
  await _requireExactFile(
    request.pkg.path,
    failureClass: "package-node-invalid",
  );
  final evidenceType = await FileSystemEntity.type(
    request.evidence.path,
    followLinks: false,
  );
  if (evidenceType != FileSystemEntityType.notFound &&
      evidenceType != FileSystemEntityType.file) {
    throw const _AuditFailure("evidence-output-invalid");
  }
}

Future<void> _executeTrustAudit(
  MacOSPkgArtifactAuditRequest request,
  AuditProcessRunner runProcess,
) async {
  final sourceMetadata = await _readBundleMetadata(
    request.sourceApp,
    request,
    scope: "source",
    runProcess: runProcess,
  );
  await _verifyBundle(
    request.sourceApp,
    sourceMetadata,
    expectedTeamId: request.expectedTeamId,
    scope: "source",
    runProcess: runProcess,
  );

  final temporaryRoot = await Directory.systemTemp.createTemp(
    "desktop_updater_pkg_audit_",
  );
  try {
    final expanded = Directory(path.join(temporaryRoot.path, "expanded"));
    await _runChecked(
      runProcess,
      "/usr/sbin/pkgutil",
      ["--expand-full", request.pkg.path, expanded.path],
      failureClass: "package-expand-failed",
    );
    final component = Directory(
      path.join(expanded.path, _componentPackageName),
    );
    await _requireExactDirectory(
      component.path,
      failureClass: "package-component-invalid",
    );
    final packageInfo = File(path.join(component.path, "PackageInfo"));
    await _validatePackageInfo(packageInfo, request);
    final payloadApp = Directory(
      path.join(
        component.path,
        _payloadDirectoryName,
        path.basename(request.sourceApp.path),
      ),
    );
    await _requireExactDirectory(
      payloadApp.path,
      failureClass: "payload-app-node-invalid",
    );
    final payloadMetadata = await _readBundleMetadata(
      payloadApp,
      request,
      scope: "payload",
      runProcess: runProcess,
    );
    if (payloadMetadata.executable != sourceMetadata.executable) {
      throw const _AuditFailure("payload-executable-mismatch");
    }
    await _verifyBundle(
      payloadApp,
      payloadMetadata,
      expectedTeamId: request.expectedTeamId,
      scope: "payload",
      runProcess: runProcess,
    );

    final packageSignature = await _runChecked(
      runProcess,
      "/usr/sbin/pkgutil",
      ["--check-signature", request.pkg.path],
      failureClass: "package-signature-invalid",
    );
    final packageSignatureOutput =
        "${packageSignature.stdout}\n${packageSignature.stderr}";
    final teamMarker = "(${request.expectedTeamId})";
    final teamLinePattern = RegExp(
      "Team Identifier:\\s*${RegExp.escape(request.expectedTeamId)}",
      caseSensitive: false,
    );
    if (!packageSignatureOutput.contains(teamMarker) &&
        !teamLinePattern.hasMatch(packageSignatureOutput)) {
      throw const _AuditFailure("package-team-identifier-mismatch");
    }

    for (final app in [request.sourceApp, payloadApp]) {
      await _runChecked(
        runProcess,
        "/usr/bin/xcrun",
        ["stapler", "validate", app.path],
        failureClass: "app-staple-invalid",
      );
      await _runChecked(
        runProcess,
        "/usr/sbin/spctl",
        ["--assess", "--type", "execute", "--verbose=2", app.path],
        failureClass: "gatekeeper-execute-rejected",
      );
    }
    await _runChecked(
      runProcess,
      "/usr/bin/xcrun",
      ["stapler", "validate", request.pkg.path],
      failureClass: "package-staple-invalid",
    );
    await _runChecked(
      runProcess,
      "/usr/sbin/spctl",
      [
        "--assess",
        "--type",
        "install",
        "--verbose=2",
        request.pkg.path,
      ],
      failureClass: "gatekeeper-install-rejected",
    );
  } finally {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  }
}

Future<_BundleMetadata> _readBundleMetadata(
  Directory app,
  MacOSPkgArtifactAuditRequest request, {
  required String scope,
  required AuditProcessRunner runProcess,
}) async {
  final info = File(path.join(app.path, "Contents", "Info.plist"));
  await _requireExactFile(
    info.path,
    failureClass: "$scope-metadata-invalid",
  );
  final result = await _runChecked(
    runProcess,
    "/usr/bin/plutil",
    ["-convert", "json", "-o", "-", info.path],
    failureClass: "$scope-metadata-invalid",
  );
  try {
    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException();
    }
    final executable = decoded["CFBundleExecutable"]?.toString() ?? "";
    if (decoded["CFBundleIdentifier"] != request.expectedBundleId ||
        decoded["CFBundleShortVersionString"] != request.expectedVersion ||
        decoded["CFBundleVersion"]?.toString() != request.expectedBuild ||
        !_simpleFileNamePattern.hasMatch(executable)) {
      throw const FormatException();
    }
    return _BundleMetadata(executable: executable);
  } on Object {
    throw _AuditFailure("$scope-metadata-mismatch");
  }
}

Future<void> _verifyBundle(
  Directory app,
  _BundleMetadata metadata, {
  required String expectedTeamId,
  required String scope,
  required AuditProcessRunner runProcess,
}) async {
  final mainExecutable = File(
    path.join(app.path, "Contents", "MacOS", metadata.executable),
  );
  final helper = File(
    path.join(
      app.path,
      "Contents",
      "Helpers",
      _helperExecutableName,
    ),
  );
  await _requireExactFile(
    mainExecutable.path,
    failureClass: "$scope-main-node-invalid",
  );
  await _requireExactFile(
    helper.path,
    failureClass: "$scope-helper-node-invalid",
  );

  await _verifySignedNode(
    app.path,
    expectedTeamId: expectedTeamId,
    failurePrefix: "$scope-app",
    deep: true,
    runProcess: runProcess,
  );
  await _verifySignedNode(
    mainExecutable.path,
    expectedTeamId: expectedTeamId,
    failurePrefix: "$scope-main",
    runProcess: runProcess,
  );
  await _verifySignedNode(
    helper.path,
    expectedTeamId: expectedTeamId,
    failurePrefix: "$scope-helper",
    runProcess: runProcess,
  );
}

Future<void> _verifySignedNode(
  String nodePath, {
  required String expectedTeamId,
  required String failurePrefix,
  required AuditProcessRunner runProcess,
  bool deep = false,
}) async {
  await _runChecked(
    runProcess,
    "/usr/bin/codesign",
    [
      "--verify",
      if (deep) "--deep",
      "--strict",
      "--verbose=2",
      nodePath,
    ],
    failureClass: "$failurePrefix-signature-invalid",
  );
  final details = await _runChecked(
    runProcess,
    "/usr/bin/codesign",
    ["-dvvv", "--entitlements", ":-", nodePath],
    failureClass: "$failurePrefix-signing-metadata-invalid",
  );
  final detailsOutput = "${details.stdout}\n${details.stderr}";
  if (!detailsOutput.contains("TeamIdentifier=$expectedTeamId")) {
    throw _AuditFailure("$failurePrefix-team-identifier-mismatch");
  }
  if (!RegExp(r"flags=.*\bruntime\b").hasMatch(detailsOutput)) {
    throw _AuditFailure("$failurePrefix-hardened-runtime-missing");
  }
}

Future<void> _validatePackageInfo(
  File packageInfo,
  MacOSPkgArtifactAuditRequest request,
) async {
  await _requireExactFile(
    packageInfo.path,
    failureClass: "package-info-invalid",
  );
  String contents;
  try {
    contents = await packageInfo.readAsString();
  } on Object {
    throw const _AuditFailure("package-info-invalid");
  }
  final packageInfoAttributes =
      RegExp(r"<pkg-info\b([^>]*)>").firstMatch(contents)?.group(1) ?? "";
  final identifier = RegExp(r'\bidentifier="([^"]+)"')
      .firstMatch(packageInfoAttributes)
      ?.group(1);
  final version = RegExp(r'\bversion="([^"]+)"')
      .firstMatch(packageInfoAttributes)
      ?.group(1);
  if (identifier != request.expectedReceiptId) {
    throw const _AuditFailure("package-receipt-identifier-mismatch");
  }
  if (version != request.expectedVersion) {
    throw const _AuditFailure("package-version-mismatch");
  }
}

Future<ProcessResult> _runChecked(
  AuditProcessRunner runProcess,
  String executable,
  List<String> arguments, {
  required String failureClass,
}) async {
  ProcessResult result;
  try {
    result = await runProcess(executable, arguments);
  } on Object {
    throw _AuditFailure(failureClass);
  }
  if (result.exitCode != 0) {
    throw _AuditFailure(failureClass);
  }
  return result;
}

Future<void> _requireExactDirectory(
  String nodePath, {
  required String failureClass,
}) async {
  if (await FileSystemEntity.type(nodePath, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw _AuditFailure(failureClass);
  }
}

Future<void> _requireExactFile(
  String nodePath, {
  required String failureClass,
}) async {
  if (await FileSystemEntity.type(nodePath, followLinks: false) !=
      FileSystemEntityType.file) {
    throw _AuditFailure(failureClass);
  }
}

Future<ProcessResult> _defaultProcessRunner(
  String executable,
  List<String> arguments,
) {
  return Process.run(executable, arguments);
}

Map<String, Object?> _successEvidence(
  MacOSPkgArtifactAuditRequest request,
  String artifactSHA256,
) {
  return {
    "schemaVersion": 1,
    "status": "verified locally",
    "gitCommit": request.gitCommit,
    "artifactSHA256": artifactSHA256,
    "bundleIdentifier": request.expectedBundleId,
    "receiptIdentifier": request.expectedReceiptId,
    "version": request.expectedVersion,
    "build": request.expectedBuild,
    "teamIdentifier": request.expectedTeamId,
    "sourceAppSignatureValid": true,
    "payloadAppSignatureValid": true,
    "payloadHelperSignatureValid": true,
    "packageSignatureValid": true,
    "appStapleValid": true,
    "packageStapleValid": true,
    "gatekeeperExecuteAccepted": true,
    "gatekeeperInstallAccepted": true,
    "notarizationSubmissionId": request.notarizationSubmissionId,
  };
}

Map<String, Object?> _failureEvidence(String failureClass) {
  return {
    "schemaVersion": 1,
    "status": "candidate-only",
    "failureClass": failureClass,
  };
}

Future<void> _writeEvidence(
  File evidence,
  Map<String, Object?> document,
) async {
  _validateEvidenceDocument(document);
  final existingType = await FileSystemEntity.type(
    evidence.path,
    followLinks: false,
  );
  if (existingType != FileSystemEntityType.notFound &&
      existingType != FileSystemEntityType.file) {
    throw const FileSystemException("evidence output node is invalid");
  }
  await evidence.parent.create(recursive: true);
  if (await FileSystemEntity.type(
        evidence.parent.path,
        followLinks: false,
      ) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException("evidence output parent is invalid");
  }
  final temporary = File(
    "${evidence.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}",
  );
  await temporary.create(exclusive: true);
  try {
    await temporary.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(document)}\n",
      flush: true,
    );
    await temporary.rename(evidence.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

const _forbiddenEvidenceKeys = <String>{
  "path",
  "command",
  "stdout",
  "stderr",
  "environment",
  "identityDisplayName",
  "keychainPath",
  "notaryProfile",
};

const _successEvidenceKeys = <String>{
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
};

const _failureEvidenceKeys = <String>{
  "schemaVersion",
  "status",
  "failureClass",
};

final _absolutePathPattern = RegExp(r"(^|[\s=])(?:/|[A-Za-z]:\\)");
final _credentialValuePattern = RegExp(
  r"Developer ID (?:Application|Installer)|Keychains?|notary[- ]profile|"
  r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|api[-_ ]?key",
  caseSensitive: false,
);
final _teamIdPattern = RegExp(r"^[A-Z0-9]{10}$");
final _versionPattern =
    RegExp(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$");
final _buildPattern = RegExp(r"^[0-9]+$");
final _identifierPattern = RegExp(r"^[A-Za-z0-9][A-Za-z0-9.-]*$");
final _gitCommitPattern = RegExp(r"^[0-9a-f]{40}$");
final _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");
final _uuidPattern = RegExp(
  r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
  r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
);
final _simpleFileNamePattern = RegExp(r"^[A-Za-z0-9._+-]+$");
final _failureClassPattern = RegExp(r"^[a-z0-9]+(?:-[a-z0-9]+)*$");

void _validateEvidenceDocument(Map<String, Object?> document) {
  final status = document["status"];
  final expectedKeys = switch (status) {
    "verified locally" => _successEvidenceKeys,
    "candidate-only" => _failureEvidenceKeys,
    _ => throw StateError("evidence has an invalid status"),
  };
  if (document.keys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(document.keys.toSet()).isNotEmpty ||
      document["schemaVersion"] != 1) {
    throw StateError("evidence has an invalid schema");
  }
  if (status == "verified locally") {
    if (!_gitCommitPattern.hasMatch(document["gitCommit"] as String? ?? "") ||
        !_sha256Pattern.hasMatch(
          document["artifactSHA256"] as String? ?? "",
        ) ||
        !_teamIdPattern.hasMatch(
          document["teamIdentifier"] as String? ?? "",
        ) ||
        !_uuidPattern.hasMatch(
          document["notarizationSubmissionId"] as String? ?? "",
        )) {
      throw StateError("evidence identifiers are invalid");
    }
    for (final key in _successEvidenceKeys.where(
      (key) => key.endsWith("Valid") || key.endsWith("Accepted"),
    )) {
      if (document[key] != true) {
        throw StateError("evidence trust boolean is not true");
      }
    }
  } else if (!_failureClassPattern.hasMatch(
    document["failureClass"] as String? ?? "",
  )) {
    throw StateError("evidence failure class is invalid");
  }

  void validate(Object? value, {String? key}) {
    if (key != null && _forbiddenEvidenceKeys.contains(key)) {
      throw StateError("evidence contains a forbidden field");
    }
    if (value is String &&
        (_absolutePathPattern.hasMatch(value) ||
            _credentialValuePattern.hasMatch(value))) {
      throw StateError("evidence contains a forbidden value");
    }
    if (value is Map<String, Object?>) {
      for (final entry in value.entries) {
        validate(entry.value, key: entry.key);
      }
    } else if (value is Iterable<Object?>) {
      for (final item in value) {
        validate(item);
      }
    }
  }

  validate(document);
  jsonEncode(document);
}

class _BundleMetadata {
  const _BundleMetadata({required this.executable});

  final String executable;
}

class _AuditFailure implements Exception {
  const _AuditFailure(this.failureClass);

  final String failureClass;
}
