import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";

const _configPath = "docs/agent-harness/config.json";
const _coveragePath = "docs/agent-harness/coverage-matrix.md";
const _certificationPath = "docs/agent-harness/certification.json";
const _evidenceDomain = "harness-engineering-evidence-v2\u0000";

const _canonicalCapabilities = <String>[
  "Humans set intent; agents execute within authority",
  "Break large goals into reusable design, code, review, test, and verification steps",
  "Agents can self-review and respond to feedback",
  "Application behavior is directly readable",
  "Logs, metrics, and traces are queryable when relevant",
  "Repository knowledge is the durable record",
  "Repository tools and authorized work context are directly invocable",
  "Dependencies and abstractions remain agent-legible",
  "`AGENTS.md` is a concise map, not an encyclopedia",
  "Plans are versioned living artifacts",
  "Architecture and critical taste boundaries are mechanical",
  "Local autonomy exists inside enforced central boundaries",
  "Verification proves working behavior, not only code changes",
  "Failures and review judgment feed back into the harness",
  "Entropy and technical debt are continuously controlled",
  "Autonomy increases only after test, review, recovery, and escalation loops exist",
  "Merge throughput policy matches project risk",
  "Release, deployment, and production actions require repository-local authority",
  "Repository-specific OpenAI examples are treated as options, not universal mandates",
  "Zero human-authored code as an operating constraint",
  "Reported repository size, pull-request throughput, elapsed-time speedup, and long agent-run duration as targets",
  "Local and cloud agent review loops continue until reviewers are satisfied while human review is optional",
  "Per-worktree application isolation",
  "Per-worktree observability stack",
  "Chrome DevTools Protocol for UI control",
  "Victoria Logs, Metrics, and Traces with LogQL/PromQL/TraceQL",
  "OpenAI's fixed layered domain architecture",
  "Reimplementing upstream dependency behavior locally",
  "Minimally blocking merge gates and short-lived pull requests",
  "Scheduled Codex documentation gardening and quality-scoring agents open targeted repair pull requests",
  "Automated merge and agent-authored release tooling",
];

const _requiredPaths = <String>[
  "AGENTS.md",
  "ARCHITECTURE.md",
  "docs/index.md",
  "docs/PLANS.md",
  "docs/harness-engineering.md",
  "docs/agent-harness/index.md",
  _configPath,
  "docs/agent-harness/registry.md",
  "docs/agent-harness/operating-loop.md",
  "docs/agent-harness/environment-contract.md",
  "docs/agent-harness/output-contract.md",
  "docs/agent-harness/verification-matrix.md",
  "docs/agent-harness/entropy-cleanup-checklist.md",
  _coveragePath,
  "docs/agent-harness/certification.md",
  _certificationPath,
  "docs/agent-harness/evidence",
  "docs/exec-plans/index.md",
  "docs/exec-plans/tech-debt-tracker.md",
  "tool/harness_check.dart",
  "tool/harness_evidence.dart",
  "test/harness_engineering_docs_test.dart",
];

const _authorityKeys = <String>{
  "instructions",
  "architecture",
  "planning",
  "registry",
  "environment",
  "verification",
  "coverage",
  "certification",
};

const _certificationKeys = <String>{
  "schema_version",
  "claim",
  "profile",
  "repository_commit",
  "repository_identity",
  "deployment_target_id",
  "environment",
  "issued_at",
  "expires_at",
  "coverage_sha256",
  "evidence_root",
  "project_native_gate",
  "maintenance",
  "production_authority",
};

const _evidenceKeys = <String>{
  "schema_version",
  "repository_commit",
  "repository_identity",
  "deployment_target_id",
  "capabilities",
  "environment",
  "command",
  "exit_code",
  "observed_at",
  "result",
  "artifacts",
  "issuer",
  "key_id",
  "signature",
};

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == "--structural") {
    final failures = _structuralFailures();
    _finishStructural(failures);
    return;
  }

  if (arguments.length == 2 && arguments.first == "--attestation-key-file") {
    final failures = _structuralFailures();
    if (failures.isEmpty) {
      failures.addAll(
        await _certificationFailures(
          attestationKeyPath: arguments[1],
          prospective: false,
        ),
      );
    }
    _finishCertification(failures);
    return;
  }

  if (arguments.length == 3 &&
      arguments.first == "--candidate" &&
      arguments[1] == "--attestation-key-file") {
    final failures = _structuralFailures();
    if (failures.isEmpty) {
      failures.addAll(
        await _certificationFailures(
          attestationKeyPath: arguments[2],
          prospective: true,
        ),
      );
    }
    _finishCandidate(failures);
    return;
  }

  stderr.writeln(
    "Usage: dart run tool/harness_gate.dart --structural\n"
    "   or: dart run tool/harness_gate.dart --candidate "
    "--attestation-key-file <absolute-owner-only-key>\n"
    "   or: dart run tool/harness_gate.dart "
    "--attestation-key-file <absolute-owner-only-key>",
  );
  exitCode = 64;
}

List<String> _structuralFailures() {
  final failures = <String>[];

  for (final path in _requiredPaths) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    final expectedDirectory = path == "docs/agent-harness/evidence";
    final exists = expectedDirectory
        ? type == FileSystemEntityType.directory
        : type == FileSystemEntityType.file;
    if (!exists) {
      failures.add(
        "$path is missing or is not a regular "
        "${expectedDirectory ? "directory" : "file"}. "
        "Restore the declared harness authority and rerun --structural.",
      );
    }
  }

  if (failures.isNotEmpty) {
    return failures;
  }

  final config = _readJsonObject(_configPath, failures);
  if (config != null) {
    if (config["schema_version"] != 1) {
      failures.add("$_configPath must use schema_version 1.");
    }
    final authorities = config["authorities"];
    if (authorities is! Map<String, dynamic>) {
      failures.add("$_configPath authorities must be a JSON object.");
    } else {
      final keys = authorities.keys.toSet();
      if (!_sameSet(keys, _authorityKeys)) {
        failures.add(
          "$_configPath must declare exactly ${_authorityKeys.join(", ")}. "
          "The legacy ExecPlan ledger intentionally remains repo-native and "
          "must not add exec_plan_index without a planned migration.",
        );
      }
      for (final entry in authorities.entries) {
        final value = entry.value;
        if (value is! String ||
            value.isEmpty ||
            FileSystemEntity.typeSync(value, followLinks: false) !=
                FileSystemEntityType.file) {
          failures.add(
            "$_configPath authority ${entry.key} must resolve to a regular "
            "repository file; found ${jsonEncode(value)}.",
          );
        }
      }
    }
  }

  final agents = File("AGENTS.md").readAsBytesSync();
  if (agents.length > 32 * 1024) {
    failures.add(
      "AGENTS.md is ${agents.length} bytes, above the conservative 32 KiB "
      "instruction budget. Move detail into linked authorities.",
    );
  }
  final agentsText = utf8.decode(agents);
  for (final route in const [
    "ARCHITECTURE.md",
    "docs/index.md",
    "docs/harness-engineering.md",
    "docs/agent-harness/index.md",
    "docs/exec-plans/index.md",
  ]) {
    if (!agentsText.contains(route)) {
      failures.add("AGENTS.md must route to $route before the byte cutoff.");
    }
  }

  final markerPaths = <String>[
    "docs/index.md",
    "docs/PLANS.md",
    "docs/harness-engineering.md",
    ...Directory("docs/agent-harness")
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) => file.path)
        .where((path) => path.endsWith(".md")),
  ];
  for (final path in markerPaths) {
    final text = File(path).readAsStringSync();
    for (final marker in const [
      "TODO(harness)",
      "<replace-with",
      "<!-- TODO",
    ]) {
      if (text.contains(marker)) {
        failures.add(
          "$path contains scaffold marker $marker. Replace it with "
          "repository-specific facts.",
        );
      }
    }
  }

  final coverageText = File(_coveragePath).readAsStringSync();
  final rows = _coverageRows(coverageText, failures);
  final identities = rows.map((row) => row.identity).toList();
  final missing = _canonicalCapabilities
      .where((capability) => !identities.contains(capability))
      .toList();
  final extra = identities
      .where((capability) => !_canonicalCapabilities.contains(capability))
      .toList();
  if (rows.length != _canonicalCapabilities.length ||
      missing.isNotEmpty ||
      extra.isNotEmpty ||
      identities.toSet().length != identities.length) {
    failures.add(
      "$_coveragePath must contain each of the 31 canonical rows exactly "
      "once. Missing: ${missing.isEmpty ? "none" : missing.join("; ")}. "
      "Extra or duplicate: ${extra.isEmpty ? "none" : extra.join("; ")}.",
    );
  }
  for (final row in rows) {
    if (_coverageStatus(row.statusCell) == null) {
      failures.add(
        "$_coveragePath row '${row.identity}' must use verified, candidate, "
        "blocked, or N/A with a reason.",
      );
    }
  }

  final manifest = _readJsonObject(_certificationPath, failures);
  if (manifest != null) {
    if (!_sameSet(manifest.keys.toSet(), _certificationKeys)) {
      failures.add(
        "$_certificationPath must contain exactly the v2 manifest fields.",
      );
    }
    if (manifest["schema_version"] != 2 ||
        manifest["claim"] != "harness-ready" ||
        manifest["profile"] != "adaptive") {
      failures.add(
        "$_certificationPath must use schema_version 2, claim harness-ready, "
        "and profile adaptive.",
      );
    }
    final source = manifest["repository_commit"];
    if (source is! String || !RegExp(r"^[0-9a-f]{40}$").hasMatch(source)) {
      failures.add(
        "$_certificationPath repository_commit must be a full lowercase Git "
        "object ID.",
      );
    }
    for (final key in const [
      "repository_identity",
      "deployment_target_id",
      "environment",
    ]) {
      final value = manifest[key];
      if (value is! String || value.length < 8) {
        failures.add("$_certificationPath $key must be concrete.");
      }
    }
    final issuedAt = _parseUtc(manifest["issued_at"]);
    final expiresAt = _parseUtc(manifest["expires_at"]);
    if (issuedAt == null ||
        expiresAt == null ||
        expiresAt.isBefore(issuedAt) ||
        expiresAt.difference(issuedAt) > const Duration(hours: 168)) {
      failures.add(
        "$_certificationPath must declare a valid UTC evidence window of at "
        "most 168 hours.",
      );
    }
    final actualCoverageDigest =
        sha256.convert(File(_coveragePath).readAsBytesSync()).toString();
    if (manifest["coverage_sha256"] != actualCoverageDigest) {
      failures.add(
        "$_certificationPath coverage_sha256 does not match $_coveragePath. "
        "Refresh the digest after the final coverage edit.",
      );
    }
    final evidenceRoot = manifest["evidence_root"];
    if (evidenceRoot is! String ||
        FileSystemEntity.typeSync(evidenceRoot, followLinks: false) !=
            FileSystemEntityType.directory) {
      failures.add(
        "$_certificationPath evidence_root must resolve to a regular "
        "repository directory.",
      );
    }
    final projectGate = manifest["project_native_gate"];
    if (projectGate is! Map<String, dynamic> ||
        !_sameSet(projectGate.keys.toSet(), {"command", "evidence"}) ||
        projectGate["command"] is! String ||
        !(projectGate["command"] as String)
            .contains("tool/harness_gate.dart") ||
        projectGate["evidence"] is! String) {
      failures.add(
        "$_certificationPath project_native_gate must name the repository "
        "Dart gate and its evidence record.",
      );
    }
    final maintenance = manifest["maintenance"];
    if (maintenance is! Map<String, dynamic> ||
        !_sameSet(maintenance.keys.toSet(), {
          "command",
          "triggers",
          "max_age_hours",
          "evidence",
        }) ||
        maintenance["command"] is! String ||
        maintenance["triggers"] is! List ||
        jsonEncode(maintenance["triggers"]) != jsonEncode(["manual"]) ||
        maintenance["max_age_hours"] is! int ||
        (maintenance["max_age_hours"] as int) > 168 ||
        maintenance["evidence"] is! String) {
      failures.add(
        "$_certificationPath maintenance must declare the manual "
        "repository-native gate with max_age_hours <= 168.",
      );
    }
    final production = manifest["production_authority"];
    if (production is! Map<String, dynamic> ||
        !_sameSet(production.keys.toSet(), {
          "owner",
          "approval_evidence",
          "rollback_evidence",
        })) {
      failures.add(
        "$_certificationPath production_authority must retain its exact v2 "
        "shape even when certification remains incomplete.",
      );
    }
  }

  return failures;
}

Future<List<String>> _certificationFailures({
  required String attestationKeyPath,
  required bool prospective,
}) async {
  final failures = <String>[];
  final coverageText = File(_coveragePath).readAsStringSync();
  final rows = _coverageRows(coverageText, failures);
  final manifest =
      _readJsonObject(_certificationPath, failures) ?? <String, dynamic>{};

  final keyFile = File(attestationKeyPath);
  if (!_isAbsolute(attestationKeyPath)) {
    failures.add("Attestation key path must be absolute.");
  }
  if (FileSystemEntity.typeSync(attestationKeyPath, followLinks: false) !=
      FileSystemEntityType.file) {
    failures.add(
      "Attestation key must be a non-symlinked regular file outside the "
      "repository.",
    );
  }
  final root = Directory.current.absolute.path;
  if (_isWithin(root, keyFile.absolute.path)) {
    failures.add("Attestation key must be outside the repository.");
  }

  var keyBytes = const <int>[];
  if (failures.isEmpty) {
    final stat = keyFile.statSync();
    keyBytes = keyFile.readAsBytesSync();
    if (keyBytes.length < 32 || keyBytes.length > 4096) {
      failures.add("Attestation key must contain 32–4096 raw bytes.");
    }
    if ((stat.mode & 0x3f) != 0) {
      failures.add(
        "Attestation key must not be accessible to group or world. "
        "Use owner-only permissions such as 0600.",
      );
    }
  }

  final source = manifest["repository_commit"];
  final repositoryIdentity = manifest["repository_identity"];
  final deploymentTarget = manifest["deployment_target_id"];
  final environment = manifest["environment"];
  final issuedAt = _parseUtc(manifest["issued_at"]);
  final expiresAt = _parseUtc(manifest["expires_at"]);
  final maintenance = manifest["maintenance"];
  final maxAgeHours =
      maintenance is Map<String, dynamic> ? maintenance["max_age_hours"] : null;
  final evidenceRoot = manifest["evidence_root"];
  final keyId = keyBytes.isEmpty ? "" : sha256.convert(keyBytes).toString();
  final linkedEvidence = <String>{};

  for (final row in rows) {
    final status = _coverageStatus(row.statusCell);
    if (status != "verified" && status != "N/A") {
      failures.add(
        "Coverage row '${row.identity}' is $status. Full certification "
        "requires verified or justified N/A with fresh evidence.",
      );
      continue;
    }
    final links = _jsonLinks(row.statusCell);
    if (links.length != 1) {
      failures.add(
        "Coverage row '${row.identity}' must link exactly one evidence JSON "
        "from its status cell.",
      );
      continue;
    }
    final evidencePath = _resolveCoverageLink(links.single);
    linkedEvidence.add(evidencePath);
    _verifyEvidence(
      path: evidencePath,
      expectedCapability: row.identity,
      expectedResult: status == "verified" ? "passed" : "not-applicable",
      expectedSource: source,
      expectedRepositoryIdentity: repositoryIdentity,
      expectedDeploymentTarget: deploymentTarget,
      expectedEnvironment: environment,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxAgeHours: maxAgeHours,
      keyId: keyId,
      keyBytes: keyBytes,
      failures: failures,
    );
  }

  final projectGate = manifest["project_native_gate"];
  final projectGateEvidence =
      projectGate is Map<String, dynamic> ? projectGate["evidence"] : null;
  final maintenanceEvidence =
      maintenance is Map<String, dynamic> ? maintenance["evidence"] : null;
  final namedEvidence = <({Object? path, String capability})>[
    (
      path: projectGateEvidence,
      capability: "project-native-harness-gate",
    ),
    (
      path: maintenanceEvidence,
      capability: "continuous-harness-maintenance",
    ),
  ];
  for (final named in namedEvidence) {
    if (prospective && named.capability == "project-native-harness-gate") {
      continue;
    }
    if (named.path is! String) {
      failures.add(
        "$_certificationPath is missing the ${named.capability} evidence path.",
      );
      continue;
    }
    linkedEvidence.add(named.path as String);
    _verifyEvidence(
      path: named.path as String,
      expectedCapability: named.capability,
      expectedResult: "passed",
      expectedSource: source,
      expectedRepositoryIdentity: repositoryIdentity,
      expectedDeploymentTarget: deploymentTarget,
      expectedEnvironment: environment,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxAgeHours: maxAgeHours,
      keyId: keyId,
      keyBytes: keyBytes,
      failures: failures,
    );
  }

  final productionRow = rows
      .where(
        (row) =>
            row.identity ==
            "Release, deployment, and production actions require "
                "repository-local authority",
      )
      .firstOrNull;
  final productionStatus =
      productionRow == null ? null : _coverageStatus(productionRow.statusCell);
  final production = manifest["production_authority"];
  if (productionStatus == "verified") {
    if (production is! Map<String, dynamic> ||
        production["owner"] is! String ||
        (production["owner"] as String).trim().length < 3) {
      failures.add(
        "$_certificationPath must name a substantive production authority "
        "owner when the canonical row is verified.",
      );
    } else {
      for (final named in [
        (
          path: production["approval_evidence"],
          capability: "production-authority-approval",
        ),
        (
          path: production["rollback_evidence"],
          capability: "production-rollback-readiness",
        ),
      ]) {
        if (named.path is! String) {
          failures.add(
            "$_certificationPath must name ${named.capability} evidence.",
          );
          continue;
        }
        linkedEvidence.add(named.path as String);
        _verifyEvidence(
          path: named.path as String,
          expectedCapability: named.capability,
          expectedResult: "passed",
          expectedSource: source,
          expectedRepositoryIdentity: repositoryIdentity,
          expectedDeploymentTarget: deploymentTarget,
          expectedEnvironment: environment,
          issuedAt: issuedAt,
          expiresAt: expiresAt,
          maxAgeHours: maxAgeHours,
          keyId: keyId,
          keyBytes: keyBytes,
          failures: failures,
        );
      }
    }
  } else if (productionStatus == "N/A") {
    if (production is! Map<String, dynamic> ||
        production.values.any((value) => value != null)) {
      failures.add(
        "$_certificationPath production_authority fields must all be null "
        "when the canonical row is N/A.",
      );
    }
  }

  final gitRoot = await _git(["rev-parse", "--show-toplevel"], failures);
  final head = await _git(["rev-parse", "HEAD"], failures);
  if (gitRoot != null &&
      Directory(gitRoot).absolute.path != Directory.current.absolute.path) {
    failures.add(
      "Run the certification gate from the Git worktree root; found $gitRoot.",
    );
  }

  if (prospective) {
    if (head != source) {
      failures.add(
        "Candidate evidence must be prepared directly on source commit "
        "$source; current HEAD is $head.",
      );
    }
    final status = await _git(
      ["status", "--porcelain", "--untracked-files=all"],
      failures,
    );
    if (status != null) {
      final changed = _workingTreePaths(status, failures);
      final expected = <String>{
        _certificationPath,
        _coveragePath,
        ...linkedEvidence,
      };
      if (!_sameSet(changed, expected)) {
        final unexpected = changed.difference(expected);
        final missing = expected.difference(changed);
        failures.add(
          "Candidate attestation working tree must contain exactly coverage, "
          "certification, row evidence, maintenance, approval, and rollback "
          "records. Unexpected: "
          "${unexpected.isEmpty ? "none" : unexpected.join(", ")}. Missing: "
          "${missing.isEmpty ? "none" : missing.join(", ")}.",
        );
      }
    }
  } else {
    final parentLine =
        await _git(["rev-list", "--parents", "-n", "1", "HEAD"], failures);
    final status = await _git(["status", "--porcelain"], failures);
    if (status != null && status.isNotEmpty) {
      failures.add(
        "Certification requires a clean attestation HEAD. Preserve or resolve "
        "the listed working-tree changes before retrying:\n$status",
      );
    }
    if (parentLine != null) {
      final parts = parentLine.split(RegExp(r"\s+"));
      if (parts.length != 2 || parts[1] != source) {
        failures.add(
          "Current HEAD must be the direct single-parent child of source "
          "commit $source; found $parentLine.",
        );
      }
    }

    if (head != null && source is String) {
      final diff = await _git(
        ["diff", "--name-only", "$source..$head"],
        failures,
      );
      if (diff != null) {
        final changed =
            diff.split("\n").where((line) => line.isNotEmpty).toSet();
        final allowed = <String>{
          _certificationPath,
          _coveragePath,
          ...linkedEvidence,
        };
        if (!_sameSet(changed, allowed)) {
          final unexpected = changed.difference(allowed);
          final missing = allowed.difference(changed);
          failures.add(
            "Attestation overlay must change exactly certification, coverage, "
            "and referenced evidence files. Unexpected: "
            "${unexpected.isEmpty ? "none" : unexpected.join(", ")}. Missing: "
            "${missing.isEmpty ? "none" : missing.join(", ")}.",
          );
        }
      }
    }
  }

  if (evidenceRoot is String) {
    for (final path in linkedEvidence) {
      if (!_isWithin(
        Directory(evidenceRoot).absolute.path,
        File(path).absolute.path,
      )) {
        failures.add("$path must stay beneath evidence_root $evidenceRoot.");
      }
    }
  }

  return failures;
}

Set<String> _workingTreePaths(
  String porcelain,
  List<String> failures,
) {
  final paths = <String>{};
  for (final line in const LineSplitter().convert(porcelain)) {
    final String path;
    if (line.startsWith("?? ") && line.length > 3) {
      path = line.substring(3);
    } else if (line.length > 3 && line[2] == " ") {
      path = line.substring(3);
    } else if (line.length > 2 && line[1] == " ") {
      // `_git` trims the complete stdout string, so the leading workspace
      // status space on the first porcelain line may be absent.
      path = line.substring(2);
    } else {
      failures.add("Cannot parse Git status line: $line");
      continue;
    }
    if (path.startsWith("\"") || path.contains(" -> ")) {
      failures.add(
        "Candidate attestation paths must not be quoted or renamed: $line",
      );
      continue;
    }
    paths.add(path);
  }
  return paths;
}

void _verifyEvidence({
  required String path,
  required String expectedCapability,
  required String expectedResult,
  required Object? expectedSource,
  required Object? expectedRepositoryIdentity,
  required Object? expectedDeploymentTarget,
  required Object? expectedEnvironment,
  required DateTime? issuedAt,
  required DateTime? expiresAt,
  required Object? maxAgeHours,
  required String keyId,
  required List<int> keyBytes,
  required List<String> failures,
}) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    failures.add("$path must be a regular non-symlinked evidence JSON file.");
    return;
  }
  final evidence = _readJsonObject(path, failures);
  if (evidence == null) {
    return;
  }
  if (!_sameSet(evidence.keys.toSet(), _evidenceKeys)) {
    failures.add("$path must contain exactly the harness-evidence v2 fields.");
  }
  if (evidence["schema_version"] != 2 ||
      evidence["repository_commit"] != expectedSource ||
      evidence["repository_identity"] != expectedRepositoryIdentity ||
      evidence["deployment_target_id"] != expectedDeploymentTarget ||
      evidence["environment"] != expectedEnvironment) {
    failures.add(
      "$path does not match the manifest schema, source, identities, or "
      "environment.",
    );
  }
  final capabilities = evidence["capabilities"];
  if (capabilities is! List ||
      capabilities.isEmpty ||
      !capabilities.contains(expectedCapability)) {
    failures.add("$path must name capability '$expectedCapability'.");
  }
  if (evidence["result"] != expectedResult) {
    failures.add("$path result must be $expectedResult.");
  }
  if (expectedResult == "passed" && evidence["exit_code"] != 0) {
    failures.add("$path passed evidence must use exit_code 0.");
  }
  if (expectedResult == "not-applicable" && evidence["exit_code"] != null) {
    failures.add("$path N/A evidence must use a null exit_code.");
  }
  for (final key in const ["command", "issuer"]) {
    final value = evidence[key];
    if (value is! String || value.trim().length < 3) {
      failures.add("$path $key must be substantive.");
    }
  }
  final artifacts = evidence["artifacts"];
  if (artifacts is! List ||
      artifacts.isEmpty ||
      artifacts.any((item) => item is! String || item.trim().isEmpty)) {
    failures.add("$path artifacts must contain substantive identifiers.");
  }
  final observedAt = _parseUtc(evidence["observed_at"]);
  final now = DateTime.now().toUtc();
  if (observedAt == null ||
      observedAt.isAfter(now.add(const Duration(minutes: 5))) ||
      (maxAgeHours is int &&
          now.difference(observedAt) > Duration(hours: maxAgeHours)) ||
      (issuedAt != null && observedAt.isAfter(issuedAt)) ||
      (expiresAt != null && observedAt.isAfter(expiresAt))) {
    failures.add(
      "$path observed_at must be current, not later than manifest issuance, "
      "and within the declared freshness window.",
    );
  }
  if (evidence["key_id"] != keyId) {
    failures.add("$path key_id does not match the supplied key.");
  }
  final unsigned = Map<String, dynamic>.from(evidence)..remove("signature");
  if (!_allStringsAscii(unsigned)) {
    failures.add(
      "$path uses non-ASCII evidence text; the native canonicalizer requires "
      "ASCII evidence identifiers for cross-platform determinism.",
    );
  } else if (keyBytes.isNotEmpty) {
    final bytes = <int>[
      ...utf8.encode(_evidenceDomain),
      ...utf8.encode(_canonicalJson(unsigned)),
    ];
    final expectedSignature = Hmac(sha256, keyBytes).convert(bytes).toString();
    if (evidence["signature"] != expectedSignature) {
      failures.add("$path signature is not HMAC-consistent.");
    }
  }
}

List<_CoverageRow> _coverageRows(
  String text,
  List<String> failures,
) {
  final rows = <_CoverageRow>[];
  for (final line in const LineSplitter().convert(text)) {
    if (!line.startsWith("|") || !line.endsWith("|")) {
      continue;
    }
    final cells = line
        .substring(1, line.length - 1)
        .split("|")
        .map((cell) => cell.trim())
        .toList();
    if (cells.length != 4) {
      continue;
    }
    if (_canonicalCapabilities.contains(cells.first)) {
      rows.add(_CoverageRow(cells.first, cells.last));
    }
  }
  if (rows.isEmpty) {
    failures.add("$_coveragePath has no parseable canonical coverage rows.");
  }
  return rows;
}

String? _coverageStatus(String cell) {
  for (final status in const ["verified", "candidate", "blocked", "N/A"]) {
    if (cell.contains(status)) {
      return status;
    }
  }
  return null;
}

List<String> _jsonLinks(String cell) {
  return RegExp(r"\[[^\]]+\]\(([^)]+\.json)\)")
      .allMatches(cell)
      .map((match) => match.group(1)!)
      .toList();
}

String _resolveCoverageLink(String link) {
  final segments = <String>["docs", "agent-harness"];
  for (final segment in link.split("/")) {
    if (segment.isEmpty || segment == ".") {
      continue;
    }
    if (segment == "..") {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }
  return segments.join("/");
}

Map<String, dynamic>? _readJsonObject(
  String path,
  List<String> failures,
) {
  try {
    final value = jsonDecode(File(path).readAsStringSync());
    if (value is Map<String, dynamic>) {
      return value;
    }
    failures.add("$path must contain a JSON object.");
  } on Object catch (error) {
    failures.add("$path is not valid JSON: $error");
  }
  return null;
}

DateTime? _parseUtc(Object? value) {
  if (value is! String || !value.endsWith("Z")) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

String _canonicalJson(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return "{${keys.map((key) {
      return "${_asciiJsonString(key)}:${_canonicalJson(value[key])}";
    }).join(",")}}";
  }
  if (value is List) {
    return "[${value.map(_canonicalJson).join(",")}]";
  }
  if (value is String) {
    return _asciiJsonString(value);
  }
  return jsonEncode(value);
}

String _asciiJsonString(String value) {
  final encoded = jsonEncode(value);
  final buffer = StringBuffer();
  for (final rune in encoded.runes) {
    if (rune <= 0x7f) {
      buffer.writeCharCode(rune);
    } else if (rune <= 0xffff) {
      buffer.write("\\u${rune.toRadixString(16).padLeft(4, "0")}");
    } else {
      final adjusted = rune - 0x10000;
      final high = 0xd800 + (adjusted >> 10);
      final low = 0xdc00 + (adjusted & 0x3ff);
      buffer
        ..write("\\u${high.toRadixString(16)}")
        ..write("\\u${low.toRadixString(16)}");
    }
  }
  return buffer.toString();
}

bool _allStringsAscii(Object? value) {
  if (value is String) {
    return value.runes.every((rune) => rune <= 0x7f);
  }
  if (value is List) {
    return value.every(_allStringsAscii);
  }
  if (value is Map) {
    return value.entries.every(
      (entry) =>
          _allStringsAscii(entry.key.toString()) &&
          _allStringsAscii(entry.value),
    );
  }
  return true;
}

Future<String?> _git(
  List<String> arguments,
  List<String> failures,
) async {
  final result = await Process.run("git", arguments, runInShell: false);
  if (result.exitCode != 0) {
    failures.add(
      "git ${arguments.join(" ")} failed with ${result.exitCode}: "
      "${result.stderr.toString().trim()}",
    );
    return null;
  }
  return result.stdout.toString().trim();
}

bool _sameSet(Set<Object?> left, Set<Object?> right) {
  return left.length == right.length &&
      left.containsAll(right) &&
      right.containsAll(left);
}

bool _isAbsolute(String path) {
  return path.startsWith("/") || RegExp(r"^[A-Za-z]:[\\/]").hasMatch(path);
}

bool _isWithin(String parent, String child) {
  final normalizedParent = parent.endsWith(Platform.pathSeparator)
      ? parent
      : "$parent${Platform.pathSeparator}";
  return child == parent || child.startsWith(normalizedParent);
}

Never _fail(List<String> failures) {
  for (final failure in failures) {
    stderr.writeln("[harness-gate] ERROR: $failure");
  }
  exitCode = 1;
  throw const _GateExit();
}

void _finishStructural(List<String> failures) {
  if (failures.isNotEmpty) {
    try {
      _fail(failures);
    } on _GateExit {
      return;
    }
  }
  stdout.writeln(
    "[harness-gate] structural validation passed "
    "(31/31 canonical coverage rows declared; certification may remain "
    "incomplete).",
  );
}

void _finishCertification(List<String> failures) {
  if (failures.isNotEmpty) {
    try {
      _fail(failures);
    } on _GateExit {
      return;
    }
  }
  stdout.writeln(
    "[harness-gate] certification validation passed for the current clean "
    "source/direct-child attestation pair.",
  );
}

void _finishCandidate(List<String> failures) {
  if (failures.isNotEmpty) {
    try {
      _fail(failures);
    } on _GateExit {
      return;
    }
  }
  stdout.writeln(
    "[harness-gate] candidate attestation validation passed; record this "
    "observation, create the direct-child attestation commit, then run the "
    "full gate.",
  );
}

final class _CoverageRow {
  const _CoverageRow(this.identity, this.statusCell);

  final String identity;
  final String statusCell;
}

final class _GateExit implements Exception {
  const _GateExit();
}
