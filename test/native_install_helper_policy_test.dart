import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  const schemaPath = "schemas/native-install-helper-policy-v1.schema.json";
  const fixturePath =
      "fixtures/compat/native-install-helper/v1/policy-cases.json";
  const generatorPath = "tool/generate_native_install_helper_policy.dart";

  test("sealed policy schema, generator, fixtures, and C++ parser exist", () {
    for (final requiredPath in <String>[
      schemaPath,
      fixturePath,
      generatorPath,
      "native_runtime/cpp/install_helper_policy.h",
      "native_runtime/cpp/install_helper_policy.cc",
      "native_runtime/cpp/install_helper_policy_fixture_tests.cc",
    ]) {
      expect(
        File(requiredPath).existsSync(),
        isTrue,
        reason: "$requiredPath must exist",
      );
    }
  });

  test("policy schema seals every authority-bearing object", () async {
    final schema = await _readJson(schemaPath);
    expect(schema[r"$schema"], contains("2020-12"));
    expect(schema["additionalProperties"], isFalse);
    expect(
      (schema["required"] as List).cast<String>().toSet(),
      <String>{
        "policyVersion",
        "policyId",
        "applicationPackageId",
        "helperServiceId",
        "allowedApplicationSigner",
        "allowedHelperSigner",
        "allowedTargetClasses",
        "allowedInstallRoots",
        "releaseRootPublicKeys",
        "allowedStrategies",
        "minimumHelperProtocolVersion",
      },
    );
    final definitions = Map<String, dynamic>.from(schema[r"$defs"] as Map);
    for (final name in <String>[
      "signer",
      "releaseRootPublicKey",
      "allowedStrategy",
    ]) {
      expect(
        Map<String, dynamic>.from(
          definitions[name] as Map,
        )["additionalProperties"],
        isFalse,
        reason: "${r"$defs"}.$name must reject unknown fields",
      );
    }
  });

  test("policy fixtures are deterministic and cover required attacks",
      () async {
    final root = await Directory.systemTemp.createTemp("helper_policy_");
    try {
      final first = File(path.join(root.path, "first.json"));
      final second = File(path.join(root.path, "second.json"));
      await _runGenerator(
        generatorPath,
        <String>["--fixture-output", first.path],
      );
      await _runGenerator(
        generatorPath,
        <String>["--fixture-output", second.path],
      );
      expect(await first.readAsBytes(), await second.readAsBytes());
      expect(await first.readAsBytes(), await File(fixturePath).readAsBytes());
    } finally {
      await root.delete(recursive: true);
    }

    final fixture = await _readJson(fixturePath);
    expect(
      _mapList(fixture, "cases").map((entry) => entry["name"]).toSet(),
      containsAll(<String>{
        "valid portable policy",
        "valid privileged policy",
        "wrong package ID",
        "unknown strategy",
        "root filesystem authorization",
        "relative install root",
        "caller-added release key authority",
        "policy rollback",
        "invalid signer",
        "duplicate release key ID",
        "protocol downgrade",
        "portable policy requests elevation",
        "external refresh without named provider",
      }),
    );
  });

  test("Dart policy validator matches every generated case", () async {
    final fixture = await _readJson(fixturePath);
    for (final entry in _mapList(fixture, "cases")) {
      final root = await Directory.systemTemp.createTemp("policy_case_");
      try {
        final input = File(path.join(root.path, "policy.json"));
        await input.writeAsString(jsonEncode(entry["policy"]));
        final result = await _runGeneratorResult(generatorPath, <String>[
          "--validate",
          input.path,
          "--expected-package-id",
          entry["expectedPackageId"] as String,
          "--minimum-policy-version",
          (entry["minimumAcceptedPolicyVersion"] as int).toString(),
        ]);
        if (entry["expectedValid"] as bool) {
          expect(
            result.exitCode,
            0,
            reason: _processReason(entry["name"] as String, result),
          );
          expect((result.stdout as String).trim(), entry["canonicalSha256"]);
          expect(result.stderr, isEmpty);
        } else {
          expect(
            result.exitCode,
            1,
            reason: _processReason(entry["name"] as String, result),
          );
          expect(result.stdout, isEmpty);
          expect(
            (result.stderr as String).trim(),
            entry["expectedFailure"],
            reason: entry["name"] as String,
          );
        }
      } finally {
        await root.delete(recursive: true);
      }
    }
  });

  test("build-time generation writes only canonical policy and digest",
      () async {
    final fixture = await _readJson(fixturePath);
    final valid = _mapList(fixture, "cases")
        .singleWhere((entry) => entry["name"] == "valid privileged policy");
    final root = await Directory.systemTemp.createTemp("policy_generate_");
    try {
      final config = File(path.join(root.path, "config.json"));
      final output = File(path.join(root.path, "policy.json"));
      final digest = File(path.join(root.path, "policy.json.sha256"));
      await config.writeAsString(jsonEncode(valid["policy"]));
      await _runGenerator(generatorPath, <String>[
        "--config",
        config.path,
        "--output",
        output.path,
        "--digest-output",
        digest.path,
        "--expected-package-id",
        "com.example.app",
        "--minimum-policy-version",
        "1",
      ]);

      final bytes = await output.readAsBytes();
      final text = utf8.decode(bytes);
      expect(text, endsWith("\n"));
      expect(text.trim(), valid["canonicalJson"]);
      expect(
        crypto.sha256.convert(utf8.encode(text.trim())).toString(),
        valid["canonicalSha256"],
      );
      expect((await digest.readAsString()).trim(), valid["canonicalSha256"]);
      expect(text, isNot(contains("privateKey")));
      expect(text, isNot(contains("passphrase")));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("common C++ policy parser remains non-destructive", () {
    final source = File(
      "native_runtime/cpp/install_helper_policy.cc",
    ).readAsStringSync();
    for (final forbidden in <String>[
      "<filesystem>",
      "<fstream>",
      "std::filesystem",
      "std::remove(",
      "std::rename(",
      "CreateFile",
      "DeleteFile",
      "ShellExecute",
      " open(",
      " unlink(",
      " rename(",
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}

Future<void> _runGenerator(String generatorPath, List<String> arguments) async {
  final result = await _runGeneratorResult(generatorPath, arguments);
  expect(result.exitCode, 0, reason: _processReason("generator", result));
}

Future<ProcessResult> _runGeneratorResult(
  String generatorPath,
  List<String> arguments,
) {
  final executableName = Platform.isWindows ? "dart.exe" : "dart";
  final flutterRoot = Platform.environment["FLUTTER_ROOT"];
  var executable = executableName;
  if (flutterRoot != null) {
    executable = path.join(
      flutterRoot,
      "bin",
      "cache",
      "dart-sdk",
      "bin",
      executableName,
    );
  } else {
    for (final directory in (Platform.environment["PATH"] ?? "")
        .split(Platform.isWindows ? ";" : ":")) {
      final wrapper = File(path.join(directory, executableName));
      if (!wrapper.existsSync()) {
        continue;
      }
      final candidate = path.join(
        Directory(directory).parent.path,
        "bin",
        "cache",
        "dart-sdk",
        "bin",
        executableName,
      );
      executable = File(candidate).existsSync() ? candidate : wrapper.path;
      break;
    }
  }
  return Process.run(
    executable,
    <String>[generatorPath, ...arguments],
    environment: <String, String>{
      ...Platform.environment,
      "DART_TOOL_DISABLE_ANALYTICS": "1",
    },
  );
}

String _processReason(String name, ProcessResult result) {
  return "$name\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}";
}

Future<Map<String, dynamic>> _readJson(String filePath) async {
  return Map<String, dynamic>.from(
    jsonDecode(await File(filePath).readAsString()) as Map,
  );
}

List<Map<String, dynamic>> _mapList(
  Map<String, dynamic> source,
  String key,
) {
  return (source[key] as List)
      .map((entry) => Map<String, dynamic>.from(entry as Map))
      .toList();
}
