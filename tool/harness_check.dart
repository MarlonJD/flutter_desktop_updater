import "dart:io";

const reportPath = "reports/harness-check.md";

const harnessCommands = [
  HarnessCommand(
    "Format",
    "dart format --set-exit-if-changed .",
    "dart",
    ["format", "--set-exit-if-changed", "."],
  ),
  HarnessCommand(
    "Analyze",
    "flutter analyze --no-fatal-infos --no-pub",
    "flutter",
    ["analyze", "--no-fatal-infos", "--no-pub"],
  ),
  HarnessCommand(
    "Focused harness test",
    "flutter test --no-pub test/harness_engineering_docs_test.dart",
    "flutter",
    ["test", "--no-pub", "test/harness_engineering_docs_test.dart"],
  ),
  HarnessCommand(
    "Full test suite",
    "flutter test --no-pub",
    "flutter",
    ["test", "--no-pub"],
  ),
  HarnessCommand(
    "Publish dry-run",
    "dart pub publish --dry-run",
    "dart",
    ["pub", "publish", "--dry-run"],
  ),
];

final class HarnessCommand {
  const HarnessCommand(
    this.name,
    this.displayCommand,
    this.executable,
    this.arguments,
  );

  final String name;
  final String displayCommand;
  final String executable;
  final List<String> arguments;
}

final class HarnessResult {
  const HarnessResult({
    required this.command,
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
    required this.elapsed,
  });

  final HarnessCommand command;
  final int exitCode;
  final String stdoutText;
  final String stderrText;
  final Duration elapsed;

  bool get passed => exitCode == 0;
}

Future<void> main() async {
  final startedAt = DateTime.now().toUtc();
  final results = <HarnessResult>[];

  for (final command in harnessCommands) {
    stdout.writeln("[harness] ${command.displayCommand}");
    final stopwatch = Stopwatch()..start();

    try {
      final result = await Process.run(
        command.executable,
        command.arguments,
        runInShell: false,
      );

      results.add(
        HarnessResult(
          command: command,
          exitCode: result.exitCode,
          stdoutText: result.stdout.toString(),
          stderrText: result.stderr.toString(),
          elapsed: stopwatch.elapsed,
        ),
      );
    } on Object catch (error, stackTrace) {
      results.add(
        HarnessResult(
          command: command,
          exitCode: 127,
          stdoutText: "",
          stderrText: "$error\n$stackTrace",
          elapsed: stopwatch.elapsed,
        ),
      );
    } finally {
      stopwatch.stop();
    }
  }

  final finishedAt = DateTime.now().toUtc();
  final report = _buildReport(
    startedAt: startedAt,
    finishedAt: finishedAt,
    results: results,
  );

  final reportFile = File(reportPath);
  await reportFile.parent.create(recursive: true);
  await reportFile.writeAsString(report);

  final failed = results.where((result) => !result.passed).toList();
  if (failed.isEmpty) {
    stdout.writeln("[harness] Report written to $reportPath");
    exitCode = 0;
    return;
  }

  stderr
    ..writeln("[harness] ${failed.length} command(s) failed.")
    ..writeln("[harness] Report written to $reportPath");
  exitCode = failed.first.exitCode == 0 ? 1 : failed.first.exitCode;
}

String _buildReport({
  required DateTime startedAt,
  required DateTime finishedAt,
  required List<HarnessResult> results,
}) {
  final failedCount = results.where((result) => !result.passed).length;
  final buffer = StringBuffer()
    ..writeln("# Harness Check")
    ..writeln()
    ..writeln("- Started: `${startedAt.toIso8601String()}`")
    ..writeln("- Finished: `${finishedAt.toIso8601String()}`")
    ..writeln("- Status: `${failedCount == 0 ? "passed" : "failed"}`")
    ..writeln()
    ..writeln("| Step | Command | Exit code | Duration |")
    ..writeln("| --- | --- | ---: | ---: |");

  for (final result in results) {
    buffer.writeln(
      "| ${result.command.name} | `${result.command.displayCommand}` | "
      "${result.exitCode} | ${_formatDuration(result.elapsed)} |",
    );
  }

  for (final result in results) {
    buffer
      ..writeln()
      ..writeln("## ${result.command.name}")
      ..writeln()
      ..writeln("Command: `${result.command.displayCommand}`")
      ..writeln()
      ..writeln("Exit code: ${result.exitCode}")
      ..writeln()
      ..writeln("Duration: ${_formatDuration(result.elapsed)}")
      ..writeln()
      ..writeln("### stdout")
      ..writeln()
      ..writeln("```text")
      ..write(result.stdoutText.trimRight());

    if (result.stdoutText.trimRight().isNotEmpty) {
      buffer.writeln();
    }

    buffer
      ..writeln("```")
      ..writeln()
      ..writeln("### stderr")
      ..writeln()
      ..writeln("```text")
      ..write(result.stderrText.trimRight());

    if (result.stderrText.trimRight().isNotEmpty) {
      buffer.writeln();
    }

    buffer.writeln("```");
  }

  return buffer.toString();
}

String _formatDuration(Duration duration) {
  final seconds = duration.inMilliseconds / Duration.millisecondsPerSecond;
  return "${seconds.toStringAsFixed(1)}s";
}
