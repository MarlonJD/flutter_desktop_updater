import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("Inno path arguments retain quotes for Start-Process", () {
    final script = _innoLaunchScript();

    expect(script, contains(r'''$args.Add('/DIR="' + $targetRoot + '"')'''));
    expect(script, contains(r'''$args.Add('/LOG="' + $logPath + '"')'''));
    expect(script, contains(r"-ArgumentList $args.ToArray() -Wait -PassThru"));
  });

  test(
    "Windows Inno launch preserves paths and explicit closure choices",
    () async {
      final root = await Directory.systemTemp.createTemp("inno arguments ");
      addTearDown(() async => root.delete(recursive: true));
      final capture = File(path.join(root.path, "capture arguments.exe"));
      final output = File(path.join(root.path, "received arguments.txt"));
      final script = File(path.join(root.path, "launch.ps1"));
      await script.writeAsString(
        r"""
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $env:INNO_TEST_CAPTURE)) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class CaptureArguments {
  public static void Main(string[] args) {
    File.WriteAllLines(Environment.GetEnvironmentVariable("INNO_TEST_OUTPUT"),
                       args, new UTF8Encoding(false));
  }
}
'@ -OutputAssembly $env:INNO_TEST_CAPTURE -OutputType ConsoleApplication
}
$installer = $env:INNO_TEST_CAPTURE
$targetRoot = $env:INNO_TEST_TARGET
$logPath = $env:INNO_TEST_LOG
$inno = $env:INNO_TEST_CONFIG | ConvertFrom-Json
function Write-DiagnosticsEvent([string] $Message) {}
""" +
            _innoLaunchScript() +
            r"""
if ($process.ExitCode -ne 0) {
  throw "Argument capture failed: $($process.ExitCode)"
}
""",
      );

      const defaultArgs = [
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
      ];
      const closureArgs = ["/CLOSEAPPLICATIONS", "/FORCECLOSEAPPLICATIONS"];
      const targets = <String>[
        r"C:\Program Files (x86)\Example App",
        r"C:\Program Files\Example App",
        r"C:\Users\Jane Doe\应用 更新",
        r"C:\Apps\O'Brien App",
        r"C:\Apps\Example",
      ];
      final cases = [
        for (final target in targets)
          for (final inherit in [true, false])
            (
              target: target,
              inherit: inherit,
              arguments: defaultArgs,
              expected: [...defaultArgs, ...closureArgs],
            ),
        for (final arguments in [
          [...defaultArgs, "/NOCLOSEAPPLICATIONS"],
          [...defaultArgs, "/noforcecloseapplications"],
          [...defaultArgs, "/closeapplications", "/forcecloseapplications"],
        ])
          (
            target: targets.first,
            inherit: true,
            arguments: arguments,
            expected: arguments,
          ),
        (
          target: targets.first,
          inherit: true,
          arguments: [...defaultArgs, "/CLOSEAPPLICATIONS"],
          expected: [...defaultArgs, ...closureArgs],
        ),
      ];
      for (final request in cases) {
        const log = r"C:\Users\Jane Doe\AppData\Local\Temp\Inno update (1).log";
        final process = await Process.start(
          "powershell.exe",
          [
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script.path,
          ],
          environment: {
            "INNO_TEST_CAPTURE": capture.path,
            "INNO_TEST_OUTPUT": output.path,
            "INNO_TEST_TARGET": request.target,
            "INNO_TEST_LOG": log,
            "INNO_TEST_CONFIG": jsonEncode({
              "inheritInstallDirectory": request.inherit,
              "silentArgs": request.arguments,
            }),
          },
        );
        final stdoutFuture = process.stdout.transform(utf8.decoder).join();
        final stderrFuture = process.stderr.transform(utf8.decoder).join();
        try {
          final exitCode = await process.exitCode.timeout(
            const Duration(seconds: 30),
          );
          expect(
            exitCode,
            0,
            reason: "${await stdoutFuture}\n${await stderrFuture}",
          );
          expect(await output.readAsLines(), [
            ...request.expected,
            if (request.inherit) "/DIR=${request.target}",
            "/LOG=$log",
          ]);
          await output.delete();
        } finally {
          process.kill();
          await process.exitCode;
        }
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

// Execute the actual generated PowerShell argument/launch block, so this test
// also covers the C++ string escaping and Start-Process serialization boundary.
String _innoLaunchScript() {
  final source = File("windows/desktop_updater_plugin.cpp").readAsStringSync();
  final start = source.indexOf(
    r"$args = New-Object System.Collections.Generic.List[string]",
  );
  final end = source.indexOf(r"if ($process.ExitCode -ne 0)", start);
  expect(start, isNonNegative);
  expect(end, greaterThan(start));
  final block = source.substring(
    source.lastIndexOf("\n", start) + 1,
    source.lastIndexOf("\n", end),
  );
  return RegExp(r'^\s*<< ("(?:[^"\\]|\\.)*")$', multiLine: true)
      .allMatches(block)
      .map((match) => jsonDecode(match.group(1)!) as String)
      .join();
}
