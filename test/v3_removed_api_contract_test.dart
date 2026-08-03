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
      const _AnalyzerExpectation(
        "final_value_implementation.dart",
        "SUBTYPE_OF_FINAL_IS_NOT_BASE",
        "final result, receipt, and retained-stage implementation",
      ),
      const _AnalyzerExpectation(
        "sealed_recovery_implementation.dart",
        "SUBTYPE_OF_SEALED_CLASS",
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
    expect(failures, isEmpty, reason: failures.join("\n\n"));

    final testingAuthority = await _analyze("for_testing_authority_seams.dart");
    final testingAuthorityOutput = _output(testingAuthority);
    expect(testingAuthority.exitCode, isNonZero);
    for (final seam in <String>[
      "checkResult",
      "stageResult",
      "verifiedNativeInstallRequest",
      "persistedInstallTransaction",
    ]) {
      expect(
        testingAuthorityOutput,
        contains("The named parameter '$seam' isn't defined"),
        reason: "forTesting must not accept the $seam authority seam.\n"
            "$testingAuthorityOutput",
      );
    }
  });

  test("3.0 native consumers reject removed source and ABI entries", () async {
    final root = Directory.current.path;
    final commands = <_CommandExpectation>[
      _CommandExpectation(
        "C scheduleInstallAndRelaunch",
        "desktop_updater_schedule_install_and_relaunch_v1",
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
        "desktop_updater_schedule_install_and_relaunch_v1",
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
        "Swift unsigned install request",
        "scheduleInstallAndRelaunch",
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
        "ScheduleInstallAndRelaunch",
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
      if (result.exitCode == 0 ||
          !_output(result).contains(command.expectedDiagnosticToken)) {
        failures.add(_reason(command.label, result));
      }
    }
    final linuxCmake = await _buildLinuxCmakeConsumer(root);
    if (Platform.isLinux) {
      expect(
        linuxCmake,
        isNotNull,
        reason: "Linux contract validation requires the CMake compiler path.",
      );
    }
    if (linuxCmake != null &&
        (linuxCmake.exitCode == 0 ||
            !linuxCmake.output.contains("ScheduleInstallAndRelaunch"))) {
      failures.add(
        "Linux CMake legacy scheduler consumer must be rejected by the real "
                "CMake compiler path.\n" +
            linuxCmake.output,
      );
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

Future<_CmakeResult?> _buildLinuxCmakeConsumer(String root) async {
  try {
    final availability = await Process.run(
      "cmake",
      const <String>["--version"],
      runInShell: false,
    );
    if (availability.exitCode != 0) {
      return null;
    }
  } on ProcessException {
    return null;
  }

  final build = await Directory.systemTemp.createTemp(
    "desktop-updater-v3-removed-linux-cmake-",
  );
  try {
    final fixture = path.join(root, "test/fixtures/v3_removed_api/linux-cmake");
    final configure = await Process.run(
      "cmake",
      <String>[
        "-S",
        fixture,
        "-B",
        build.path,
        "-DDESKTOP_UPDATER_SOURCE_ROOT=$root",
      ],
      runInShell: false,
    );
    if (configure.exitCode != 0) {
      return _CmakeResult(configure.exitCode, _output(configure));
    }

    final compile = await Process.run(
      "cmake",
      <String>["--build", build.path],
      runInShell: false,
    );
    return _CmakeResult(
      compile.exitCode,
      _output(configure) + "\n" + _output(compile),
    );
  } finally {
    await build.delete(recursive: true);
  }
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
    this.expectedDiagnosticToken,
    this.executable,
    this.arguments,
    this.workingDirectory,
  );

  final String label;
  final String expectedDiagnosticToken;
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

final class _CmakeResult {
  const _CmakeResult(this.exitCode, this.output);

  final int exitCode;
  final String output;
}
