import "dart:async";
import "dart:io";

Future<void> main(List<String> args) async {
  final relaunch = args.contains("--relaunch");
  final productionGates = args.contains("--production-gates");
  final appPath = _absolutePath(_argValue(args, "--app") ?? _defaultAppPath());
  final appArchiveUrl = _argValue(args, "--app-archive-url");

  if (appPath == null ||
      appArchiveUrl == null ||
      appArchiveUrl.trim().isEmpty) {
    _usage();
    exit(64);
  }

  final executablePath = _executablePath(appPath);
  if (!File(executablePath).existsSync()) {
    stderr.writeln("Executable not found: $executablePath");
    _usage();
    exit(66);
  }

  if (productionGates && Platform.isMacOS) {
    await _runMacOSProductionGate(appPath, "installed app");
  }

  final installedSentinel = File(
    Platform.isMacOS && appPath.endsWith(".app")
        ? _joinAll([
            appPath,
            "Contents",
            "Resources",
            "desktop_updater_smoke.txt",
          ])
        : _join(File(appPath).parent.path, "desktop_updater_smoke.txt"),
  );
  if (installedSentinel.existsSync()) {
    stderr.writeln(
      "Installed app already contains ${installedSentinel.path}; refusing "
      "to start a hosted smoke from an already-updated app.",
    );
    exit(65);
  }

  final tempRoot = await Directory.systemTemp.createTemp(
    "desktop_updater_hosted_smoke_",
  );
  final markerPath = _join(tempRoot.path, "marker.txt");

  stdout
    ..writeln("Launching $executablePath")
    ..writeln("Hosted app archive: $appArchiveUrl")
    ..writeln("Hosted smoke marker: $markerPath");

  final process = await Process.start(
    executablePath,
    const [],
    environment: {
      "DESKTOP_UPDATER_APP_ARCHIVE_URL": appArchiveUrl.trim(),
      "DESKTOP_UPDATER_HOSTED_SMOKE": "1",
      "DESKTOP_UPDATER_HOSTED_SMOKE_MARKER": markerPath,
      if (!productionGates) "DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS": "1",
      if (!relaunch) "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1",
    },
    mode: ProcessStartMode.normal,
    workingDirectory: File(executablePath).parent.path,
  );

  process.stdout.listen(stdout.add);
  process.stderr.listen(stderr.add);

  await _waitForFileText(markerPath, "checking", const Duration(seconds: 15));
  await _waitForFileText(
    markerPath,
    "downloading",
    const Duration(seconds: 45),
  );
  await _waitForFileText(markerPath, "installing", const Duration(seconds: 45));
  stdout.writeln("Hosted app scheduled native installation and is closing...");

  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 45),
    onTimeout: () {
      process.kill();
      throw TimeoutException(
        "App did not exit after scheduling hosted update.",
      );
    },
  );

  stdout.writeln("Initial hosted app process exited with code $exitCode");

  await _waitFor(
    installedSentinel.existsSync,
    const Duration(seconds: 60),
    "Timed out waiting for hosted update sentinel at ${installedSentinel.path}",
  );

  if (productionGates && Platform.isMacOS) {
    await _runMacOSProductionGate(appPath, "updated app");
  }

  stdout
    ..writeln("Hosted smoke update installed: ${installedSentinel.path}")
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
      "Release",
      "desktop_updater_example.app",
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

Future<void> _waitForFileText(
  String filePath,
  String expected,
  Duration timeout,
) async {
  await _waitFor(
    () =>
        File(filePath).existsSync() &&
        markerHasReached(File(filePath).readAsStringSync().trim(), expected),
    timeout,
    "Timed out waiting for hosted smoke marker '$expected'.",
  );
}

bool markerHasReached(String actual, String expected) {
  if (actual.startsWith("failed:")) {
    return false;
  }

  const markerOrder = ["checking", "downloading", "installing"];
  final actualIndex = markerOrder.indexOf(actual);
  final expectedIndex = markerOrder.indexOf(expected);
  if (actualIndex == -1 || expectedIndex == -1) {
    return actual == expected;
  }

  return actualIndex >= expectedIndex;
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

Future<void> _runMacOSProductionGate(String appPath, String label) async {
  stdout.writeln("Validating $label production gates...");
  await _runChecked("/usr/bin/codesign", [
    "--verify",
    "--deep",
    "--strict",
    "--verbose=2",
    appPath,
  ]);
  await _runChecked("/usr/sbin/spctl", [
    "--assess",
    "--type",
    "execute",
    "--verbose=4",
    appPath,
  ]);
  await _runChecked("/usr/bin/xcrun", ["stapler", "validate", appPath]);
}

Future<void> _runChecked(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
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

String? _absolutePath(String? path) {
  if (path == null) {
    return null;
  }
  return File(path).absolute.path;
}

void _usage() {
  stderr.writeln(
    "Usage: dart run tool/hosted_update_smoke.dart --app <path> "
    "--app-archive-url <url> [--production-gates] [--relaunch]\n"
    "\n"
    "Use --production-gates on macOS with signed, notarized, stapled Release "
    ".app bundles.",
  );
}
