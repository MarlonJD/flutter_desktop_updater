import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("agent harness entrypoints stay discoverable", () {
    final agents = File("AGENTS.md").readAsStringSync();
    final harness = File("docs/harness-engineering.md").readAsStringSync();
    final plansIndex = File("docs/exec-plans/index.md").readAsStringSync();

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
  });

  test("harness plan records stage boundaries and local commands", () {
    final plan = File(
      "docs/exec-plans/active/2026-07-01-agent-harness-engineering-plan.md",
    ).readAsStringSync();

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

    expect(Directory("docs/plans").existsSync(), isFalse);
    expect(Directory("docs/exec-plans/active").existsSync(), isTrue);
    expect(Directory("docs/exec-plans/completed").existsSync(), isTrue);
    expect(File("docs/exec-plans/tech-debt-tracker.md").existsSync(), isTrue);

    expect(index, contains("# Execution Plans"));
    expect(index, contains("## Active"));
    expect(index, contains("## Completed"));
    expect(
      index,
      contains("active/2026-07-01-agent-harness-engineering-plan.md"),
    );
    expect(index, isNot(contains("docs/plans")));

    expect(debtTracker, contains("# Tech Debt Tracker"));
    expect(debtTracker, contains("Harness"));
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

  test("harness avoids redundant prompt routers and oversized active plans",
      () {
    final activePlan = File(
      "docs/exec-plans/active/2026-07-01-agent-harness-engineering-plan.md",
    ).readAsStringSync();

    expect(File("docs/migration/agent-prompt.md").existsSync(), isFalse);
    expect(activePlan.split("\n"), hasLength(lessThanOrEqualTo(120)));
    expect(activePlan, isNot(contains("Non-Negotiable Constraints")));
    expect(activePlan, isNot(contains("REQUIRED SUB-SKILL")));
  });
}
