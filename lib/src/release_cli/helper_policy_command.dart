import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/native_install_helper/policy.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_signing_resolver.dart";
import "package:path/path.dart" as path;

/// Builds the consumer-facing macOS helper policy command.
ArgParser buildHelperPolicyParser() => ArgParser()
  ..addFlag("help", abbr: "h", negatable: false)
  ..addOption(
    "team-id",
    help: "Apple Team ID for a new policy (10 uppercase letters/digits).",
  )
  ..addOption(
    "package-id",
    help: "App bundle ID; defaults to macos/Runner/Configs/AppInfo.xcconfig.",
  )
  ..addOption(
    "helper-service-id",
    help: "New helper identifier; defaults to <package-id>.helper.",
  )
  ..addOption(
    "config",
    help: "Publishing config; defaults to desktop_updater.yaml.",
  )
  ..addOption(
    "base-url",
    help: "Override updates.baseUrl for the public key profile check.",
  )
  ..addOption(
    "key-profile",
    help: "Public key profile; defaults to desktop_updater.keys.json.",
  );

/// Creates or regenerates the app-owned sealed policy without accessing secrets.
Future<int> runHelperPolicyCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
}) async {
  if (results["help"] as bool) {
    output.writeln("Run from your Flutter app directory:\n"
        "  dart run desktop_updater:release helper-policy --team-id ABC1234567\n\n"
        "Existing source policies are preserved. After editing the source, run:\n"
        "  dart run desktop_updater:release helper-policy\n\n"
        "${buildHelperPolicyParser().usage}");
    return 0;
  }
  if (results.rest.isNotEmpty) {
    throw const FormatException(
      "helper-policy does not accept positional arguments.",
    );
  }
  final runner = Directory(path.join(projectRoot.path, "macos", "Runner"));
  if (!await runner.exists()) {
    throw const FormatException(
      "Run helper-policy from your Flutter app root; macos/Runner is missing.",
    );
  }
  final settings = await readMacosAppInfo(projectRoot);
  final packageId =
      _option(results, "package-id") ?? settings["PRODUCT_BUNDLE_IDENTIFIER"];
  if (packageId == null || !_bundleId.hasMatch(packageId)) {
    throw const FormatException(
        "A literal macOS bundle ID is required. Set PRODUCT_BUNDLE_IDENTIFIER "
        "in AppInfo.xcconfig or pass --package-id com.example.app.");
  }

  final source =
      File(path.join(runner.path, "DesktopUpdaterHelperPolicy.source.json"));
  final sealed =
      File(path.join(runner.path, "DesktopUpdaterHelperPolicy.json"));
  final digest =
      File(path.join(runner.path, "DesktopUpdaterHelperPolicy.sha256"));
  for (final file in [source, sealed, digest]) {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException(
        "Helper policy path must be a regular file, not a link or directory.",
        file.path,
      );
    }
  }

  final sourceExists = await source.exists();
  final sealedExists = await sealed.exists();
  late final String sourceText;
  if (sourceExists || sealedExists) {
    sourceText = await (sourceExists ? source : sealed).readAsString();
    output.writeln(
      sourceExists
          ? "Using existing source policy: ${source.path}"
          : "Preserving existing policy as the source: ${source.path}",
    );
    if (["team-id", "helper-service-id", "key-profile"]
        .any(results.wasParsed)) {
      output.writeln(
        "Initialization options do not replace an existing policy. Edit the source to change its authority.",
      );
    }
  } else {
    final teamId = _option(results, "team-id");
    if (teamId == null || !RegExp(r"^[A-Z0-9]{10}$").hasMatch(teamId)) {
      throw const FormatException(
        "Creating a policy requires --team-id with your 10-character Apple Team ID.",
      );
    }
    final helperId =
        _option(results, "helper-service-id") ?? "$packageId.helper";
    if (!_bundleId.hasMatch(helperId) || helperId == packageId) {
      throw const FormatException(
        "--helper-service-id must be a literal helper identifier distinct from the app bundle ID.",
      );
    }
    final configPath = _option(results, "config");
    final config = await ReleasePublishConfig.load(
      projectRoot: projectRoot,
      cliOverrides: ReleasePublishOverrides(
        configPath: configPath == null
            ? null
            : path.absolute(path.join(projectRoot.path, configPath)),
        baseUrl: _option(results, "base-url"),
      ),
    );
    final publicKeys = (await resolveReleasePublicKeys(
      results: results,
      projectRoot: projectRoot,
      expectedFeedUrl: config.baseUrl.resolve("app-archive.json"),
      candidateOnly: false,
    ))!;
    sourceText = "${const JsonEncoder.withIndent("  ").convert({
          "policyVersion": 1,
          "policyId": "$packageId.install-policy",
          "applicationPackageId": packageId,
          "helperServiceId": helperId,
          "allowedApplicationSigner": _signer(packageId, teamId),
          "allowedHelperSigner": _signer(helperId, teamId),
          "allowedTargetClasses": ["applicationBundle"],
          "allowedInstallRoots": ["/Applications"],
          "releaseRootPublicKeys": [
            for (final entry in publicKeys.entries)
              {
                "keyId": entry.key,
                "algorithm": "ed25519",
                "publicKeyBase64": entry.value,
              },
          ],
          "allowedStrategies": [
            {"strategy": "directoryReplace", "provider": "platformDirectory"},
          ],
          "minimumHelperProtocolVersion": 1,
        })}\n";
  }

  final policy = validateHelperPolicyJson(
    sourceText,
    expectedApplicationPackageId: packageId,
    minimumAcceptedPolicyVersion: 1,
  );
  // Validate every input before writing. Commit the pin last so an interrupted
  // regeneration fails closed in the embed script's exact digest comparison.
  if (!sourceExists) await _writeAtomically(source, sourceText);
  await _writeAtomically(sealed, "${policy.canonicalJson}\n");
  await _writeAtomically(digest, "${policy.canonicalSha256}\n");
  output.writeln("Generated ${sealed.path}\nGenerated ${digest.path}\n"
      "Policy SHA-256: ${policy.canonicalSha256}\n"
      "Review and commit the source JSON and generated JSON/SHA-256 pair.\n"
      "Configure Runner's helper build phase as shown in the macOS Setup guide.\n"
      "New policies support ZIP/DMG bundle replacement in writable /Applications; "
      "privileged and PKG installs require an explicitly reviewed source policy.");
  return 0;
}

Map<String, String> _signer(String identifier, String teamId) => {
      "kind": "appleDesignatedRequirement",
      "value":
          'identifier "$identifier" and anchor apple generic and certificate leaf[subject.OU] = "$teamId"',
    };

String? _option(ArgResults results, String name) {
  final value = results[name] as String?;
  if (value == null) return null;
  if (value.trim().isEmpty) throw FormatException("--$name must not be blank.");
  return value.trim();
}

final _bundleId = RegExp(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$");

Future<void> _writeAtomically(File file, String contents) async {
  if (await file.exists() && await file.readAsString() == contents) return;
  final temp = await file.parent.createTemp(".desktop-updater-policy-");
  try {
    final pending = File(path.join(temp.path, "policy"));
    await pending.writeAsString(contents, flush: true);
    await pending.rename(file.path);
  } finally {
    await temp.delete(recursive: true);
  }
}
