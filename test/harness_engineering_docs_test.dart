import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";

import "support/dart_cli.dart";

const harnessPlanPath =
    "docs/exec-plans/completed/2026-07-01-agent-harness-engineering-plan.md";
const harnessPlanLink =
    "completed/2026-07-01-agent-harness-engineering-plan.md";
const oldActiveHarnessPlanPath =
    "docs/exec-plans/active/2026-07-01-agent-harness-engineering-plan.md";

void main() {
  test("agent harness entrypoints stay discoverable", () {
    final agents = File("AGENTS.md").readAsStringSync();
    final architecture = File("ARCHITECTURE.md").readAsStringSync();
    final harness = File("docs/harness-engineering.md").readAsStringSync();
    final plansIndex = File("docs/exec-plans/index.md").readAsStringSync();
    final readme = File("README.md").readAsStringSync();

    expect(agents, contains("[architecture map](ARCHITECTURE.md)"));
    expect(
      agents,
      contains("[harness operating model](docs/harness-engineering.md)"),
    );
    expect(
      agents,
      contains("[execution-plan ledger](docs/exec-plans/index.md)"),
    );
    expect(agents, isNot(contains("docs/plans")));
    expect(agents, contains("flutter test --no-pub"));
    expect(agents, isNot(contains("OpenAI Harness Engineering")));

    expect(architecture, contains("# Architecture"));
    expect(architecture, contains("Dependency Direction"));
    expect(architecture, contains("Update Flow"));
    expect(harness, contains("# Harness Engineering For desktop_updater"));
    expect(harness, contains("Agent-Readable Repository Map"));
    expect(harness, contains("Mechanical Quality Gates"));
    expect(harness, contains("Agent Feedback Loops"));
    expect(harness, contains("test/harness_engineering_docs_test.dart"));
    expect(harness, isNot(contains("Staged Adoption Plan")));
    expect(harness, isNot(contains("docs/plans")));

    expect(
      plansIndex,
      contains("2026-07-01 - Agent harness engineering"),
    );
    expect(plansIndex, contains(harnessPlanLink));
    expect(readme, contains("AGENTS.md"));
    expect(readme, contains("docs/harness-engineering.md"));
    expect(readme, contains("docs/exec-plans/index.md"));
  });

  test("harness plan records stage boundaries and local commands", () {
    final plan = File(harnessPlanPath).readAsStringSync();

    expect(plan, contains("Stage 0"));
    expect(plan, contains("Stage 1"));
    expect(plan, contains("Stage 2"));
    expect(plan, contains("Stage 3"));
    expect(plan, contains("dart format --set-exit-if-changed"));
    expect(plan, contains("flutter analyze --no-fatal-infos"));
    expect(plan, contains("flutter test --no-pub"));
    expect(plan, contains("dart pub publish --dry-run"));
  });

  test("exec plan system follows harness layout", () {
    final index = File("docs/exec-plans/index.md").readAsStringSync();
    final debtTracker =
        File("docs/exec-plans/tech-debt-tracker.md").readAsStringSync();
    final activePlansDirectory = Directory("docs/exec-plans/active");

    expect(Directory("docs/plans").existsSync(), isFalse);
    if (activePlansDirectory.existsSync()) {
      for (final entity in activePlansDirectory.listSync()) {
        expect(entity, isA<File>());
        expect(entity.path, endsWith(".md"));
        final activePlanLink = "active/${entity.uri.pathSegments.last}";
        expect(index, contains(activePlanLink));
      }
    }
    expect(Directory("docs/exec-plans/completed").existsSync(), isTrue);
    expect(File("docs/exec-plans/tech-debt-tracker.md").existsSync(), isTrue);

    expect(index, contains("# Execution Plans"));
    expect(index, contains("## Active"));
    expect(index, contains("## Completed"));
    expect(index, contains(harnessPlanLink));
    expect(index, isNot(contains("active/2026-07-01")));
    expect(index, isNot(contains("docs/plans")));

    expect(debtTracker, contains("# Tech Debt Tracker"));
    expect(debtTracker, contains("Harness"));
    expect(
      debtTracker,
      isNot(contains("Add a local `tool/harness_check.dart` runner")),
    );
    expect(
      debtTracker,
      isNot(contains("Standardize evidence file names under `reports/`")),
    );
  });

  test("exec plan index links resolve", () {
    final index = File("docs/exec-plans/index.md").readAsStringSync();
    final links = RegExp(r"\]\(([^)]+\.md)\)")
        .allMatches(index)
        .map((match) => match.group(1)!)
        .where((link) => !link.startsWith("http"))
        .toList(growable: false);

    expect(links, isNotEmpty);

    for (final link in links) {
      expect(
        File("docs/exec-plans/$link").existsSync(),
        isTrue,
        reason: "docs/exec-plans/index.md links missing plan $link",
      );
    }
  });

  test("harness avoids redundant prompt routers and oversized plans", () {
    final completedPlan = File(harnessPlanPath).readAsStringSync();

    expect(File("docs/migration/agent-prompt.md").existsSync(), isFalse);
    expect(File(oldActiveHarnessPlanPath).existsSync(), isFalse);
    expect(Directory("agent-harness").existsSync(), isFalse);
    expect(Directory("docs/superpowers").existsSync(), isFalse);
    expect(
      File(
        "docs/design-docs/"
        "2026-07-11-cross-platform-privileged-install-helper-design.md",
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        "docs/exec-plans/active/"
        "2026-07-21-windows-linux-production-readiness.md",
      ).existsSync(),
      isTrue,
    );
    expect(completedPlan.split("\n"), hasLength(lessThanOrEqualTo(120)));
    expect(completedPlan, isNot(contains("Non-Negotiable Constraints")));
    expect(completedPlan, isNot(contains("REQUIRED SUB-SKILL")));
  });

  test("local harness runner records the validation ladder", () {
    final runner = File("tool/harness_check.dart");
    final gitignore = File(".gitignore").readAsStringSync();

    expect(
      runner.existsSync(),
      isTrue,
      reason: "Stage 2 requires a local secretless harness runner.",
    );

    final source = runner.readAsStringSync();
    const orderedCommands = [
      "dart run tool/harness_gate.dart --structural",
      "dart format --output=none --set-exit-if-changed .",
      "flutter analyze --no-fatal-infos --no-pub",
      "flutter test --no-pub test/harness_engineering_docs_test.dart",
      "flutter test --no-pub",
      "dart pub publish --dry-run",
    ];

    var previousIndex = -1;
    for (final command in orderedCommands) {
      final index = source.indexOf(command, previousIndex + 1);

      expect(index, isNot(-1), reason: "Missing harness command: $command");
      expect(
        index,
        greaterThan(previousIndex),
        reason: "Harness command is out of order: $command",
      );

      previousIndex = index;
    }

    expect(source, contains("reports/harness-check.md"));
    expect(source, contains("Exit code"));
    expect(source, isNot(contains("GITHUB_TOKEN")));
    expect(source, isNot(contains("API_KEY")));
    expect(source, isNot(contains("SECRET")));
    expect(source, isNot(contains("PASSWORD")));
    expect(gitignore, contains("reports/harness-check.md"));
  });

  test("adopted harness authorities and coverage remain complete", () {
    final config = jsonDecode(
      File(
        "docs/agent-harness/config.json",
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    final authorities = config["authorities"] as Map<String, dynamic>;
    const expectedAuthorities = {
      "instructions",
      "architecture",
      "planning",
      "registry",
      "environment",
      "verification",
      "coverage",
      "certification",
    };

    expect(config["schema_version"], 1);
    expect(authorities.keys.toSet(), expectedAuthorities);
    expect(authorities, isNot(contains("exec_plan_index")));

    for (final path in authorities.values.cast<String>()) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: "Configured harness authority must exist: $path",
      );
    }

    final coverage =
        File("docs/agent-harness/coverage-matrix.md").readAsStringSync();
    final statusRows = RegExp(
      r"^\| .+ \| .+ \| .+ \| (?:\[(?:verified|candidate|blocked|N/A)\]\([^)]+\)|(?:verified|candidate|blocked|N/A))(?:\s|$)",
      multiLine: true,
    ).allMatches(coverage);

    expect(
      statusRows,
      hasLength(31),
      reason: "The canonical harness inventory contains exactly 31 rows.",
    );
    expect(coverage, isNot(contains("TODO(harness)")));
    expect(coverage, isNot(contains("<replace-with")));

    final certification = jsonDecode(
      File(
        "docs/agent-harness/certification.json",
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    final coverageDigest = sha256
        .convert(utf8.encode(coverage.replaceAll("\r\n", "\n")))
        .toString();

    expect(certification["schema_version"], 2);
    expect(certification["claim"], "harness-ready");
    expect(certification["profile"], "adaptive");
    expect(certification["coverage_sha256"], coverageDigest);
    expect(
      certification["project_native_gate"]["command"],
      contains("tool/harness_gate.dart"),
    );
    expect(certification["maintenance"]["triggers"], ["manual"]);
  });

  test("project-native structural harness gate passes", () async {
    final result = await Process.run(
      resolveDartExecutable(),
      ["run", "tool/harness_gate.dart", "--structural"],
      runInShell: false,
    );

    expect(
      result.exitCode,
      0,
      reason: "${result.stdout}\n${result.stderr}",
    );
    expect(
      result.stdout.toString(),
      contains("31/31 canonical coverage rows declared"),
    );
  });

  test("harness docs describe runner and smoke evidence naming", () {
    final harness = File("docs/harness-engineering.md").readAsStringSync();
    final completedPlan = File(harnessPlanPath).readAsStringSync();

    expect(harness, contains("dart run tool/harness_check.dart"));
    expect(harness, contains("reports/harness-check.md"));
    expect(
      harness,
      contains("reports/<platform>-update-smoke-<mode>-diagnostics.jsonl"),
    );
    expect(harness, contains("manual release approval"));

    expect(completedPlan, contains("- [x] Add `tool/harness_check.dart`."));
    expect(
      completedPlan,
      contains("- [x] Have it run format, analyze, test, and publish dry-run"),
    );
    expect(
      completedPlan,
      contains("- [x] Write `reports/harness-check.md`"),
    );
    expect(
      completedPlan,
      contains("- [x] Standardize platform-smoke evidence under `reports/`."),
    );
    expect(
      completedPlan,
      contains("- [x] Document when platform smoke belongs to local work"),
    );
  });

  test("platform smoke diagnostics use mechanical reports paths", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    const diagnosticsPaths = [
      "reports/windows-v3-debug-run-1",
      "reports/windows-v3-debug-run-2",
      "reports/windows-v3-release-run-1",
      "reports/windows-v3-release-run-2",
      "reports/linux-update-smoke-debug-diagnostics.jsonl",
      "reports/linux-update-smoke-release-diagnostics.jsonl",
    ];

    for (final path in diagnosticsPaths) {
      expect(workflow, contains(path), reason: "Missing evidence path $path");
    }

    expect(workflow, isNot(contains("build/desktop-updater-helper-debug")));
    expect(workflow, isNot(contains("build/desktop-updater-helper-release")));
  });
}
