import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("3.0 rejects removed Dart callers and opaque-value construction",
      () async {
    final fixtures = <_AnalyzerExpectation>[
      const _AnalyzerExpectation(
        "legacy_controller_arguments.dart",
        "UNDEFINED_NAMED_PARAMETER",
        "unsigned flag and diagnostics path",
      ),
      const _AnalyzerExpectation(
        "legacy_raw_descriptor_download.dart",
        "UNDEFINED_METHOD",
        "raw descriptor download",
      ),
      const _AnalyzerExpectation(
        "legacy_platform_fallback.dart",
        "OVERRIDE_ON_NON_OVERRIDING_MEMBER",
        "platform fallback",
      ),
      const _AnalyzerExpectation(
        "opaque_value_construction.dart",
        "UNDEFINED_CONSTRUCTOR",
        "final result and retained-stage construction",
      ),
      const _AnalyzerExpectation(
        "opaque_persistence_and_request.dart",
        "NEW_WITH_UNDEFINED_CONSTRUCTOR_DEFAULT",
        "persistence receipt construction",
      ),
      const _AnalyzerExpectation(
        "opaque_persistence_and_request.dart",
        "INVALID_USE_OF_TYPE_OUTSIDE_LIBRARY",
        "sealed install-request implementation",
      ),
      const _AnalyzerExpectation(
        "final_value_implementation.dart",
        "INVALID_USE_OF_TYPE_OUTSIDE_LIBRARY",
        "final result, receipt, and retained-stage implementation",
      ),
      const _AnalyzerExpectation(
        "sealed_recovery_implementation.dart",
        "INVALID_USE_OF_TYPE_OUTSIDE_LIBRARY",
        "base-only recovery implementation",
      ),
    ];

    final failures = <String>[];
    for (final fixture in fixtures) {
      final result = await _analyze(fixture.path);
      if (result.exitCode == 0 ||
          !_output(result).contains(fixture.diagnostic)) {
        failures.add(_reason(fixture.label, result));
      }
    }

    final testingAuthority = await _analyze("for_testing_authority_seams.dart");
    final testingAuthorityOutput = _output(testingAuthority);
    if (testingAuthority.exitCode == 0) {
      failures.add(
        "forTesting must reject retained authority seams.\n$testingAuthorityOutput",
      );
    }
    for (final seam in <String>[
      "checkResult",
      "stageResult",
      "verifiedNativeInstallRequest",
      "persistedInstallTransaction",
    ]) {
      if (!testingAuthorityOutput
          .contains("The named parameter '$seam' isn't defined")) {
        failures.add(
          "forTesting must not accept the $seam authority seam.\n$testingAuthorityOutput",
        );
      }
    }
    expect(failures, isEmpty, reason: failures.join("\n\n"));
  });

  test("3.0 rejects Swift unsigned runtime switches", () async {
    final result = await Process.run(
      "swift",
      const <String>[
        "build",
        "--package-path",
        "test/fixtures/v3_removed_api/swift",
        "--target",
        "LegacyUnsignedRuntimeConsumer",
      ],
      runInShell: false,
    );

    expect(
      result.exitCode,
      isNot(0),
      reason:
          "Legacy Swift unsigned controls must not compile.\n${_output(result)}",
    );
  });
}

Future<ProcessResult> _analyze(String fixture) {
  return Process.run(
    "dart",
    <String>[
      "analyze",
      "--format",
      "machine",
      "test/fixtures/v3_removed_api/dart/$fixture",
    ],
    runInShell: false,
  );
}

String _output(ProcessResult result) => "${result.stdout}\n${result.stderr}";

String _reason(String label, ProcessResult result) {
  return "$label must be rejected by the real compiler.\n${_output(result)}";
}

final class _AnalyzerExpectation {
  const _AnalyzerExpectation(this.path, this.diagnostic, this.label);

  final String path;
  final String diagnostic;
  final String label;
}
