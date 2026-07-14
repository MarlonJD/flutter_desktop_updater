import "dart:convert";
import "dart:io";

Future<void> main(List<String> arguments) async {
  try {
    if (!Platform.isMacOS) {
      throw StateError("macOS install-helper smoke requires a macOS host");
    }
    final mode = _option(arguments, "--mode");
    switch (mode) {
      case "unprivileged":
        await _runUnprivileged();
      case "privileged":
        await _runPrivileged();
      default:
        throw const UsageException(
          "Usage: dart run tool/macos_install_helper_smoke.dart "
          "--mode <unprivileged|privileged>",
        );
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = error is UsageException ? 64 : 1;
  }
}

Future<void> _runUnprivileged() async {
  final root = _repositoryRoot();
  await _runChecked(
    "swift",
    [
      "test",
      "--package-path",
      "macos/install_helper",
      "--filter",
      "MacFileTransactionTests.testUnprivilegedSmoke",
    ],
    workingDirectory: root.path,
  );
  await _runChecked(
    "swift",
    [
      "test",
      "--package-path",
      "macos/install_helper",
      "--filter",
      "HelperVersionTests.testBuiltHelperExecutableParsesCanonicalRequest",
    ],
    workingDirectory: root.path,
  );
  stdout.writeln(
    jsonEncode({
      "schemaVersion": 1,
      "mode": "unprivileged",
      "canonicalProtocolParsed": true,
      "recoverableSwapExecuted": true,
    }),
  );
}

Future<void> _runPrivileged() async {
  final app = FileSystemEntity.typeSync(_requiredEnvironment("APP")) ==
          FileSystemEntityType.directory
      ? Directory(_requiredEnvironment("APP"))
      : throw StateError("SMJobBless smoke app is not a directory");
  final host = File(_requiredEnvironment("HOST"));
  final serviceIdentifier =
      Platform.environment["DESKTOP_UPDATER_SMJOBBLESS_SERVICE_ID"] ??
          "com.example.desktop-updater.helper";
  if (!host.existsSync()) {
    throw StateError("SMJobBless smoke host executable does not exist");
  }

  final oneShot = File(
    "${app.path}/Contents/Helpers/DesktopUpdaterInstallHelper",
  );
  final privileged = File(
    "${app.path}/Contents/Library/LaunchServices/$serviceIdentifier",
  );
  if (!oneShot.existsSync() || !privileged.existsSync()) {
    throw StateError("signed app is missing one or both fixed helper payloads");
  }
  final oneShotBytes = await oneShot.readAsBytes();
  final privilegedBytes = await privileged.readAsBytes();
  if (oneShotBytes.isEmpty ||
      !_constantTimeEquals(oneShotBytes, privilegedBytes)) {
    throw StateError(
      "one-shot and SMJobBless helper payloads are not identical",
    );
  }

  await _runChecked("/usr/bin/codesign", [
    "--verify",
    "--deep",
    "--strict",
    "--verbose=2",
    app.path,
  ]);
  await _runChecked("/usr/bin/codesign", [
    "--verify",
    "--strict",
    "--verbose=2",
    oneShot.path,
  ]);
  await _runChecked("/usr/bin/codesign", [
    "--verify",
    "--strict",
    "--verbose=2",
    privileged.path,
  ]);

  final hostResult = await _runChecked(
    host.path,
    [
      "--desktop-updater-smjobbless-smoke",
      "--service-id",
      serviceIdentifier,
    ],
  );
  final evidence = _lastJsonObject(hostResult.stdout as String);
  if (evidence["schemaVersion"] != 1 ||
      evidence["mode"] != "privileged" ||
      evidence["serviceIdentifier"] != serviceIdentifier ||
      evidence["blessedHelperExecuted"] != true ||
      evidence["authenticatedXPC"] != true ||
      evidence["recoveredSwap"] != true) {
    throw StateError("privileged host returned incomplete smoke evidence");
  }
  await _runChecked(
    "/bin/launchctl",
    ["print", "system/$serviceIdentifier"],
  );
  stdout.writeln(jsonEncode(evidence));
}

String _requiredEnvironment(String suffix) {
  final name = "DESKTOP_UPDATER_SMJOBBLESS_SMOKE_$suffix";
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError("missing required environment variable $name");
  }
  return value;
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    return null;
  }
  return arguments[index + 1];
}

Directory _repositoryRoot() {
  var candidate = File.fromUri(Platform.script).parent.parent;
  while (candidate.parent.path != candidate.path) {
    if (File("${candidate.path}/pubspec.yaml").existsSync() &&
        Directory("${candidate.path}/macos/install_helper").existsSync()) {
      return candidate;
    }
    candidate = candidate.parent;
  }
  throw StateError("could not locate repository root");
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if ((result.stdout as String).isNotEmpty) {
    stdout.write(result.stdout);
  }
  if ((result.stderr as String).isNotEmpty) {
    stderr.write(result.stderr);
  }
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "command exited with ${result.exitCode}",
      result.exitCode,
    );
  }
  return result;
}

Map<String, Object?> _lastJsonObject(String output) {
  for (final line in output.split("\n").reversed) {
    final candidate = line.trim();
    if (!candidate.startsWith("{")) {
      continue;
    }
    final value = jsonDecode(candidate);
    if (value is Map<String, Object?>) {
      return value;
    }
  }
  throw const FormatException("host did not emit JSON smoke evidence");
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

final class UsageException implements Exception {
  const UsageException(this.message);

  final String message;

  @override
  String toString() => message;
}
