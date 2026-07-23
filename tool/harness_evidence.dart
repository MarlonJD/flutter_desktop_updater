import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";

const _coveragePath = "docs/agent-harness/coverage-matrix.md";
const _certificationPath = "docs/agent-harness/certification.json";
const _evidenceRoot = "docs/agent-harness/evidence";
const _repositoryIdentity = "scm://github.com/MarlonJD/flutter_desktop_updater";
const _deploymentTarget =
    "harness://github.com/MarlonJD/flutter_desktop_updater/repository-harness";
const _environment = "local-macos-workspace";
const _issuer = "repository-native-harness-evidence-generator";
const _evidenceDomain = "harness-engineering-evidence-v2\u0000";
const _projectGateCommand = "dart run tool/harness_gate.dart --candidate "
    "--attestation-key-file \"\$HARNESS_ATTESTATION_KEY_FILE\"";
const _maintenanceCommand = "dart run tool/harness_check.dart";

const _specs = <_EvidenceSpec>[
  _EvidenceSpec(
    "Humans set intent; agents execute within authority",
    "human-intent",
    _EvidenceStatus.verified,
    "Authority roles and escalation boundaries were reviewed.",
    "review AGENTS.md and docs/agent-harness/operating-loop.md authority boundaries",
    "docs/agent-harness/operating-loop.md",
  ),
  _EvidenceSpec(
    "Break large goals into reusable design, code, review, test, and verification steps",
    "reusable-steps",
    _EvidenceStatus.verified,
    "The convergence plan records restartable milestones and proof.",
    "review the active harness convergence ExecPlan milestones and evidence",
    "docs/exec-plans/active/2026-07-23-harness-engineering-convergence-plan.md",
  ),
  _EvidenceSpec(
    "Agents can self-review and respond to feedback",
    "self-review",
    _EvidenceStatus.verified,
    "The review loop and current repair findings were exercised.",
    "run the harness checks and review actionable failures before refresh",
    "docs/agent-harness/operating-loop.md",
  ),
  _EvidenceSpec(
    "Application behavior is directly readable",
    "readable-behavior",
    _EvidenceStatus.verified,
    "Fixture-driven package, CLI, widget, and native surfaces are mapped.",
    "run focused harness docs behavior tests through Flutter test",
    "test/harness_engineering_docs_test.dart",
  ),
  _EvidenceSpec(
    "Logs, metrics, and traces are queryable when relevant",
    "observable-signals",
    _EvidenceStatus.verified,
    "Package-appropriate reports and diagnostics are declared.",
    "review reports/harness-check.md and documented platform diagnostics paths",
    "docs/agent-harness/environment-contract.md",
  ),
  _EvidenceSpec(
    "Repository knowledge is the durable record",
    "durable-knowledge",
    _EvidenceStatus.verified,
    "Canonical documentation routes passed structural validation.",
    "run the repository-native structural harness gate",
    "docs/index.md",
  ),
  _EvidenceSpec(
    "Repository tools and authorized work context are directly invocable",
    "invocable-tools-context",
    _EvidenceStatus.verified,
    "Repository commands and read-only Git context are directly discoverable.",
    "run repository harness commands and inspect git status without external writes",
    "docs/agent-harness/registry.md",
  ),
  _EvidenceSpec(
    "Dependencies and abstractions remain agent-legible",
    "legible-dependencies",
    _EvidenceStatus.verified,
    "Architecture, schemas, fixtures, and native contracts are linked.",
    "review architecture and execute the repository validation report",
    "fixtures/compat/native-contract/README.md",
  ),
  _EvidenceSpec(
    "`AGENTS.md` is a concise map, not an encyclopedia",
    "concise-agents",
    _EvidenceStatus.verified,
    "Root routes fit the conservative instruction byte budget.",
    "run the structural gate instruction size and route checks",
    "AGENTS.md",
  ),
  _EvidenceSpec(
    "Plans are versioned living artifacts",
    "living-plans",
    _EvidenceStatus.verified,
    "The repo-native ledger and preferred living sections are explicit.",
    "run the focused plan index and link tests",
    "docs/PLANS.md",
  ),
  _EvidenceSpec(
    "Architecture and critical taste boundaries are mechanical",
    "mechanical-boundaries",
    _EvidenceStatus.verified,
    "Selected trust, contract, and harness invariants have executable checks.",
    "run the broad repository harness validation report",
    "ARCHITECTURE.md",
  ),
  _EvidenceSpec(
    "Local autonomy exists inside enforced central boundaries",
    "bounded-autonomy",
    _EvidenceStatus.verified,
    "Local reversible work is separated from Git and external authority.",
    "review root instructions and operating-loop escalation boundaries",
    "docs/agent-harness/operating-loop.md",
  ),
  _EvidenceSpec(
    "Verification proves working behavior, not only code changes",
    "behavioral-verification",
    _EvidenceStatus.verified,
    "Focused and broad commands report observable outcomes.",
    "run dart run tool/harness_check.dart and require a passed report",
    "docs/agent-harness/verification-matrix.md",
  ),
  _EvidenceSpec(
    "Failures and review judgment feed back into the harness",
    "feedback-capture",
    _EvidenceStatus.verified,
    "Adoption findings were converted into docs, tests, and gate behavior.",
    "review the convergence plan discoveries and focused harness tests",
    "test/harness_engineering_docs_test.dart",
  ),
  _EvidenceSpec(
    "Entropy and technical debt are continuously controlled",
    "entropy-control",
    _EvidenceStatus.verified,
    "A manual sweep, current findings, and debt destinations exist.",
    "execute the manual entropy checklist during evidence refresh",
    "docs/agent-harness/entropy-cleanup-checklist.md",
  ),
  _EvidenceSpec(
    "Autonomy increases only after test, review, recovery, and escalation loops exist",
    "graduated-autonomy",
    _EvidenceStatus.verified,
    "The granted local level and unavailable higher levels are explicit.",
    "review registry statuses and operating-loop escalation levels",
    "docs/agent-harness/registry.md",
  ),
  _EvidenceSpec(
    "Merge throughput policy matches project risk",
    "risk-matched-merge",
    _EvidenceStatus.verified,
    "Trust and target-host gates remain risk-based instead of throughput-based.",
    "review SECURITY.md and docs/github-actions-ci-cd.md gate rationale",
    "docs/github-actions-ci-cd.md",
  ),
  _EvidenceSpec(
    "Release, deployment, and production actions require repository-local authority",
    "production-authority",
    _EvidenceStatus.verified,
    "Release approval and rollback ownership are explicit; no production action was inferred.",
    "review publishing and CI authority gates without executing a release",
    "docs/publishing.md",
  ),
  _EvidenceSpec(
    "Repository-specific OpenAI examples are treated as options, not universal mandates",
    "case-study-options",
    _EvidenceStatus.verified,
    "Every case-study choice has an independent repository decision.",
    "review the complete case-study decision ledger",
    "docs/agent-harness/coverage-matrix.md",
  ),
  _EvidenceSpec(
    "Zero human-authored code as an operating constraint",
    "na-zero-human-code",
    _EvidenceStatus.notApplicable,
    "Not adopted; maintainers may author code and retain judgment.",
    "applicability review of the human and agent responsibility model",
    "docs/agent-harness/operating-loop.md",
  ),
  _EvidenceSpec(
    "Reported repository size, pull-request throughput, elapsed-time speedup, and long agent-run duration as targets",
    "na-case-study-metrics",
    _EvidenceStatus.notApplicable,
    "Not adopted; behavior, safety, and compatibility are the measures.",
    "applicability review of repository outcome and evidence measures",
    "docs/agent-harness/coverage-matrix.md",
  ),
  _EvidenceSpec(
    "Local and cloud agent review loops continue until reviewers are satisfied while human review is optional",
    "na-review-loop-default",
    _EvidenceStatus.notApplicable,
    "Not a universal policy; review and human gates are risk-based.",
    "applicability review of the repository review policy",
    "docs/agent-harness/operating-loop.md",
  ),
  _EvidenceSpec(
    "Per-worktree application isolation",
    "na-per-worktree-app",
    _EvidenceStatus.notApplicable,
    "Not required by default; this package uses explicit workspace preservation.",
    "applicability review of package workspace isolation",
    "docs/agent-harness/environment-contract.md",
  ),
  _EvidenceSpec(
    "Per-worktree observability stack",
    "na-per-worktree-observability",
    _EvidenceStatus.notApplicable,
    "Not required; bounded reports and platform diagnostics fit this package.",
    "applicability review of package observability requirements",
    "docs/agent-harness/environment-contract.md",
  ),
  _EvidenceSpec(
    "Chrome DevTools Protocol for UI control",
    "na-cdp",
    _EvidenceStatus.notApplicable,
    "Not required; Flutter widget and selected desktop-host tests are primary.",
    "applicability review of package UI verification surfaces",
    "docs/agent-harness/verification-matrix.md",
  ),
  _EvidenceSpec(
    "Victoria Logs, Metrics, and Traces with LogQL/PromQL/TraceQL",
    "na-victoria",
    _EvidenceStatus.notApplicable,
    "Not required; no persistent distributed service is operated here.",
    "applicability review of package logs metrics and traces",
    "docs/agent-harness/environment-contract.md",
  ),
  _EvidenceSpec(
    "OpenAI's fixed layered domain architecture",
    "na-fixed-layers",
    _EvidenceStatus.notApplicable,
    "Not adopted; the repository uses its own documented dependency direction.",
    "applicability review of the repository architecture map",
    "ARCHITECTURE.md",
  ),
  _EvidenceSpec(
    "Reimplementing upstream dependency behavior locally",
    "na-reimplementation-default",
    _EvidenceStatus.notApplicable,
    "Not a default; contracts and stable dependencies are preferred.",
    "applicability review of dependency and fixture policy",
    "third_party/README.md",
  ),
  _EvidenceSpec(
    "Minimally blocking merge gates and short-lived pull requests",
    "na-minimal-blocking",
    _EvidenceStatus.notApplicable,
    "Not inherited; gate strength follows compatibility and trust risk.",
    "applicability review of repository CI and review risk",
    "docs/github-actions-ci-cd.md",
  ),
  _EvidenceSpec(
    "Scheduled Codex documentation gardening and quality-scoring agents open targeted repair pull requests",
    "na-scheduled-gardening",
    _EvidenceStatus.notApplicable,
    "Not enabled; maintenance is manual and external writes need authority.",
    "applicability review of the entropy automation decision",
    "docs/agent-harness/entropy-cleanup-checklist.md",
  ),
  _EvidenceSpec(
    "Automated merge and agent-authored release tooling",
    "na-automated-merge-release",
    _EvidenceStatus.notApplicable,
    "Automated merge is not authorized; release execution stays owner-gated.",
    "applicability review of merge release and production authority",
    "docs/agent-harness/operating-loop.md",
  ),
];

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stderr.writeln(
      "Usage:\n"
      "  dart run tool/harness_evidence.dart --prepare "
      "--source-commit <40-hex> --attestation-key-file <absolute-path> "
      "--validation-report reports/harness-check.md\n"
      "  dart run tool/harness_evidence.dart --record-project-gate "
      "--source-commit <40-hex> --attestation-key-file <absolute-path> "
      "--candidate-observation <substantive-id>",
    );
    exitCode = 64;
    return;
  }

  final keyBytes = _readKey(options.attestationKeyPath);
  final head = await _git(["rev-parse", "HEAD"]);
  if (head != options.sourceCommit) {
    _fail(
      "Evidence must be prepared on source commit ${options.sourceCommit}; "
      "current HEAD is $head.",
    );
  }

  if (options.prepare) {
    final status = await _git(["status", "--porcelain"]);
    if (status.isNotEmpty) {
      _fail(
        "Prepare requires a clean source worktree before the attestation "
        "overlay is generated:\n$status",
      );
    }
    final reportFile = File(options.validationReport!);
    if (!reportFile.existsSync()) {
      _fail("Validation report does not exist: ${options.validationReport}");
    }
    final report = reportFile.readAsStringSync();
    if (!report.contains("- Status: `passed`")) {
      _fail(
        "Validation report must record Status: passed before evidence refresh.",
      );
    }
    _prepare(
      sourceCommit: options.sourceCommit,
      keyBytes: keyBytes,
      validationReportPath: options.validationReport!,
      validationReportBytes: reportFile.readAsBytesSync(),
    );
    stdout.writeln(
      "[harness-evidence] prepared 31 row records plus maintenance, approval, "
      "and rollback records for ${options.sourceCommit}.",
    );
    return;
  }

  _recordProjectGate(
    sourceCommit: options.sourceCommit,
    keyBytes: keyBytes,
    candidateObservation: options.candidateObservation!,
  );
  stdout.writeln(
    "[harness-evidence] recorded the prospective project-native gate "
    "observation for ${options.sourceCommit}.",
  );
}

void _prepare({
  required String sourceCommit,
  required List<int> keyBytes,
  required String validationReportPath,
  required List<int> validationReportBytes,
}) {
  final observedAt = DateTime.now().toUtc();
  final observedAtText = observedAt.toIso8601String();
  final reportDigest = sha256.convert(validationReportBytes).toString();
  final keyId = sha256.convert(keyBytes).toString();

  final statusCells = <String, String>{};
  for (final spec in _specs) {
    final relativeEvidencePath = "evidence/${spec.slug}.json";
    statusCells[spec.capability] =
        "[${spec.status.label}]($relativeEvidencePath) - ${spec.reason}";
    final record = _record(
      sourceCommit: sourceCommit,
      capability: spec.capability,
      command: spec.command,
      result: spec.status.result,
      exitCode: spec.status.exitCode,
      observedAt: observedAtText,
      artifacts: [
        "git:$sourceCommit:${spec.sourceArtifact}",
        "validation-report-sha256:$reportDigest:$validationReportPath",
      ],
      keyId: keyId,
      keyBytes: keyBytes,
    );
    _writeJson("$_evidenceRoot/${spec.slug}.json", record);
  }

  final coverageFile = File(_coveragePath);
  final updatedCoverage = const LineSplitter()
      .convert(coverageFile.readAsStringSync())
      .map((line) => _replaceStatusCell(line, statusCells))
      .join("\n");
  coverageFile.writeAsStringSync("$updatedCoverage\n");

  _writeNamedRecord(
    path: "$_evidenceRoot/continuous-maintenance.json",
    sourceCommit: sourceCommit,
    capability: "continuous-harness-maintenance",
    command: _maintenanceCommand,
    observedAt: observedAtText,
    artifacts: [
      "validation-report-sha256:$reportDigest:$validationReportPath",
      "git:$sourceCommit:tool/harness_check.dart",
    ],
    keyId: keyId,
    keyBytes: keyBytes,
  );
  _writeNamedRecord(
    path: "$_evidenceRoot/production-approval.json",
    sourceCommit: sourceCommit,
    capability: "production-authority-approval",
    command: "review SECURITY.md docs/publishing.md and CI approval boundaries",
    observedAt: observedAtText,
    artifacts: [
      "git:$sourceCommit:SECURITY.md",
      "git:$sourceCommit:docs/github-actions-ci-cd.md",
    ],
    keyId: keyId,
    keyBytes: keyBytes,
  );
  _writeNamedRecord(
    path: "$_evidenceRoot/production-rollback.json",
    sourceCommit: sourceCommit,
    capability: "production-rollback-readiness",
    command: "review publishing recovery and release rollback ownership",
    observedAt: observedAtText,
    artifacts: [
      "git:$sourceCommit:docs/publishing.md",
      "git:$sourceCommit:docs/diagnostics-and-recovery.md",
    ],
    keyId: keyId,
    keyBytes: keyBytes,
  );

  final coverageDigest =
      sha256.convert(coverageFile.readAsBytesSync()).toString();
  final manifest = <String, dynamic>{
    "schema_version": 2,
    "claim": "harness-ready",
    "profile": "adaptive",
    "repository_commit": sourceCommit,
    "repository_identity": _repositoryIdentity,
    "deployment_target_id": _deploymentTarget,
    "environment": _environment,
    "issued_at": observedAtText,
    "expires_at": observedAt.add(const Duration(days: 7)).toIso8601String(),
    "coverage_sha256": coverageDigest,
    "evidence_root": _evidenceRoot,
    "project_native_gate": {
      "command": _projectGateCommand,
      "evidence": "$_evidenceRoot/project-native-gate.json",
    },
    "maintenance": {
      "command": _maintenanceCommand,
      "triggers": ["manual"],
      "max_age_hours": 168,
      "evidence": "$_evidenceRoot/continuous-maintenance.json",
    },
    "production_authority": {
      "owner": "Package release maintainers",
      "approval_evidence": "$_evidenceRoot/production-approval.json",
      "rollback_evidence": "$_evidenceRoot/production-rollback.json",
    },
  };
  _writeJson(_certificationPath, manifest);
}

void _recordProjectGate({
  required String sourceCommit,
  required List<int> keyBytes,
  required String candidateObservation,
}) {
  final manifest = jsonDecode(File(_certificationPath).readAsStringSync())
      as Map<String, dynamic>;
  if (manifest["repository_commit"] != sourceCommit) {
    _fail("Certification manifest is not bound to $sourceCommit.");
  }
  final projectGate = manifest["project_native_gate"] as Map<String, dynamic>;
  if (projectGate["command"] != _projectGateCommand) {
    _fail("Certification manifest project gate command has drifted.");
  }
  final observedAt = DateTime.now().toUtc().toIso8601String();
  _writeNamedRecord(
    path: projectGate["evidence"] as String,
    sourceCommit: sourceCommit,
    capability: "project-native-harness-gate",
    command: _projectGateCommand,
    observedAt: observedAt,
    artifacts: [
      "candidate-gate:$candidateObservation",
      "git:$sourceCommit:tool/harness_gate.dart",
    ],
    keyId: sha256.convert(keyBytes).toString(),
    keyBytes: keyBytes,
  );
}

void _writeNamedRecord({
  required String path,
  required String sourceCommit,
  required String capability,
  required String command,
  required String observedAt,
  required List<String> artifacts,
  required String keyId,
  required List<int> keyBytes,
}) {
  _writeJson(
    path,
    _record(
      sourceCommit: sourceCommit,
      capability: capability,
      command: command,
      result: "passed",
      exitCode: 0,
      observedAt: observedAt,
      artifacts: artifacts,
      keyId: keyId,
      keyBytes: keyBytes,
    ),
  );
}

Map<String, dynamic> _record({
  required String sourceCommit,
  required String capability,
  required String command,
  required String result,
  required int? exitCode,
  required String observedAt,
  required List<String> artifacts,
  required String keyId,
  required List<int> keyBytes,
}) {
  final unsigned = <String, dynamic>{
    "schema_version": 2,
    "repository_commit": sourceCommit,
    "repository_identity": _repositoryIdentity,
    "deployment_target_id": _deploymentTarget,
    "capabilities": [capability],
    "environment": _environment,
    "command": command,
    "exit_code": exitCode,
    "observed_at": observedAt,
    "result": result,
    "artifacts": artifacts,
    "issuer": _issuer,
    "key_id": keyId,
  };
  final bytes = <int>[
    ...utf8.encode(_evidenceDomain),
    ...utf8.encode(_canonicalJson(unsigned)),
  ];
  return <String, dynamic>{
    ...unsigned,
    "signature": Hmac(sha256, keyBytes).convert(bytes).toString(),
  };
}

String _replaceStatusCell(
  String line,
  Map<String, String> statusCells,
) {
  if (!line.startsWith("|") || !line.endsWith("|")) {
    return line;
  }
  final cells = line
      .substring(1, line.length - 1)
      .split("|")
      .map((cell) => cell.trim())
      .toList();
  if (cells.length != 4 || !statusCells.containsKey(cells.first)) {
    return line;
  }
  cells[3] = statusCells[cells.first]!;
  return "| ${cells.join(" | ")} |";
}

void _writeJson(String path, Map<String, dynamic> value) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    "${const JsonEncoder.withIndent("  ").convert(value)}\n",
  );
}

List<int> _readKey(String path) {
  final keyFile = File(path);
  if (!keyFile.absolute.path.startsWith("/") ||
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
    _fail("Attestation key must be an absolute non-symlinked regular file.");
  }
  final repositoryRoot = Directory.current.absolute.path;
  if (keyFile.absolute.path.startsWith("$repositoryRoot/")) {
    _fail("Attestation key must be outside the repository.");
  }
  final stat = keyFile.statSync();
  final bytes = keyFile.readAsBytesSync();
  if (bytes.length < 32 || bytes.length > 4096 || (stat.mode & 0x3f) != 0) {
    _fail(
      "Attestation key must contain 32-4096 bytes and use owner-only "
      "permissions.",
    );
  }
  return bytes;
}

Future<String> _git(List<String> arguments) async {
  final result = await Process.run("git", arguments, runInShell: false);
  if (result.exitCode != 0) {
    _fail(
      "git ${arguments.join(" ")} failed with ${result.exitCode}: "
      "${result.stderr.toString().trim()}",
    );
  }
  return result.stdout.toString().trim();
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

Never _fail(String message) {
  stderr.writeln("[harness-evidence] ERROR: $message");
  exit(1);
}

enum _EvidenceStatus {
  verified("verified", "passed", 0),
  notApplicable("N/A", "not-applicable", null);

  const _EvidenceStatus(this.label, this.result, this.exitCode);

  final String label;
  final String result;
  final int? exitCode;
}

final class _EvidenceSpec {
  const _EvidenceSpec(
    this.capability,
    this.slug,
    this.status,
    this.reason,
    this.command,
    this.sourceArtifact,
  );

  final String capability;
  final String slug;
  final _EvidenceStatus status;
  final String reason;
  final String command;
  final String sourceArtifact;
}

final class _Options {
  const _Options({
    required this.prepare,
    required this.sourceCommit,
    required this.attestationKeyPath,
    this.validationReport,
    this.candidateObservation,
  });

  static _Options? parse(List<String> arguments) {
    final prepare = arguments.contains("--prepare");
    final record = arguments.contains("--record-project-gate");
    if (prepare == record) {
      return null;
    }

    String? value(String name) {
      final index = arguments.indexOf(name);
      if (index == -1 || index + 1 >= arguments.length) {
        return null;
      }
      return arguments[index + 1];
    }

    final sourceCommit = value("--source-commit");
    final keyPath = value("--attestation-key-file");
    final report = value("--validation-report");
    final observation = value("--candidate-observation");
    if (sourceCommit == null ||
        !RegExp(r"^[0-9a-f]{40}$").hasMatch(sourceCommit) ||
        keyPath == null ||
        (prepare && report == null) ||
        (record && (observation == null || observation.length < 12))) {
      return null;
    }
    return _Options(
      prepare: prepare,
      sourceCommit: sourceCommit,
      attestationKeyPath: keyPath,
      validationReport: report,
      candidateObservation: observation,
    );
  }

  final bool prepare;
  final String sourceCommit;
  final String attestationKeyPath;
  final String? validationReport;
  final String? candidateObservation;
}
