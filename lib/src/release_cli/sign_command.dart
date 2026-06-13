import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:path/path.dart" as path;

ArgParser buildSignParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("release", help: "Path to the release.json file to sign.")
    ..addOption("public-key-id", help: "Pinned public key id to write.")
    ..addOption(
      "private-key-env",
      help: "Environment variable containing base64 raw Ed25519 private seed.",
    )
    ..addOption(
      "private-key-file",
      help: "External file containing base64 raw Ed25519 private seed.",
    );
}

Future<int> runSignCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
  Map<String, String>? environment,
}) async {
  if (results["help"] as bool) {
    output.writeln(buildSignParser().usage);
    return 0;
  }

  final releaseFile = _resolveFile(
    projectRoot: projectRoot,
    value: _required(results, "release"),
  );
  final publicKeyId = _required(results, "public-key-id");
  final privateKey = await _readPrivateKey(
    results: results,
    projectRoot: projectRoot,
    environment: environment ?? Platform.environment,
  );

  await ReleaseDescriptorSigner().sign(
    releaseFile: releaseFile,
    publicKeyId: publicKeyId,
    privateKeyBase64: privateKey,
  );

  output
    ..writeln("Signed release descriptor:")
    ..writeln(releaseFile.path)
    ..writeln()
    ..writeln("Public key id:")
    ..writeln(publicKeyId);
  return 0;
}

class ReleaseDescriptorSigner {
  ReleaseDescriptorSigner({Ed25519? algorithm})
      : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  Future<void> sign({
    required File releaseFile,
    required String publicKeyId,
    required String privateKeyBase64,
  }) async {
    final seed = _decodePrivateSeed(privateKeyBase64);
    final json = jsonDecode(await releaseFile.readAsString());
    if (json is! Map<String, dynamic>) {
      throw const FormatException("release.json must be a JSON object.");
    }

    final descriptorToSign = ReleaseDescriptor.fromJson({
      ...json,
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": publicKeyId,
        "value": "",
      },
    });
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final signature = await _algorithm.sign(
      descriptorToSign.canonicalSignatureBytes(),
      keyPair: keyPair,
    );
    final signedJson = descriptorToSign.toJson()
      ..["signature"] = ReleaseSignature(
        algorithm: "ed25519",
        publicKeyId: publicKeyId,
        value: base64Encode(signature.bytes),
      ).toJson();

    await releaseFile.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(signedJson)}\n",
    );
  }

  List<int> _decodePrivateSeed(String value) {
    final seed = base64Decode(value.trim());
    if (seed.length != 32) {
      throw const FormatException(
        "Ed25519 private key must be 32 raw bytes encoded as base64.",
      );
    }
    return seed;
  }
}

Future<String> _readPrivateKey({
  required ArgResults results,
  required Directory projectRoot,
  required Map<String, String> environment,
}) async {
  final envName = results["private-key-env"] as String?;
  final filePath = results["private-key-file"] as String?;
  final hasEnv = envName != null && envName.trim().isNotEmpty;
  final hasFile = filePath != null && filePath.trim().isNotEmpty;
  if (hasEnv == hasFile) {
    throw const FormatException(
      "Provide exactly one of --private-key-env or --private-key-file.",
    );
  }

  if (hasEnv) {
    final value = environment[envName!.trim()];
    if (value == null || value.trim().isEmpty) {
      throw FormatException("Missing environment variable ${envName.trim()}.");
    }
    return value;
  }

  final keyFile = _resolveFile(projectRoot: projectRoot, value: filePath!);
  return keyFile.readAsString();
}

File _resolveFile({
  required Directory projectRoot,
  required String value,
}) {
  final expanded = value.trim();
  if (path.isAbsolute(expanded)) {
    return File(expanded);
  }
  return File(path.join(projectRoot.path, expanded));
}

String _required(ArgResults results, String name) {
  final value = results[name] as String?;
  if (value == null || value.trim().isEmpty) {
    throw FormatException("Missing --$name.");
  }
  return value.trim();
}
