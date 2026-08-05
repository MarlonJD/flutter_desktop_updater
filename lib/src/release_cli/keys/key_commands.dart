import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_manager.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_signing_resolver.dart";
import "package:path/path.dart" as path;

/// Builds the first-run `release keygen` parser.
ArgParser buildKeygenParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("config", help: "Path to desktop_updater.yaml.")
    ..addOption("base-url", help: "Override updates.baseUrl.")
    ..addOption(
      "key-profile",
      help: "Public profile path; defaults to desktop_updater.keys.json.",
    );
}

/// Builds the lifecycle parser for `release keys ...`.
ArgParser buildKeysParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addCommand("show", _profileCommandParser())
    ..addCommand("export", _exportParser())
    ..addCommand("import", _importParser())
    ..addCommand("adopt", _adoptParser())
    ..addCommand("rotate", _profileCommandParser())
    ..addCommand("activate", _profileCommandParser());
}

Future<int> runKeygenCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
  ReleaseKeySecretStore? keyStore,
}) async {
  if (results["help"] as bool) {
    output.writeln(buildKeygenParser().usage);
    return 0;
  }
  final config = await _loadConfig(
    projectRoot: projectRoot,
    configPath: results["config"] as String?,
    baseUrl: results["base-url"] as String?,
  );
  final manager = _manager(
    projectRoot: projectRoot,
    feedUrl: config.baseUrl.resolve("app-archive.json"),
    profileValue: results["key-profile"] as String?,
    keyStore: keyStore,
  );
  await manager.keygen(output);
  return 0;
}

Future<int> runKeysCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
  Map<String, String>? environment,
  ReleaseKeySecretStore? keyStore,
}) async {
  if (results["help"] as bool || results.command == null) {
    output.writeln(buildKeysParser().usage);
    return 0;
  }
  final command = results.command!;
  final child = command.command;
  if (child == null || (child["help"] as bool)) {
    output.writeln(buildKeysParser().usage);
    return 0;
  }
  switch (command.name) {
    case "show":
      final manager = await _managerFromProfileCommand(
        child,
        projectRoot: projectRoot,
        keyStore: keyStore,
      );
      await manager.show(output);
      return 0;
    case "export":
      final config = await _loadConfigFromResults(projectRoot, child);
      final manager = _manager(
        projectRoot: projectRoot,
        feedUrl: config.baseUrl.resolve("app-archive.json"),
        profileValue: child["key-profile"] as String?,
        keyStore: keyStore,
      );
      final publicOnly = child["public-only"] as bool;
      final passphrase = publicOnly
          ? null
          : await _readPassphrase(
              child,
              environment ?? Platform.environment,
              output,
            );
      await manager.export(
        outputFile: _resolveFile(projectRoot, child["output"] as String?),
        passphrase: passphrase ?? "unused-public-export",
        publicOnly: publicOnly,
        force: child["force"] as bool,
      );
      output.writeln(
        publicOnly
            ? "Exported public release key profile."
            : "Exported encrypted release key bundle.",
      );
      return 0;
    case "import":
      final config = await _loadConfigFromResults(projectRoot, child);
      final manager = _manager(
        projectRoot: projectRoot,
        feedUrl: config.baseUrl.resolve("app-archive.json"),
        profileValue: child["key-profile"] as String?,
        keyStore: keyStore,
      );
      final passphrase = await _readPassphrase(
        child,
        environment ?? Platform.environment,
        output,
      );
      await manager.importBundle(
        inputFile: _resolveFile(projectRoot, child["input"] as String),
        passphrase: passphrase,
        output: output,
      );
      return 0;
    case "adopt":
      final config = await _loadConfigFromResults(projectRoot, child);
      final material = await readDirectReleaseSigningMaterial(
        results: child,
        projectRoot: projectRoot,
        environment: environment ?? Platform.environment,
        requirePublicKeys: true,
      );
      final manager = _manager(
        projectRoot: projectRoot,
        feedUrl: config.baseUrl.resolve("app-archive.json"),
        profileValue: child["key-profile"] as String?,
        keyStore: keyStore,
      );
      await manager.adopt(
        publicKeyId: material.publicKeyId,
        privateKeyBase64: base64Encode(material.privateSeed),
        trustedPublicKeys: material.trustedPublicKeys,
        output: output,
      );
      return 0;
    case "rotate":
      final manager = await _managerFromProfileCommand(
        child,
        projectRoot: projectRoot,
        keyStore: keyStore,
      );
      await manager.rotate(output);
      return 0;
    case "activate":
      final manager = await _managerFromProfileCommand(
        child,
        projectRoot: projectRoot,
        keyStore: keyStore,
      );
      await manager.activate(output);
      return 0;
  }
  throw FormatException("Unsupported key command: ${command.name}.");
}

ArgParser _profileCommandParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("config", help: "Path to desktop_updater.yaml.")
    ..addOption("base-url", help: "Override updates.baseUrl.")
    ..addOption("key-profile", help: "Public profile path.");
}

ArgParser _exportParser() {
  return _profileCommandParser()
    ..addOption("output", help: "Output path for the public profile or bundle.")
    ..addFlag("public-only", negatable: false)
    ..addOption(
      "passphrase-env",
      help: "Environment variable containing the bundle passphrase.",
    )
    ..addFlag("force", negatable: false);
}

ArgParser _importParser() {
  return _profileCommandParser()
    ..addOption("input", help: "Encrypted release key bundle path.")
    ..addOption(
      "passphrase-env",
      help: "Environment variable containing the bundle passphrase.",
    );
}

ArgParser _adoptParser() {
  return _profileCommandParser()
    ..addOption("public-key-id")
    ..addOption("private-key-env")
    ..addOption("private-key-file")
    ..addOption("public-keys-env");
}

Future<ReleaseKeyManager> _managerFromProfileCommand(
  ArgResults results, {
  required Directory projectRoot,
  ReleaseKeySecretStore? keyStore,
}) async {
  final config = await _loadConfigFromResults(projectRoot, results);
  return _manager(
    projectRoot: projectRoot,
    feedUrl: config.baseUrl.resolve("app-archive.json"),
    profileValue: results["key-profile"] as String?,
    keyStore: keyStore,
  );
}

ReleaseKeyManager _manager({
  required Directory projectRoot,
  required Uri feedUrl,
  required String? profileValue,
  required ReleaseKeySecretStore? keyStore,
}) {
  final profileFile = profileValue == null
      ? null
      : File(
          path.isAbsolute(profileValue)
              ? profileValue
              : path.join(projectRoot.path, profileValue),
        );
  return ReleaseKeyManager(
    projectRoot: projectRoot,
    feedUrl: feedUrl,
    profileFile: profileFile,
    store: keyStore,
  );
}

Future<ReleasePublishConfig> _loadConfigFromResults(
  Directory projectRoot,
  ArgResults results,
) {
  return _loadConfig(
    projectRoot: projectRoot,
    configPath: results["config"] as String?,
    baseUrl: results["base-url"] as String?,
  );
}

Future<ReleasePublishConfig> _loadConfig({
  required Directory projectRoot,
  required String? configPath,
  required String? baseUrl,
}) {
  return ReleasePublishConfig.load(
    projectRoot: projectRoot,
    cliOverrides: ReleasePublishOverrides(
      configPath: configPath,
      baseUrl: baseUrl,
    ),
  );
}

File _resolveFile(Directory projectRoot, String? value) {
  if (value == null || value.trim().isEmpty) {
    throw const FormatException("An input or output path is required.");
  }
  final trimmed = value.trim();
  return File(
    path.isAbsolute(trimmed) ? trimmed : path.join(projectRoot.path, trimmed),
  );
}

Future<String> _readPassphrase(
  ArgResults results,
  Map<String, String> environment,
  StringSink output,
) async {
  final envName = results["passphrase-env"] as String?;
  if (envName != null && envName.trim().isNotEmpty) {
    final value = environment[envName.trim()];
    if (value == null || value.runes.length < 12) {
      throw FormatException(
          "Missing or too-short environment variable ${envName.trim()}.");
    }
    return value;
  }
  if (!stdin.hasTerminal) {
    throw const FormatException(
      "Interactive passphrase input requires a terminal; use --passphrase-env.",
    );
  }
  if (Platform.isWindows) {
    throw const FormatException(
      "Use --passphrase-env on Windows; passphrases are never accepted as CLI arguments.",
    );
  }
  output.write("Bundle passphrase: ");
  await Process.run("stty", ["-echo"]);
  try {
    final value = stdin.readLineSync() ?? "";
    output.writeln();
    output.write("Confirm bundle passphrase: ");
    final confirmation = stdin.readLineSync() ?? "";
    output.writeln();
    if (value != confirmation)
      throw const FormatException("Passphrases do not match.");
    if (value.runes.length < 12)
      throw const FormatException("Passphrase is too short.");
    return value;
  } finally {
    await Process.run("stty", ["echo"]);
  }
}
