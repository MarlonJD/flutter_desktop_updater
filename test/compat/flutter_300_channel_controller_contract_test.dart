import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../support/dart_cli.dart";

void main() {
  test("3.0 platform handoff requires the verified native payload", () async {
    final result = await _analyze("verified_platform_contract.dart");

    expect(
      result.exitCode,
      0,
      reason: _reason(
        "The typed platform method must accept every required verified "
        "MethodChannel payload binding.",
        result,
      ),
    );
  });

  test("Windows atomic recovery exposes no direct recover operation", () async {
    final result = await _analyze("atomic_recovery_has_no_direct_recover.dart");

    expect(result.exitCode, isNonZero,
        reason: _reason("Expected failure.", result));
    expect(
      _machineOutput(result),
      contains("UNDEFINED_METHOD"),
      reason: _reason(
        "The Windows atomic capability must not grow a direct-recover member.",
        result,
      ),
    );
  });
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
