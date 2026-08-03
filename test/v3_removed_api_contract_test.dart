import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

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
        "NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER",
        "platform fallback",
      ),
      const _AnalyzerExpectation(
        "opaque_value_construction.dart",
        "UNDEFINED_CONSTRUCTOR",
        "final result and retained-stage construction",
      ),
      const _AnalyzerExpectation(
        "opaque_persistence_and_request.dart",
        "UNDEFINED_CONSTRUCTOR",
        "persistence receipt construction",
      ),
      const _AnalyzerExpectation(
        "opaque_persistence_and_request.dart",
        "SUBTYPE_OF_SEALED_CLASS",
        "sealed install-request implementation",
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
    expect(failures, isEmpty, reason: failures.join("\n\n"));
  });

  test("3.0 native consumers reject removed source and ABI entries", () async {
    final root = Directory.current.path;
    final commands = <_CommandExpectation>[
      _CommandExpectation(
        "C scheduleInstallAndRelaunch",
        "clang",
        <String>[
          "-std=c11",
          "-Werror",
          "-I",
          path.join(root, "windows/native/include"),
          "-fsyntax-only",
          path.join(root,
              "test/fixtures/v3_removed_api/windows-c/legacy_schedule_install.c"),
        ],
        root,
      ),
      _CommandExpectation(
        "C++ Windows legacy schedule entry",
        "clang++",
        <String>[
          "-std=c++17",
          "-Werror",
          "-I",
          path.join(root, "windows/native/include"),
          "-fsyntax-only",
          path.join(root,
              "test/fixtures/v3_removed_api/windows-cpp/legacy_schedule_install.cc"),
        ],
        root,
      ),
      _CommandExpectation(
        "Linux CMake legacy scheduler source",
        "clang++",
        <String>[
          "-std=c++17",
          "-Werror",
          "-I",
          path.join(root, "linux/native/include"),
          "-fsyntax-only",
          path.join(root, "test/fixtures/v3_removed_api/linux-cmake/main.cpp"),
        ],
        root,
      ),
      _CommandExpectation(
        "Swift unsigned install request",
        "swift",
        <String>[
          "build",
          "--package-path",
          path.join(root, "test/fixtures/v3_removed_api/swift"),
        ],
        root,
      ),
      _CommandExpectation(
        "dotnet schedule and diagnostics path",
        "dotnet",
        <String>[
          "build",
          path.join(root,
              "test/fixtures/v3_removed_api/windows-dotnet/LegacyConsumer.csproj"),
          "--nologo",
        ],
        root,
      ),
    ];

    final failures = <String>[];
    for (final command in commands) {
      final result = await Process.run(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
        runInShell: false,
      );
      if (result.exitCode == 0) {
        failures.add(_reason(command.label, result));
      }
    }
    expect(failures, isEmpty, reason: failures.join("\n\n"));
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

final class _CommandExpectation {
  const _CommandExpectation(
    this.label,
    this.executable,
    this.arguments,
    this.workingDirectory,
  );

  final String label;
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}
