import "dart:io";

import "package:flutter_test/flutter_test.dart";

const _ledgerHeading = "## Current-Head Merge-Gate Ledger";

const _expectedLedger = <String, String>{
  "Portable contract, trust, provenance, lifecycle, redirect, and package-layout suites":
      "verified locally",
  "Task 10 complete local ladder": "verified locally",
  "macOS root SwiftPM tests": "verified locally",
  "macOS exact CocoaPods 10.14 five-source typecheck": "verified locally",
  "macOS external SwiftPM consumer": "not run",
  "Flutter macOS SwiftPM build and integration": "not run",
  "Flutter macOS CocoaPods build and integration": "not run",
  "macOS normal ZIP smoke": "not run",
  "Windows Unicode and relative redirect CTest": "not run",
  "Windows provenance, lifecycle, and C ABI CTest": "not run",
  "Windows source-contract target and reparse validation": "verified locally",
  "Windows junction/reparse transaction mutation and recovery": "blocked",
  "Windows Release NuGet isolated P/Invoke consumer": "not run",
  "Windows normal ZIP smoke": "not run",
  "Linux native tamper CTest": "not run",
  "Linux installed CMake consumer": "not run",
  "Linux standard and multiarch pkg-config consumers": "not run",
  "Linux mount/bind transaction mutation and recovery": "blocked",
  "Linux normal ZIP smoke": "not run",
  "Current remediation head in GitHub Actions": "not run",
  "macOS signed/notarized DMG smoke": "not run",
  "macOS signed/notarized PKG smoke": "not run",
  "Windows signed Inno smoke": "not run",
};

const _workflowCommands = <String, List<String>>{
  "dart": <String>[
    "dart run tool/generate_native_contract_fixtures.dart --check",
    "dart format --set-exit-if-changed .",
    "flutter analyze --no-fatal-infos",
    "flutter test --no-pub",
    "dart pub publish --dry-run",
  ],
  "macos-native": <String>[
    "xcrun swiftc -typecheck",
    "x86_64-apple-macosx10.14",
    "DesktopUpdaterVersion.swift",
    "Diagnostics.swift",
    "MacInstallHelper.swift",
    "MacInstallRequest.swift",
    "DesktopUpdaterPlugin.swift",
    "swift test --package-path .",
    "swift run --package-path example/native/macos",
    "tool/native_runtime_smoke_server.dart",
  ],
  "macos-flutter": <String>[
    "flutter config --enable-swift-package-manager",
    "flutter config --no-enable-swift-package-manager",
    "flutter build macos --debug",
    "flutter test integration_test -d macos",
  ],
  "windows": <String>[
    "ctest --test-dir windows/native/build -C Release --output-on-failure",
    "tool/verify_windows_nuget_consumer.ps1",
    "DesktopUpdater.Consumer.dll",
    "tool/native_runtime_smoke_server.dart",
  ],
  "linux": <String>[
    "ctest --test-dir linux/native/build --output-on-failure",
    "pkg-config --cflags --libs desktop_updater_native",
    "lib/x86_64-linux-gnu/pkgconfig",
    "ctest --test-dir example/native/linux-cmake-runtime/build",
    "dart run tool/native_runtime_smoke_server.dart",
  ],
};

void main() {
  test("publishes exactly one atomic current-head ledger", () {
    final runtimeApi = _read("docs/native-runtime-api.md");

    expect(_ledgerErrors(runtimeApi), isEmpty);
    expect(runtimeApi, contains("candidate-only"));
  });

  test("ledger validator rejects duplicate, stale, deleted, and swapped rows",
      () {
    final valid = _ledgerFixture(_expectedLedger);
    expect(_ledgerErrors(valid), isEmpty);
    expect(
      _ledgerErrors("$valid\n$valid"),
      contains("expected one ledger heading"),
    );
    expect(
      _ledgerErrors(
        valid.replaceFirst(
          "| macOS root SwiftPM tests | verified locally |",
          "",
        ),
      ),
      contains("missing row: macOS root SwiftPM tests"),
    );
    expect(
      _ledgerErrors(
        valid.replaceFirst(
          "| macOS root SwiftPM tests | verified locally |",
          "| stale combined macOS lane | verified locally |",
        ),
      ),
      contains("unexpected row: stale combined macOS lane"),
    );
    expect(
      _ledgerErrors(
        valid
            .replaceFirst(
              "| macOS root SwiftPM tests | verified locally |",
              "| macOS root SwiftPM tests | not run |",
            )
            .replaceFirst(
              "| macOS external SwiftPM consumer | not run |",
              "| macOS external SwiftPM consumer | verified locally |",
            ),
      ),
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

  test("workflow validator ignores comments and rejects commands in wrong jobs",
      () {
    const fixture = """
jobs:
  dart:
    steps:
      # run: flutter test --no-pub
      - run: dart format --set-exit-if-changed .
  unrelated:
    steps:
      - run: flutter test --no-pub
""";

    expect(
      _workflowErrors(fixture, const <String, List<String>>{
        "dart": <String>[
          "dart format --set-exit-if-changed .",
          "flutter test --no-pub",
        ],
      }),
      contains("dart missing command: flutter test --no-pub"),
    );
  });

  test("credential-gated artifact pass claims are rejected in all merge docs",
      () {
    final docs = _mergeGateDocs.map(_read).join("\n");

    expect(_credentialPassClaims(docs), isEmpty);
    expect(
      _credentialPassClaims("""
Signed DMG passed.
The PKG smoke is verified locally.
Inno lane verified in CI.
"""),
      hasLength(3),
    );
    expect(
      _credentialPassClaims(
        "Credential-gated DMG, PKG, and Inno lanes are not run.",
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

List<String> _ledgerErrors(String markdown) {
  final headingCount = RegExp(
    "^${RegExp.escape(_ledgerHeading)}\\s*\$",
    multiLine: true,
  ).allMatches(markdown).length;
  if (headingCount != 1) return <String>["expected one ledger heading"];

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
  Map<String, List<String>> expected,
) {
  final runs = _jobRunText(yaml);
  return <String>[
    for (final entry in expected.entries)
      for (final command in entry.value)
        if (!(runs[entry.key] ?? "").contains(command))
          "${entry.key} missing command: $command",
  ];
}

Map<String, String> _jobRunText(String yaml) {
  final output = <String, StringBuffer>{};
  String? job;
  var runIndent = -1;
  for (final line in yaml.split("\n")) {
    final indent = line.length - line.trimLeft().length;
    final trimmed = line.trim();
    final jobMatch =
        indent == 2 ? RegExp(r"^([A-Za-z0-9_-]+):$").firstMatch(trimmed) : null;
    if (jobMatch != null) {
      job = jobMatch.group(1);
      output.putIfAbsent(job!, StringBuffer.new);
      runIndent = -1;
      continue;
    }
    if (job == null || trimmed.startsWith("#")) continue;
    if (runIndent >= 0) {
      if (trimmed.isNotEmpty && indent <= runIndent) runIndent = -1;
      if (runIndent >= 0) output[job]!.writeln(trimmed);
    }
    final runMatch = RegExp(r"^run:\s*(.*)$").firstMatch(trimmed);
    if (runMatch == null) continue;
    final value = runMatch.group(1)!;
    if (value == "|" || value == ">") {
      runIndent = indent;
    } else {
      output[job]!.writeln(value);
    }
  }
  return <String, String>{
    for (final entry in output.entries) entry.key: entry.value.toString(),
  };
}

List<String> _credentialPassClaims(String markdown) {
  final artifact = RegExp(r"\b(?:dmg|pkg|inno)\b", caseSensitive: false);
  final pass = RegExp(
    r"\b(?:pass(?:ed|es)?|verified(?:\s+(?:locally|in\s+ci))?)\b",
    caseSensitive: false,
  );
  final explicitNonPass = RegExp(
    r"\b(?:not\s+run|credential[- ]gated|without\s+(?:explicit\s+)?credentials|no\s+verified|reject\s+claims|must\s+not|do\s+not)\b",
    caseSensitive: false,
  );
  final evidenceContext = RegExp(
    r"\b(?:signed|notarized|smoke|lane|gate|artifact|target-host|ci)\b",
    caseSensitive: false,
  );
  return markdown
      .replaceAll("`", "")
      .split(RegExp(r"\n|[.!?]\s+"))
      .map((sentence) => sentence.trim())
      .where(
        (sentence) =>
            artifact.hasMatch(sentence) &&
            evidenceContext.hasMatch(sentence) &&
            pass.hasMatch(sentence) &&
            !explicitNonPass.hasMatch(sentence),
      )
      .toList();
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
