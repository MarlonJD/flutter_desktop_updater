import "dart:async";
import "dart:io";

Future<void> main(List<String> args) async {
  final relaunch = args.contains("--relaunch");
  final productionGates = args.contains("--production-gates");
  final config = _argValue(args, "--config") ?? "Debug";
  if (config != "Debug" && config != "Release") {
    stderr.writeln("--config must be Debug or Release.");
    _usage();
    exit(64);
  }

  final appPath =
      _absolutePath(_argValue(args, "--app") ?? _defaultAppPath(config));
  final stagedAppPath = _absolutePath(_argValue(args, "--staged-app"));

  if (appPath == null) {
    _usage();
    exit(64);
  }

  if (Platform.isMacOS && productionGates && stagedAppPath == null) {
    stderr.writeln(
      "--production-gates requires --staged-app with a signed, notarized, "
      "stapled .app that already contains the smoke sentinel.",
    );
    _usage();
    exit(64);
  }

  final executablePath = _executablePath(appPath);
  final installRoot = _installRoot(appPath);

  if (!File(executablePath).existsSync()) {
    stderr.writeln("Executable not found: $executablePath");
    _usage();
    exit(66);
  }

  final tempRoot = await Directory.systemTemp.createTemp(
    "desktop_updater_smoke_",
  );
  final stagingRoot = await _prepareStagingRoot(
    appPath: appPath,
    stagedAppPath: stagedAppPath,
    tempRoot: tempRoot,
  );
  final markerPath = _join(tempRoot.path, "marker.txt");
  final diagnosticsLogPath =
      _absolutePath(_argValue(args, "--diagnostics-log")) ??
          _join(tempRoot.path, "helper-diagnostics.jsonl");
  final diagnosticsLog = File(diagnosticsLogPath);
  await diagnosticsLog.parent.create(recursive: true);
  if (await diagnosticsLog.exists()) {
    await diagnosticsLog.delete();
  }
  final sentinelRelativePath = Platform.isMacOS
      ? _join("Resources", "desktop_updater_smoke.txt")
      : "desktop_updater_smoke.txt";
  final stagedSentinel = File(
    _join(_stagingContentRoot(stagingRoot.path), sentinelRelativePath),
  );
  final installedSentinel = File(_join(installRoot, sentinelRelativePath));

  if (installedSentinel.existsSync()) {
    if (productionGates) {
      stderr.writeln(
        "Installed app already contains ${installedSentinel.path}; refusing "
        "to mutate a production-gates app before the update.",
      );
      exit(65);
    }
    installedSentinel.deleteSync();
  }

  if (productionGates) {
    if (!stagedSentinel.existsSync()) {
      stderr.writeln(
        "Production staged app must already contain ${stagedSentinel.path} "
        "before signing, notarization, and stapling.",
      );
      exit(66);
    }
  } else {
    await stagedSentinel.parent.create(recursive: true);
    await stagedSentinel.writeAsString(
      "desktop_updater smoke ${DateTime.now().toIso8601String()}",
    );
  }

  stdout
    ..writeln("Launching $executablePath")
    ..writeln("Staging update in ${stagingRoot.path}");

  final process = await Process.start(
    executablePath,
    const [],
    environment: {
      "DESKTOP_UPDATER_SMOKE_STAGING": stagingRoot.path,
      "DESKTOP_UPDATER_SMOKE_MARKER": markerPath,
      "DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG": diagnosticsLogPath,
      if (!relaunch) "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1",
      if (Platform.isMacOS && !productionGates)
        "DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS": "1",
    },
    mode: ProcessStartMode.normal,
    workingDirectory: File(executablePath).parent.path,
  );

  process.stdout.listen(stdout.add);
  process.stderr.listen(stderr.add);

  await _waitForFileText(markerPath, "installing", const Duration(seconds: 15));
  stdout.writeln("App scheduled native installation and is closing...");

  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      process.kill();
      throw TimeoutException("App did not exit after scheduling update.");
    },
  );

  stdout.writeln("Initial app process exited with code $exitCode");

  await _waitFor(
    installedSentinel.existsSync,
    const Duration(seconds: 45),
    "Timed out waiting for staged file to be copied into $installRoot",
  );

  await _waitFor(
    () => !stagingRoot.existsSync(),
    const Duration(seconds: 10),
    "Timed out waiting for staging directory cleanup.",
  );

  await _expectDiagnosticsLog(
    diagnosticsLogPath,
    const <String>[
      "helper scheduled",
      "backup start",
      "move start",
      "cleanup success",
    ],
  );

  stdout
    ..writeln("Smoke update installed: ${installedSentinel.path}")
    ..writeln("Helper diagnostics log: $diagnosticsLogPath")
    ..writeln(
      relaunch
          ? "Relaunch was enabled; close the relaunched example app manually."
          : "Relaunch was skipped for test cleanup. Pass --relaunch to test it.",
    );
}

String? _defaultAppPath(String config) {
  if (Platform.isMacOS) {
    return _joinAll([
      "build",
      "macos",
      "Build",
      "Products",
      config,
      "desktop_updater_example.app",
    ]);
  }

  if (Platform.isWindows) {
    return _joinAll([
      "build",
      "windows",
      "x64",
      "runner",
      config,
      "desktop_updater_example.exe",
    ]);
  }

  if (Platform.isLinux) {
    return _joinAll([
      "build",
      "linux",
      "x64",
      config.toLowerCase(),
      "bundle",
      "desktop_updater_example",
    ]);
  }

  return null;
}

String _executablePath(String appPath) {
  if (Platform.isMacOS && appPath.endsWith(".app")) {
    return _joinAll([appPath, "Contents", "MacOS", "desktop_updater_example"]);
  }

  return appPath;
}

String _installRoot(String appPath) {
  if (Platform.isMacOS && appPath.endsWith(".app")) {
    return _join(appPath, "Contents");
  }

  return File(appPath).parent.path;
}

Future<Directory> _prepareStagingRoot({
  required String appPath,
  required String? stagedAppPath,
  required Directory tempRoot,
}) async {
  final stageParent = Directory(_join(tempRoot.path, "stage"));

  if (!Platform.isMacOS) {
    return stageParent;
  }

  await stageParent.create(recursive: true);
  final sourceAppPath = stagedAppPath ?? appPath;
  final stagedApp =
      Directory(_join(stageParent.path, _basename(sourceAppPath)));
  final result = await Process.run("/usr/bin/ditto", [
    sourceAppPath,
    stagedApp.path,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      "/usr/bin/ditto",
      [appPath, stagedApp.path],
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }

  await File(
    _join(stageParent.path, ".desktop_updater_release_manifest.json"),
  ).writeAsString("{}");
  return stagedApp;
}

String _stagingContentRoot(String stagingPath) {
  if (Platform.isMacOS && stagingPath.endsWith(".app")) {
    return _join(stagingPath, "Contents");
  }
  return stagingPath;
}

Future<void> _waitForFileText(
  String filePath,
  String expected,
  Duration timeout,
) async {
  await _waitFor(
    () =>
        File(filePath).existsSync() &&
        File(filePath).readAsStringSync().trim() == expected,
    timeout,
    "Timed out waiting for smoke marker '$expected'.",
  );
}

Future<void> _waitFor(
  bool Function() condition,
  Duration timeout,
  String timeoutMessage,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException(timeoutMessage);
}

Future<void> _expectDiagnosticsLog(
  String logPath,
  List<String> expectedEvents,
) async {
  final log = File(logPath);
  await _waitFor(
    log.existsSync,
    const Duration(seconds: 10),
    "Timed out waiting for helper diagnostics log at $logPath.",
  );

  final contents = await log.readAsString();
  for (final event in expectedEvents) {
    if (!contents.contains('"event":"$event"')) {
      stderr.writeln(contents);
      throw StateError(
        "Helper diagnostics log missing event '$event' in $logPath.",
      );
    }
  }
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

String _join(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) {
    return "$left$right";
  }
  return "$left${Platform.pathSeparator}$right";
}

String _joinAll(List<String> parts) {
  return parts.reduce(_join);
}

String _basename(String path) {
  final normalized = path.endsWith(Platform.pathSeparator)
      ? path.substring(0, path.length - 1)
      : path;
  return normalized.split(Platform.pathSeparator).last;
}

String? _absolutePath(String? path) {
  if (path == null) {
    return null;
  }
  return File(path).absolute.path;
}

void _usage() {
  stderr.writeln(
    "Usage: dart run tool/updater_smoke.dart [--app <path>] "
    "[--config Debug|Release] [--diagnostics-log <path>] [--relaunch]\n"
    "\n"
    "Use --production-gates --staged-app <path> on macOS with a signed, "
    "notarized, stapled Release .app that already contains the smoke sentinel.\n"
    "\n"
    "Build the example first:\n"
    "  flutter build macos --debug\n"
    "  flutter build macos --release\n"
    "  flutter build windows --debug\n"
    "  flutter build windows --release\n"
    "  flutter build linux --debug\n"
    "  flutter build linux --release\n",
  );
}
