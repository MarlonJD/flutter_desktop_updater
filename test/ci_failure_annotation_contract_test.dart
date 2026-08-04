import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("secretless native build gates annotate sanitized log tails", () {
    final workflow = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    final bashSteps = <String, String>{
      "Run macOS install helper tests":
          "swift test --package-path macos/install_helper",
      "Run Linux unprivileged helper and crash recovery tests":
          "ctest --test-dir linux/native/build",
      "Build macOS example": "flutter build macos --debug",
    };

    for (final entry in bashSteps.entries) {
      final step = workflowStep(workflow, entry.key);
      expect(step, contains(entry.value), reason: entry.key);
      expect(step, contains("2>&1 | tee"), reason: entry.key);
      expect(step, contains(r"${PIPESTATUS[0]}"), reason: entry.key);
      expect(step, contains("tail -n 60"), reason: entry.key);
      expect(step, contains(r"LC_ALL=C tr -cd"), reason: entry.key);
      expect(step, contains("%25"), reason: entry.key);
      expect(step, contains("%0D"), reason: entry.key);
      expect(step, contains("%0A"), reason: entry.key);
      expect(step, contains("::error title="), reason: entry.key);
      expect(step, contains(r'exit "$status"'), reason: entry.key);
      expect(step, isNot(contains("continue-on-error")), reason: entry.key);
    }

    final windows = workflowStep(
      workflow,
      "Build standalone Windows native SDK tests",
    );
    expect(
      windows,
      contains("cmake --build windows/native/build --config Release"),
    );
    expect(windows, contains("Tee-Object"));
    expect(windows, contains(r"$LASTEXITCODE"));
    expect(windows, contains("Get-Content -LiteralPath"));
    expect(windows, contains("-Tail 60"));
    expect(windows, contains("%25"));
    expect(windows, contains("%0D"));
    expect(windows, contains("%0A"));
    expect(windows, contains("::error title="));
    expect(windows, contains(r"exit $buildExit"));
    expect(windows, isNot(contains("continue-on-error")));
  });
}

String workflowStep(String workflow, String name) {
  final start = workflow.indexOf("      - name: $name\n");
  expect(start, greaterThanOrEqualTo(0), reason: name);
  final next = workflow.indexOf("\n      - ", start + 1);
  return workflow.substring(start, next < 0 ? workflow.length : next);
}
