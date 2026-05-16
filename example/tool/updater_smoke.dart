import "dart:async";
import "dart:io";

Future<void> main(List<String> args) async {
  final relaunch = args.contains("--relaunch");
  final appPath = _argValue(args, "--app") ?? _defaultAppPath();

  if (appPath == null) {
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
  final stagingRoot = Directory(_join(tempRoot.path, "stage"));
  final markerPath = _join(tempRoot.path, "marker.txt");
  final sentinelRelativePath = Platform.isMacOS
      ? _join("Resources", "desktop_updater_smoke.txt")
      : "desktop_updater_smoke.txt";
  final stagedSentinel = File(_join(stagingRoot.path, sentinelRelativePath));
  final installedSentinel = File(_join(installRoot, sentinelRelativePath));

  if (installedSentinel.existsSync()) {
    installedSentinel.deleteSync();
  }

  await stagedSentinel.parent.create(recursive: true);
  await stagedSentinel.writeAsString(
    "desktop_updater smoke ${DateTime.now().toIso8601String()}",
  );

  stdout
    ..writeln("Launching $executablePath")
    ..writeln("Staging update in ${stagingRoot.path}");

  final process = await Process.start(
    executablePath,
    const [],
    environment: {
      "DESKTOP_UPDATER_SMOKE_STAGING": stagingRoot.path,
      "DESKTOP_UPDATER_SMOKE_MARKER": markerPath,
      if (!relaunch) "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1",
    },
    mode: ProcessStartMode.normal,
    workingDirectory: File(executablePath).parent.path,
  );

  unawaited(stdout.addStream(process.stdout));
  unawaited(stderr.addStream(process.stderr));

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

  stdout
    ..writeln("Smoke update installed: ${installedSentinel.path}")
    ..writeln(
      relaunch
          ? "Relaunch was enabled; close the relaunched example app manually."
          : "Relaunch was skipped for test cleanup. Pass --relaunch to test it.",
    );
}

String? _defaultAppPath() {
  if (Platform.isMacOS) {
    return _joinAll([
      "build",
      "macos",
      "Build",
      "Products",
      "Debug",
      "desktop_updater_example.app",
    ]);
  }

  if (Platform.isWindows) {
    return _joinAll([
      "build",
      "windows",
      "x64",
      "runner",
      "Debug",
      "desktop_updater_example.exe",
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

void _usage() {
  stderr.writeln(
    "Usage: dart run tool/updater_smoke.dart [--app <path>] [--relaunch]\n"
    "\n"
    "Build the example first:\n"
    "  flutter build macos --debug\n"
    "  flutter build windows --debug\n",
  );
}
