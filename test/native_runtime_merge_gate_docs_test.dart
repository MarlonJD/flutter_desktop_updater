import "dart:io";

import "package:flutter_test/flutter_test.dart";

const _ledgerHeading = "## Current-Head Merge-Gate Ledger";

const _expectedLedger = <String, String>{
  "Portable contract, trust, provenance, lifecycle, redirect, and package-layout suites":
      "verified locally",
  "Task 10 complete local ladder": "verified locally",
  "macOS root SwiftPM tests": "verified locally",
  "macOS exact CocoaPods 10.14 five-source typecheck": "verified locally",
  "macOS external SwiftPM consumer": "verified locally",
  "Flutter macOS SwiftPM build and integration": "verified in CI",
  "Flutter macOS CocoaPods build and integration": "verified in CI",
  "macOS normal ZIP smoke": "verified in CI",
  "Windows Unicode and relative redirect CTest": "verified in CI",
  "Windows provenance, lifecycle, and C ABI CTest": "verified in CI",
  "Windows source-contract target and reparse validation": "verified locally",
  "Windows junction/reparse transaction mutation and recovery": "blocked",
  "Windows Release NuGet isolated P/Invoke consumer": "verified in CI",
  "Windows normal ZIP smoke": "verified in CI",
  "Linux native tamper CTest": "verified in CI",
  "Linux installed CMake consumer": "verified in CI",
  "Linux standard and multiarch pkg-config consumers": "verified in CI",
  "Linux mount/bind transaction mutation and recovery": "blocked",
  "Cross-platform/macOS packaged signed helper ownership transfer, cross-process target lock, durable journal, and crash recovery":
      "blocked",
  "Linux normal ZIP smoke": "verified in CI",
  "Current remediation head in GitHub Actions": "verified in CI",
  "macOS signed/notarized DMG smoke": "not run",
  "macOS signed/notarized PKG smoke": "not run",
  "Windows signed Inno smoke": "not run",
};

const _workflowCommands = <String, Map<String, List<String>>>{
  "dart": <String, List<String>>{
    "Check generated native contract fixtures": <String>[
      "dart run tool/generate_native_contract_fixtures.dart --check",
    ],
    "Check formatting": <String>["dart format --set-exit-if-changed ."],
    "Analyze": <String>["flutter analyze --no-fatal-infos"],
    "Test Dart surface": <String>["flutter test --no-pub"],
    "Pub publish dry-run": <String>["dart pub publish --dry-run"],
  },
  "macos-native": <String, List<String>>{
    "Typecheck macOS 10.14 CocoaPods fallback source set": <String>[
      "xcrun swiftc -typecheck",
    ],
    "Run DesktopUpdaterKit SwiftPM tests": <String>[
      "swift test --package-path .",
    ],
    "Run external SwiftPM consumer": <String>[
      "swift run --package-path example/native/macos",
    ],
    "macOS native runtime ZIP smoke": <String>[
      "dart run tool/native_runtime_smoke_server.dart",
    ],
  },
  "macos-flutter": <String, List<String>>{
    "Enable SwiftPM integration": <String>[
      "flutter config --enable-swift-package-manager",
    ],
    "Enable CocoaPods fallback integration": <String>[
      "flutter config --no-enable-swift-package-manager",
    ],
    "Build macOS example": <String>["flutter build macos --debug"],
    "Run macOS integration tests": <String>[
      "flutter test integration_test -d macos",
    ],
  },
  "windows": <String, List<String>>{
    "Configure standalone Windows native SDK tests": <String>[
      "cmake -S windows/native",
    ],
    "Pack DesktopUpdater.Native": <String>[
      "dotnet pack windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj",
    ],
    "Run isolated Release NuGet P/Invoke consumer": <String>[
      "& tool/verify_windows_nuget_consumer.ps1",
    ],
  },
  "linux": <String, List<String>>{
    "Configure standalone Linux native tests": <String>[
      "cmake -S linux/native",
    ],
    "Build and run installed Linux pkg-config consumer": <String>["c++"],
    "Configure Linux multiarch pkg-config package": <String>[
      "cmake -S linux/native",
    ],
    "Linux native runtime ZIP smoke": <String>[
      "cmake -S example/native/linux-cmake-runtime",
      "dart run tool/native_runtime_smoke_server.dart",
    ],
  },
};

void main() {
  test("publishes exactly one atomic current-head ledger", () {
    final docs = <String, String>{
      for (final path in _mergeGateDocs) path: _read(path),
    };

    expect(_ledgerErrors(docs), isEmpty);
    expect(docs["docs/native-runtime-api.md"], contains("candidate-only"));
  });

  test("current-head ledger records fresh local evidence literally", () {
    final ledger = _read("docs/native-runtime-api.md");
    expect(ledger, contains("658 passes"));
    expect(ledger, contains("3 explicit skips"));
    expect(ledger, contains("0 warnings"));
    expect(ledger, contains("1 hint"));
    expect(ledger, contains("52 tests"));
    expect(ledger, contains("29290035977"));
    expect(ledger, contains("swift run --package-path example/native/macos"));
  });

  test("execution plan records the final verification and review verdict", () {
    final plan = _read(
      "docs/exec-plans/active/"
      "2026-07-10-native-runtime-merge-blocker-remediation-plan.md",
    );

    for (final phrase in <String>[
      "### Final verification and fresh adversarial review on 2026-07-13",
      "superpowers:verification-before-completion",
      "killcritic-complete-review",
      "No additional P0 or P1",
      "0 warnings and 1 hint",
      "29290035977",
      "BLOCK / NO-GO",
      "PR #65: not merge-ready",
    ]) {
      expect(plan, contains(phrase), reason: phrase);
    }
  });

  test("native runtime docs enumerate both metadata signature requirements",
      () {
    final runtimeApi = _read("docs/native-runtime-api.md");
    expect(runtimeApi, contains("- `requireIndexSignature`"));
    expect(runtimeApi, contains("- `requireDescriptorSignature`"));
  });

  test("released Flutter facades document pinned metadata trust", () {
    for (final path in <String>[
      "README.md",
      "docs/publishing.md",
      "docs/migration/1.x-to-2.0.md",
    ]) {
      final text = _read(path);
      expect(text, contains("trustedReleasePublicKeys"), reason: path);
      expect(text.toLowerCase(), contains("compatibility"), reason: path);
    }
    expect(
      _read("lib/updater_controller.dart"),
      contains("trustedReleasePublicKeys"),
    );
    expect(
      _read("lib/desktop_updater.dart"),
      contains("trustedReleasePublicKeys"),
    );
  });

  test("ledger validator rejects duplicate, stale, deleted, and swapped rows",
      () {
    final valid = <String, String>{
      "docs/native-runtime-api.md": _ledgerFixture(_expectedLedger),
      "README.md": "candidate-only",
    };
    expect(_ledgerErrors(valid), isEmpty);
    expect(
      _ledgerErrors(<String, String>{
        ...valid,
        "README.md": _ledgerFixture(_expectedLedger),
      }),
      contains("expected one ledger heading"),
    );
    final ledger = valid["docs/native-runtime-api.md"]!;
    expect(
      _ledgerErrors(<String, String>{
        ...valid,
        "docs/native-runtime-api.md": ledger.replaceFirst(
          "| macOS root SwiftPM tests | verified locally |",
          "",
        ),
      }),
      contains("missing row: macOS root SwiftPM tests"),
    );
    expect(
      _ledgerErrors(<String, String>{
        ...valid,
        "docs/native-runtime-api.md": ledger.replaceFirst(
          "| macOS root SwiftPM tests | verified locally |",
          "| stale combined macOS lane | verified locally |",
        ),
      }),
      contains("unexpected row: stale combined macOS lane"),
    );
    expect(
      _ledgerErrors(<String, String>{
        ...valid,
        "docs/native-runtime-api.md": ledger
            .replaceFirst(
              "| macOS root SwiftPM tests | verified locally |",
              "| macOS root SwiftPM tests | not run |",
            )
            .replaceFirst(
              "| Flutter macOS SwiftPM build and integration | verified in CI |",
              "| Flutter macOS SwiftPM build and integration | not run |",
            ),
      }),
      contains("wrong status: macOS root SwiftPM tests"),
    );
  });

  test("workflow runs merge-gate commands in their owning jobs", () {
    final workflow = _read(".github/workflows/desktop-updater-ci.yml");

    expect(_workflowErrors(workflow, _workflowCommands), isEmpty);
    expect(
      RegExp("No tests were found").allMatches(workflow).length,
      greaterThanOrEqualTo(9),
    );
  });

  test("workflow validator rejects false-green step and command mutations", () {
    const valid = """
jobs:
  dart:
    steps:
      - name: Test Dart surface
        run: |
          set -e
          flutter test --no-pub
""";
    const expected = <String, Map<String, List<String>>>{
      "dart": <String, List<String>>{
        "Test Dart surface": <String>["flutter test --no-pub"],
      },
    };

    expect(_workflowErrors(valid, expected), isEmpty);
    for (final mutation in <String>[
      valid.replaceFirst(
        "flutter test --no-pub",
        "echo flutter test --no-pub",
      ),
      valid.replaceFirst(
        "flutter test --no-pub",
        'message="flutter test --no-pub"',
      ),
      valid.replaceFirst(
        "flutter test --no-pub",
        "echo active # flutter test --no-pub",
      ),
      valid.replaceFirst(
        "flutter test --no-pub",
        "flutter test --no-pub || true",
      ),
    ]) {
      expect(
        _workflowErrors(mutation, expected),
        contains(
          "dart/Test Dart surface missing active command: "
          "flutter test --no-pub",
        ),
      );
    }
    expect(
      _workflowErrors(
        valid.replaceFirst("run: |", "if: false\n        run: |"),
        expected,
      ),
      contains("dart/Test Dart surface is disabled"),
    );
    expect(
      _workflowErrors(
        valid.replaceFirst(
          "run: |",
          "continue-on-error: true\n        run: |",
        ),
        expected,
      ),
      contains("dart/Test Dart surface continues on error"),
    );
  });

  test("credential-gated artifact pass claims are rejected in all merge docs",
      () {
    final docs = _mergeGateDocs.map(_read).join("\n");

    expect(_credentialPassClaims(docs), isEmpty);
    expect(
      _credentialPassClaims("""
Signed DMG passed; the PKG smoke is not run.
The PKG smoke succeeded. Inno lane successful. DMG gate green.
"""),
      hasLength(4),
    );
    expect(
      _credentialPassClaims(
        "Credential-gated DMG and Inno lanes are not run; "
        "the PKG smoke is blocked but successful.",
      ),
      hasLength(1),
    );
    expect(
      _credentialPassClaims(
        "DMG passed, while PKG was not run. "
        "DMG passed and Inno is not run.",
      ),
      hasLength(2),
    );
    expect(
      _credentialPassClaims(
        "RED, verified locally: signed DMG negative fixture passed.",
      ),
      isEmpty,
    );
    expect(
      _credentialPassClaims(
        "Linux standard and multiarch pkg-config consumers verified in CI.",
      ),
      isEmpty,
    );
  });

  test("preserves integration floors and blocked recovery truth", () {
    final guide = _read("docs/native-sdk.md");
    final runtimeApi = _read("docs/native-runtime-api.md");
    final diagnostics = _read("docs/diagnostics-and-recovery.md");
    final parent = _read(
      "docs/exec-plans/active/2026-07-05-full-native-runtime-preview-plan.md",
    );
    final remediation = _read(
      "docs/exec-plans/active/"
      "2026-07-10-native-runtime-merge-blocker-remediation-plan.md",
    );
    final combined = "$guide\n$runtimeApi\n$diagnostics".toLowerCase();

    for (final phrase in <String>[
      "swiftpm macos 10.15",
      "import desktopupdaterkit",
      "cocoapods macos 10.14",
      "signed app-archive authority",
      "owned stage provenance",
      "explicit install target proof",
      "one-shot handoff",
      "native transaction recovery journal",
    ]) {
      expect(combined, contains(phrase), reason: phrase);
    }
    expect(combined, contains("blocked"));
    expect(parent, contains("2026-07-10-native-runtime-merge-blocker"));
    expect(remediation, contains("Corrected PR #65 body draft (not posted)"));
  });
}

const _mergeGateDocs = <String>[
  "README.md",
  "docs/native-sdk.md",
  "docs/native-runtime-api.md",
  "docs/github-actions-ci-cd.md",
  "docs/diagnostics-and-recovery.md",
  "docs/migration/1.x-to-2.0.md",
  "docs/exec-plans/active/2026-07-05-full-native-runtime-preview-plan.md",
  "docs/exec-plans/active/"
      "2026-07-10-native-runtime-merge-blocker-remediation-plan.md",
];

List<String> _ledgerErrors(Map<String, String> docs) {
  final heading = RegExp(
    "^${RegExp.escape(_ledgerHeading)}\\s*\$",
    multiLine: true,
  );
  final owners = <String>[
    for (final entry in docs.entries)
      for (var index = 0;
          index < heading.allMatches(entry.value).length;
          index++)
        entry.key,
  ];
  if (owners.length != 1) return <String>["expected one ledger heading"];

  final markdown = docs[owners.single]!;
  final afterHeading = markdown.split(_ledgerHeading).last.trimLeft();
  final tableLines = afterHeading
      .split("\n")
      .skipWhile((line) => !line.trimLeft().startsWith("|"))
      .takeWhile((line) => line.trimLeft().startsWith("|"))
      .skip(2);
  final rows = <String, String>{};
  final errors = <String>[];
  for (final line in tableLines) {
    final cells = line
        .split("|")
        .skip(1)
        .take(2)
        .map((cell) => cell.replaceAll("`", "").trim())
        .toList();
    if (cells.length != 2) continue;
    if (rows.containsKey(cells[0])) errors.add("duplicate row: ${cells[0]}");
    rows[cells[0]] = cells[1];
  }
  for (final entry in _expectedLedger.entries) {
    if (!rows.containsKey(entry.key)) {
      errors.add("missing row: ${entry.key}");
    } else if (rows[entry.key] != entry.value) {
      errors.add("wrong status: ${entry.key}");
    }
  }
  for (final lane in rows.keys) {
    if (!_expectedLedger.containsKey(lane)) errors.add("unexpected row: $lane");
  }
  return errors;
}

String _ledgerFixture(Map<String, String> rows) => """
$_ledgerHeading

| Lane | Status |
| --- | --- |
${rows.entries.map((entry) => "| ${entry.key} | ${entry.value} |").join("\n")}
""";

List<String> _workflowErrors(
  String yaml,
  Map<String, Map<String, List<String>>> expected,
) {
  final steps = _workflowSteps(yaml);
  final errors = <String>[];
  for (final job in expected.entries) {
    for (final expectedStep in job.value.entries) {
      final label = "${job.key}/${expectedStep.key}";
      final step = steps[job.key]?[expectedStep.key];
      if (step == null) {
        errors.add("$label missing step");
        continue;
      }
      if (_literalBoolean(step.ifCondition) == false) {
        errors.add("$label is disabled");
      }
      if (_literalBoolean(step.continueOnError) ?? false) {
        errors.add("$label continues on error");
      }
      for (final command in expectedStep.value) {
        if (!step.runLines.any((line) => _startsCommand(line, command))) {
          errors.add("$label missing active command: $command");
        }
      }
    }
  }
  return errors;
}

Map<String, Map<String, _WorkflowStep>> _workflowSteps(String yaml) {
  final output = <String, Map<String, _WorkflowStep>>{};
  String? job;
  _WorkflowStep? step;
  var runIndent = -1;
  for (final line in yaml.split("\n")) {
    final indent = line.length - line.trimLeft().length;
    final trimmed = line.trim();
    final jobMatch =
        indent == 2 ? RegExp(r"^([A-Za-z0-9_-]+):$").firstMatch(trimmed) : null;
    if (jobMatch != null) {
      job = jobMatch.group(1);
      output.putIfAbsent(job!, () => <String, _WorkflowStep>{});
      step = null;
      runIndent = -1;
      continue;
    }
    if (job == null) continue;
    if (runIndent >= 0) {
      if (trimmed.isNotEmpty && indent <= runIndent) runIndent = -1;
      if (runIndent >= 0 && !trimmed.startsWith("#")) {
        final active = _stripComment(trimmed).trim();
        if (active.isNotEmpty) step!.runLines.add(active);
      }
    }
    final stepMatch =
        indent == 6 ? RegExp(r"^- name:\s*(.+)$").firstMatch(trimmed) : null;
    if (stepMatch != null) {
      final name = stepMatch.group(1)!.trim();
      step = _WorkflowStep(name);
      output[job]![name] = step;
      runIndent = -1;
      continue;
    }
    if (step == null || trimmed.startsWith("#")) continue;
    if (indent == 8 && trimmed.startsWith("if:")) {
      step.ifCondition = trimmed.substring(3).trim();
      continue;
    }
    if (indent == 8 && trimmed.startsWith("continue-on-error:")) {
      step.continueOnError =
          trimmed.substring("continue-on-error:".length).trim();
      continue;
    }
    final runMatch = RegExp(r"^run:\s*(.*)$").firstMatch(trimmed);
    if (indent != 8 || runMatch == null) continue;
    final value = runMatch.group(1)!;
    if (value == "|" || value == ">") {
      runIndent = indent;
    } else {
      final active = _stripComment(value).trim();
      if (active.isNotEmpty) step.runLines.add(active);
    }
  }
  return output;
}

bool _startsCommand(String line, String command) {
  final starts = line == command ||
      line.startsWith("$command ") ||
      line.startsWith("$command\\");
  if (!starts) return false;
  final suffix = line.substring(command.length);
  return !RegExp(
    r"\|\||;\s*(?:true|exit\s+0)\b|\|\s*(?:out-null|tee-object)\b",
    caseSensitive: false,
  ).hasMatch(suffix);
}

bool? _literalBoolean(String? value) {
  if (value == null) return null;
  final normalized = value
      .replaceAll(r"${{", "")
      .replaceAll("}}", "")
      .replaceAll(RegExp(r'''["'\s]'''), "")
      .toLowerCase();
  if (normalized == "true") return true;
  if (normalized == "false") return false;
  return null;
}

String _stripComment(String line) {
  var singleQuoted = false;
  var doubleQuoted = false;
  for (var index = 0; index < line.length; index++) {
    final character = line[index];
    if (character == "'" && !doubleQuoted) singleQuoted = !singleQuoted;
    if (character == '"' && !singleQuoted) doubleQuoted = !doubleQuoted;
    if (character == "#" &&
        !singleQuoted &&
        !doubleQuoted &&
        (index == 0 || RegExp(r"\s").hasMatch(line[index - 1]))) {
      return line.substring(0, index);
    }
  }
  return line;
}

class _WorkflowStep {
  _WorkflowStep(this.name);

  final String name;
  final List<String> runLines = <String>[];
  String? ifCondition;
  String? continueOnError;
}

List<String> _credentialPassClaims(String markdown) {
  final artifact = RegExp(
    r"\b(?:dmg|pkg(?!-config)|inno)\b",
    caseSensitive: false,
  );
  final pass = RegExp(
    r"\b(?:pass(?:ed|es)?|verified\s+(?:locally|in\s+ci)|"
    r"succeed(?:ed|s)?|successful|green)\b",
    caseSensitive: false,
  );
  final negatedPass = RegExp(
    r"\b(?:not|never|must\s+not|do\s+not|cannot|can't|no)\s+"
    r"(?:be\s+)?(?:claimed\s+as\s+)?"
    r"(?:pass(?:ed|es)?|verified\s+(?:locally|in\s+ci)|"
    r"succeed(?:ed|s)?|successful|green)\b",
    caseSensitive: false,
  );
  final rejectedPassClaim = RegExp(
    r"\b(?:reject(?:s|ed|ing)?|forbid(?:s|den|ding)?)\b[^.;\n]{0,48}"
    r"\b(?:pass(?:ed|es)?|verified\s+(?:locally|in\s+ci)|"
    r"succeed(?:ed|s)?|successful|green)\b|"
    r"\b(?:pass(?:ed|es)?|verified\s+(?:locally|in\s+ci)|"
    r"succeed(?:ed|s)?|successful|green)\b"
    r"[^.;\n]{0,24}\b(?:claim|claims)\b[^.;\n]{0,24}"
    r"\b(?:rejected|forbidden)\b",
    caseSensitive: false,
  );
  final redEvidence = RegExp(
    r"^\s*(?:[-*]\s*)?"
    r"(?:(?:re-review|review|follow-up)\s*\d*\s+)?"
    r"red\s*,?\s*verified\s+locally\b",
    caseSensitive: false,
  );
  return markdown
      .replaceAll("`", "")
      .split(
        RegExp(
          r"[;\n]|[.!?]\s+|,\s*(?=(?:while|and|but)\b)|"
          r"\s+(?:while|and|but)\s+"
          r"(?=(?:the\s+)?(?:signed\s+)?(?:dmg|pkg|inno)\b)",
          caseSensitive: false,
        ),
      )
      .map((sentence) => sentence.trim())
      .where(
    (sentence) {
      if (redEvidence.hasMatch(sentence)) return false;
      final positiveText = sentence
          .replaceAll(negatedPass, "")
          .replaceAll(rejectedPassClaim, "");
      return artifact.hasMatch(sentence) && pass.hasMatch(positiveText);
    },
  ).toList();
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
