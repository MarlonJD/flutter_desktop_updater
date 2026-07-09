import "dart:io";

import "package:flutter_test/flutter_test.dart";

const harnessPlanPath =
    "docs/exec-plans/completed/2026-07-01-agent-harness-engineering-plan.md";
const harnessPlanLink =
    "completed/2026-07-01-agent-harness-engineering-plan.md";
const oldActiveHarnessPlanPath =
    "docs/exec-plans/active/2026-07-01-agent-harness-engineering-plan.md";

void main() {
  test("agent harness entrypoints stay discoverable", () {
    final agents = File("AGENTS.md").readAsStringSync();
    final harness = File("docs/harness-engineering.md").readAsStringSync();
    final plansIndex = File("docs/exec-plans/index.md").readAsStringSync();
    final readme = File("README.md").readAsStringSync();

    expect(agents, contains("docs/harness-engineering.md"));
    expect(agents, contains("docs/exec-plans/index.md"));
    expect(agents, isNot(contains("docs/plans")));
    expect(agents, contains("flutter test --no-pub"));
    expect(agents, isNot(contains("OpenAI Harness Engineering")));

    expect(harness, contains("# Harness Engineering For desktop_updater"));
    expect(harness, contains("Agent-Readable Repository Map"));
    expect(harness, contains("Mechanical Quality Gates"));
    expect(harness, contains("Staged Adoption Plan"));
    expect(harness, contains("test/harness_engineering_docs_test.dart"));
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
      "dart format --set-exit-if-changed .",
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
      "reports/windows-update-smoke-debug-diagnostics.jsonl",
      "reports/windows-update-smoke-release-diagnostics.jsonl",
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
