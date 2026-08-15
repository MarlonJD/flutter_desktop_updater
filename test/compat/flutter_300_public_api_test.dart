import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../support/dart_cli.dart";

void main() {
  test("3.0 preserves the controller, state, and widget surface", () async {
    final result = await _analyze("positive_controller_surface.dart");

    expect(
      result.exitCode,
      0,
      reason: _reason(
        "The preserved public surface must compile with all four required "
        "controller authority and durability inputs.",
        result,
      ),
    );
  });

  test("3.0 exposes only owner-bound v3 capabilities", () async {
    final result = await _analyze("positive_v3_capabilities.dart");

    expect(
      result.exitCode,
      0,
      reason: _reason(
        "The pending-v3 marker, session, persistence receipt, retained-stage "
        "claim, dispatcher, and typed recovery capabilities must compile as "
        "one coherent contract.",
        result,
      ),
    );
  });

  for (final constructor in <String>["primary", "for_testing"]) {
    for (final argument in <String>[
      "app_archive_url",
      "expected_package_id",
      "trusted_release_public_keys",
      "recovery_store",
    ]) {
      test("$constructor constructor requires $argument", () async {
        final result = await _analyze("missing_${constructor}_$argument.dart");

        expect(
          result.exitCode,
          isNonZero,
          reason: _reason(
            "Omitting $argument must be a compile-time error, not optional "
            "trust or recovery configuration.",
            result,
          ),
        );
        expect(
          _machineOutput(result),
          contains("MISSING_REQUIRED_ARGUMENT"),
          reason: _reason(
            "The fixture must fail because its required argument is absent.",
            result,
          ),
        );
      });
    }
  }
}

Future<ProcessResult> _analyze(String fixture) {
  return Process.run(
    resolveDartExecutable(),
    <String>[
      "analyze",
      "--format",
      "machine",
      "test/fixtures/v3_contract/dart/$fixture",
    ],
    runInShell: false,
  );
}

String _machineOutput(ProcessResult result) =>
    "${result.stdout}\n${result.stderr}";

String _reason(String expectation, ProcessResult result) {
  return "$expectation\n"
      r"$ dart analyze --format machine "
      "test/fixtures/v3_contract/dart/<fixture>\n${_machineOutput(result)}";
}
