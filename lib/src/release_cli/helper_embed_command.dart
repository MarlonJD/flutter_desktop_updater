import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:args/args.dart";
import "package:path/path.dart" as path;

/// Build-phase entrypoint; policy generation remains a separate reviewed step.
ArgParser buildHelperEmbedParser() =>
    ArgParser()..addFlag("help", abbr: "h", negatable: false);

/// Resolves this installed package and embeds the reviewed policy during Xcode.
Future<int> runHelperEmbedCommand(
  ArgResults results, {
  required StringSink output,
  Map<String, String>? environment,
}) async {
  if (results["help"] as bool) {
    output.writeln(
        "Xcode build-phase entrypoint configured by release helper-policy.\n"
        "Uses the generated Runner policy and SHA-256 pin without regenerating them.");
    return 0;
  }
  if (results.rest.isNotEmpty) {
    throw const FormatException(
      "helper-embed does not accept positional arguments.",
    );
  }
  final env = Map<String, String>.of(environment ?? Platform.environment);
  if (!Platform.isMacOS ||
      [
        "XCODE_VERSION_ACTUAL",
        "PROJECT_DIR",
        "TARGET_BUILD_DIR",
        "CONTENTS_FOLDER_PATH",
      ].any((key) => (env[key] ?? "").isEmpty)) {
    throw const FormatException(
      "Run helper-embed from the Runner Xcode build phase configured by release helper-policy.",
    );
  }
  final library = await Isolate.resolvePackageUri(
    Uri.parse(
      "package:desktop_updater/src/release_cli/helper_embed_command.dart",
    ),
  );
  if (library == null || library.scheme != "file") {
    throw StateError(
      "Cannot resolve the installed desktop_updater package. Run flutter pub get.",
    );
  }
  final packageRoot = path.normalize(
    path.join(path.dirname(library.toFilePath()), "..", "..", ".."),
  );
  final helperRoot = path.join(packageRoot, "macos", "install_helper");
  const policyKey = "DESKTOP_UPDATER_SEALED_POLICY_PATH";
  const pinKey = "DESKTOP_UPDATER_SEALED_POLICY_SHA256";
  final hasPolicy = (env[policyKey] ?? "").isNotEmpty;
  final hasPin = (env[pinKey] ?? "").isNotEmpty;
  if (hasPolicy != hasPin) {
    throw const FormatException(
      "Custom helper policy path and SHA-256 pin must be provided together.",
    );
  }
  if (!hasPolicy) {
    final runner = path.join(env["PROJECT_DIR"]!, "Runner");
    env[policyKey] = path.join(runner, "DesktopUpdaterHelperPolicy.json");
    final digest = File(path.join(runner, "DesktopUpdaterHelperPolicy.sha256"));
    if (!await digest.exists()) {
      throw const FormatException(
        "Generated helper policy pin is missing. Run release helper-policy from your app directory and review its outputs.",
      );
    }
    // Read the reviewed pin verbatim (apart from its optional final newline).
    // Never derive this expected value from the policy being checked.
    env[pinKey] =
        (await digest.readAsString()).replaceFirst(RegExp(r"\r?\n$"), "");
  }
  env.putIfAbsent(
    "DESKTOP_UPDATER_HELPER_INFO_TEMPLATE",
    () => path.join(helperRoot, "Configuration", "Helper-Info.plist"),
  );
  final process = await Process.start(
    "/bin/sh",
    [path.join(helperRoot, "embed_install_helper.sh")],
    environment: env,
    includeParentEnvironment: false,
  );
  await Future.wait([
    process.stdout.transform(utf8.decoder).forEach(output.write),
    process.stderr.transform(utf8.decoder).forEach(output.write),
  ]);
  return process.exitCode;
}
