import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("documents the two macOS integration floors without renaming the module",
      () {
    final guide = _read("docs/native-sdk.md");
    final runtimeApi = _read("docs/native-runtime-api.md");
    final workflow = _read(".github/workflows/desktop-updater-ci.yml");
    final combined = "$guide\n$runtimeApi";

    expect(combined, contains("SwiftPM macOS 10.15"));
    expect(combined, contains("import DesktopUpdaterKit"));
    expect(combined, contains("CocoaPods macOS 10.14"));
    for (final source in <String>[
      "DesktopUpdaterVersion.swift",
      "Diagnostics.swift",
      "MacInstallHelper.swift",
      "MacInstallRequest.swift",
      "DesktopUpdaterPlugin.swift",
    ]) {
      expect(guide, contains(source), reason: source);
      expect(workflow, contains(source), reason: source);
    }
    expect(workflow, contains("x86_64-apple-macosx10.14"));
    expect(workflow, contains("swift test --package-path ."));
  });

  test("documents current trust, ownership, target, and handoff boundaries",
      () {
    final readme = _read("README.md");
    final guide = _read("docs/native-sdk.md");
    final runtimeApi = _read("docs/native-runtime-api.md");
    final diagnostics = _read("docs/diagnostics-and-recovery.md");
    final migration = _read("docs/migration/1.x-to-2.0.md");
    final combined = "$readme\n$guide\n$runtimeApi\n$diagnostics\n$migration";

    for (final boundary in <String>[
      "signed app-archive authority",
      "owned stage provenance",
      "explicit install target proof",
      "mount and reparse rejection",
      "one-shot handoff",
      "Windows Unicode paths",
      "relative redirects",
      "Release NuGet",
      "third-party notices",
    ]) {
      expect(combined, contains(boundary), reason: boundary);
    }
    expect(combined, contains("native transaction recovery journal"));
    expect(combined, contains("blocked"));
    expect(
      diagnostics,
      contains(
        "Flutter `UpdateRecoveryStore` is not a native transaction journal",
      ),
    );
  });

  test("workflow configures ordinary target-host merge gates separately", () {
    final workflow = _read(".github/workflows/desktop-updater-ci.yml");

    for (final command in <String>[
      "dart run tool/generate_native_contract_fixtures.dart --check",
      "dart format --set-exit-if-changed .",
      "flutter analyze --no-fatal-infos",
      "flutter test --no-pub",
      "dart pub publish --dry-run",
      "swift test --package-path .",
      "swift run --package-path example/native/macos",
      "Typecheck macOS 10.14 CocoaPods fallback source set",
      "--enable-swift-package-manager",
      "--no-enable-swift-package-manager",
      "Run Windows Unicode and relative redirect target-host gates",
      "Run isolated Release NuGet P/Invoke consumer",
      "Build and run Linux multiarch pkg-config consumer",
      "Run Linux native tamper target-host gates",
      "macOS native runtime ZIP smoke",
      "Windows native runtime ZIP smoke",
      "Linux native runtime ZIP smoke",
    ]) {
      expect(workflow, contains(command), reason: command);
    }
    expect(
      RegExp("No tests were found").allMatches(workflow).length,
      greaterThanOrEqualTo(9),
    );
    expect(workflow, contains("macos-notarized:"));
    expect(workflow, contains("DESKTOP_UPDATER_RUN_SIGNED_NATIVE_RUNTIME_E2E"));
    expect(workflow, contains("WINDOWS_CODE_SIGNING_P12_BASE64"));
    expect(
      workflow,
      contains("Native transaction recovery remains blocked by Task 6"),
    );
  });

  test("publishes one literal candidate-only merge-gate ledger", () {
    final runtimeApi = _read("docs/native-runtime-api.md");
    final remediation = _read(
      "docs/exec-plans/active/"
      "2026-07-10-native-runtime-merge-blocker-remediation-plan.md",
    );
    final parent = _read(
      "docs/exec-plans/active/2026-07-05-full-native-runtime-preview-plan.md",
    );

    expect(runtimeApi, contains("## Merge-Gate Ledger"));
    for (final label in <String>[
      "verified locally",
      "verified in CI",
      "not run",
      "blocked",
    ]) {
      expect(runtimeApi, contains("`$label`"), reason: label);
    }
    expect(runtimeApi, contains("candidate-only"));
    expect(runtimeApi, isNot(contains("normal target-host CI")));
    expect(
      parent,
      contains(
        "2026-07-10-native-runtime-merge-blocker-remediation-plan.md",
      ),
    );
    expect(parent, isNot(contains("20 successful checks")));
    expect(remediation, contains("Corrected PR #65 body draft (not posted)"));
    expect(_signedLanePassClaims(runtimeApi), isEmpty);
  });

  test("signed lane validator rejects credential-free pass claims", () {
    const invalid = """
| macOS | `dmg` | `verified in CI` |
| macOS | `pkgInstaller` | passed |
| Windows | `innoInstaller` | `verified locally` |
""";

    expect(_signedLanePassClaims(invalid), hasLength(3));
  });
}

List<String> _signedLanePassClaims(String text) {
  const signedArtifacts = <String>[
    "`dmg`",
    "`pkgInstaller`",
    "`innoInstaller`",
  ];
  return text.split("\n").where((line) {
    if (!line.trimLeft().startsWith("|")) return false;
    if (!signedArtifacts.any(line.contains)) return false;
    final lower = line.toLowerCase();
    return lower.contains("verified locally") ||
        lower.contains("verified in ci") ||
        RegExp(r"\bpass(?:ed|es)?\b").hasMatch(lower);
  }).toList();
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
