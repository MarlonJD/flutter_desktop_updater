import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:path/path.dart" as path;

import "package:desktop_updater/src/native_install_helper/canonical_json.dart";
import "package:desktop_updater/src/native_install_helper/policy.dart";

const nativeInstallHelperPolicyFixturePath =
    "fixtures/compat/native-install-helper/v1/policy-cases.json";

const _jsonEncoder = JsonEncoder.withIndent("  ");
const _shaA =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const _shaB =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

Future<void> main(List<String> arguments) async {
  try {
    await _run(arguments);
  } on HelperPolicyValidationFailure catch (error) {
    stderr.writeln(error.code);
    exitCode = 1;
  } on NativeInstallHelperContractFailure catch (error) {
    stderr.writeln(error.code);
    exitCode = 1;
  } on FormatException {
    stderr.writeln("invalidJson");
    exitCode = 1;
  }
}

Future<void> _run(List<String> arguments) async {
  String? fixtureOutput;
  var checkFixtures = false;
  String? validatePath;
  String? configPath;
  String? outputPath;
  String? digestOutputPath;
  String? expectedPackageId;
  var minimumPolicyVersion = 1;

  for (var index = 0; index < arguments.length; index += 1) {
    switch (arguments[index]) {
      case "--fixture-output":
        fixtureOutput = _next(arguments, ++index, "--fixture-output");
      case "--check-fixtures":
        checkFixtures = true;
      case "--validate":
        validatePath = _next(arguments, ++index, "--validate");
      case "--config":
        configPath = _next(arguments, ++index, "--config");
      case "--output":
        outputPath = _next(arguments, ++index, "--output");
      case "--digest-output":
        digestOutputPath = _next(arguments, ++index, "--digest-output");
      case "--expected-package-id":
        expectedPackageId = _next(arguments, ++index, "--expected-package-id");
      case "--minimum-policy-version":
        final value = _next(arguments, ++index, "--minimum-policy-version");
        minimumPolicyVersion = int.tryParse(value) ??
            (throw const FormatException("Invalid minimum policy version."));
      default:
        throw FormatException("Unknown argument: ${arguments[index]}");
    }
  }

  final modes = <bool>[
    fixtureOutput != null,
    checkFixtures,
    validatePath != null,
    configPath != null,
  ].where((selected) => selected).length;
  if (modes > 1) {
    throw const FormatException("Policy generator modes cannot be combined.");
  }

  if (checkFixtures) {
    await checkNativeInstallHelperPolicyFixtures();
    stdout.writeln("Native install helper policy fixtures are up to date.");
    return;
  }
  if (validatePath != null) {
    final packageId = _requiredOption(
      expectedPackageId,
      "--expected-package-id",
    );
    final policy = validateHelperPolicyJson(
      await File(validatePath).readAsString(),
      expectedApplicationPackageId: packageId,
      minimumAcceptedPolicyVersion: minimumPolicyVersion,
    );
    stdout.writeln(policy.canonicalSha256);
    return;
  }
  if (configPath != null) {
    final packageId = _requiredOption(
      expectedPackageId,
      "--expected-package-id",
    );
    final policyOutput = _requiredOption(outputPath, "--output");
    final digestOutput = _requiredOption(digestOutputPath, "--digest-output");
    final policy = validateHelperPolicyJson(
      await File(configPath).readAsString(),
      expectedApplicationPackageId: packageId,
      minimumAcceptedPolicyVersion: minimumPolicyVersion,
    );
    await _writeText(File(policyOutput), "${policy.canonicalJson}\n");
    await _writeText(File(digestOutput), "${policy.canonicalSha256}\n");
    stdout.writeln(policy.canonicalSha256);
    return;
  }
  if (outputPath != null ||
      digestOutputPath != null ||
      expectedPackageId != null) {
    throw const FormatException("Policy output options require --config.");
  }

  final destination = File(
    fixtureOutput ?? nativeInstallHelperPolicyFixturePath,
  );
  await generateNativeInstallHelperPolicyFixtures(output: destination);
  stdout.writeln("Generated native install helper policy fixtures.");
}

String _next(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException("$option requires a value.");
  }
  return arguments[index];
}

String _requiredOption(String? value, String option) {
  if (value == null) {
    throw FormatException("$option is required.");
  }
  return value;
}

Future<void> generateNativeInstallHelperPolicyFixtures({
  required File output,
}) async {
  final cases = _policyCases();
  for (final entry in cases) {
    final source = jsonEncode(entry["policy"]);
    try {
      final policy = validateHelperPolicyJson(
        source,
        expectedApplicationPackageId: entry["expectedPackageId"] as String,
        minimumAcceptedPolicyVersion:
            entry["minimumAcceptedPolicyVersion"] as int,
      );
      if (entry["expectedValid"] != true) {
        throw StateError("${entry["name"]}: invalid policy was accepted");
      }
      if (policy.canonicalJson != entry["canonicalJson"] ||
          policy.canonicalSha256 != entry["canonicalSha256"]) {
        throw StateError("${entry["name"]}: canonical policy drifted");
      }
    } on HelperPolicyValidationFailure catch (error) {
      if (entry["expectedValid"] == false &&
          entry["expectedFailure"] == error.code) {
        continue;
      }
      throw StateError(
        "${entry["name"]}: expected ${entry["expectedFailure"]}, "
        "got ${error.code}",
      );
    }
  }
  await _writeJson(
    output,
    <String, Object?>{
      "schemaVersion": 1,
      "cases": cases,
    },
  );
}

Future<void> checkNativeInstallHelperPolicyFixtures() async {
  final root = await Directory.systemTemp.createTemp("helper_policy_check_");
  try {
    final generated = File(path.join(root.path, "policy-cases.json"));
    await generateNativeInstallHelperPolicyFixtures(output: generated);
    final expected = await generated.readAsBytes();
    final actual =
        await File(nativeInstallHelperPolicyFixturePath).readAsBytes();
    if (!_bytesEqual(expected, actual)) {
      throw const HelperPolicyValidationFailure("policyFixturesOutOfDate");
    }
  } finally {
    await root.delete(recursive: true);
  }
}

List<Map<String, Object?>> _policyCases() {
  final portable = _portablePolicy();
  final privileged = _privilegedPolicy();
  final cases = <Map<String, Object?>>[
    _case("valid portable policy", portable, expectedValid: true),
    _case("valid privileged policy", privileged, expectedValid: true),
  ];

  void addInvalid(
    String name,
    String expectedFailure,
    void Function(Map<String, dynamic>) mutate, {
    int minimumAcceptedPolicyVersion = 1,
    String expectedPackageId = "com.example.app",
    Map<String, Object?>? source,
  }) {
    final policy = _copyMap(source ?? privileged);
    mutate(policy);
    cases.add(
      _case(
        name,
        policy,
        expectedValid: false,
        expectedFailure: expectedFailure,
        minimumAcceptedPolicyVersion: minimumAcceptedPolicyVersion,
        expectedPackageId: expectedPackageId,
      ),
    );
  }

  addInvalid(
    "wrong package ID",
    "applicationPackageIdMismatch",
    (_) {},
    expectedPackageId: "com.example.other",
  );
  addInvalid("unknown strategy", "unknownStrategy", (policy) {
    _listMap(policy, "allowedStrategies", 0)["strategy"] = "recursiveCopy";
  });
  addInvalid(
    "root filesystem authorization",
    "rootFilesystemAuthorization",
    (policy) => policy["allowedInstallRoots"] = <String>["/"],
  );
  addInvalid(
    "relative install root",
    "relativeInstallRoot",
    (policy) => policy["allowedInstallRoots"] = <String>["Applications"],
  );
  addInvalid(
    "caller-added release key authority",
    "unknownField:callerReleaseRootPublicKeys",
    (policy) => policy["callerReleaseRootPublicKeys"] = <String>["attacker"],
  );
  addInvalid(
    "policy rollback",
    "policyRollback",
    (policy) => policy["policyVersion"] = 2,
    minimumAcceptedPolicyVersion: 3,
  );
  addInvalid("invalid signer", "wildcardSigner", (policy) {
    _map(policy, "allowedHelperSigner")["value"] = "*";
  });
  addInvalid("duplicate release key ID", "duplicateReleaseKeyId", (policy) {
    final keys = policy["releaseRootPublicKeys"]! as List<dynamic>;
    final duplicate = _copyMap(keys.first as Map<String, dynamic>);
    duplicate["publicKeyBase64"] = base64Encode(List<int>.filled(32, 9));
    keys.add(duplicate);
  });
  addInvalid(
      "protocol downgrade", "invalidInteger:minimumHelperProtocolVersion",
      (policy) {
    policy["minimumHelperProtocolVersion"] = 0;
  });
  addInvalid(
    "portable policy requests elevation",
    "portablePolicyRequestsElevation",
    (policy) => policy["allowedTargetClasses"] = <String>[
      "sameUserWritable",
      "protectedApplication",
    ],
    source: portable,
  );
  addInvalid(
    "external refresh without named provider",
    "missingField:allowedStrategies.provider",
    (policy) {
      policy["allowedStrategies"] = <Map<String, Object?>>[
        <String, Object?>{"strategy": "externalManagedRefresh"},
      ];
    },
  );
  addInvalid("empty release root key", "emptyReleaseRootPublicKey", (policy) {
    _listMap(policy, "releaseRootPublicKeys", 0)["publicKeyBase64"] = "";
  });
  addInvalid(
    "unknown signer authority field",
    "unknownField:allowedApplicationSigner.allowedInstallRoots",
    (policy) {
      _map(policy, "allowedApplicationSigner")["allowedInstallRoots"] =
          <String>["/Applications"];
    },
  );
  return cases;
}

Map<String, Object?> _case(
  String name,
  Map<String, Object?> policy, {
  required bool expectedValid,
  String? expectedFailure,
  int minimumAcceptedPolicyVersion = 1,
  String expectedPackageId = "com.example.app",
}) {
  final canonicalJson = canonicalNativeInstallHelperJson(policy);
  return <String, Object?>{
    "name": name,
    "policy": policy,
    "expectedPackageId": expectedPackageId,
    "minimumAcceptedPolicyVersion": minimumAcceptedPolicyVersion,
    "expectedValid": expectedValid,
    "expectedFailure": expectedFailure,
    "canonicalJson": canonicalJson,
    "canonicalSha256":
        crypto.sha256.convert(utf8.encode(canonicalJson)).toString(),
  };
}

Map<String, Object?> _portablePolicy() {
  return <String, Object?>{
    "policyVersion": 1,
    "policyId": "com.example.desktop-updater.portable",
    "applicationPackageId": "com.example.app",
    "helperServiceId": "com.example.desktop-updater.helper",
    "allowedApplicationSigner": <String, Object?>{
      "kind": "sha256",
      "value": _shaA,
    },
    "allowedHelperSigner": <String, Object?>{
      "kind": "sha256",
      "value": _shaB,
    },
    "allowedTargetClasses": <String>["sameUserWritable"],
    "allowedInstallRoots": <String>[],
    "releaseRootPublicKeys": <Map<String, Object?>>[
      <String, Object?>{
        "keyId": "stable-2026",
        "algorithm": "ed25519",
        "publicKeyBase64": base64Encode(List<int>.generate(32, (i) => i)),
      },
    ],
    "allowedStrategies": <Map<String, Object?>>[
      <String, Object?>{
        "strategy": "directoryReplace",
        "provider": "platformDirectory",
      },
      <String, Object?>{
        "strategy": "singleFileReplace",
        "provider": "platformFile",
      },
    ],
    "minimumHelperProtocolVersion": 1,
  };
}

Map<String, Object?> _privilegedPolicy() {
  return <String, Object?>{
    "policyVersion": 3,
    "policyId": "com.example.desktop-updater.privileged",
    "applicationPackageId": "com.example.app",
    "helperServiceId": "com.example.desktop-updater.helper",
    "allowedApplicationSigner": <String, Object?>{
      "kind": "appleDesignatedRequirement",
      "value": "identifier com.example.app and anchor apple generic",
    },
    "allowedHelperSigner": <String, Object?>{
      "kind": "appleDesignatedRequirement",
      "value":
          "identifier com.example.desktop-updater.helper and anchor apple generic",
    },
    "allowedTargetClasses": <String>[
      "applicationBundle",
      "protectedApplication",
    ],
    "allowedInstallRoots": <String>["/Applications"],
    "releaseRootPublicKeys": <Map<String, Object?>>[
      <String, Object?>{
        "keyId": "stable-2026",
        "algorithm": "ed25519",
        "publicKeyBase64": base64Encode(List<int>.generate(32, (i) => i + 1)),
      },
    ],
    "allowedStrategies": <Map<String, Object?>>[
      <String, Object?>{
        "strategy": "directoryReplace",
        "provider": "platformDirectory",
      },
      <String, Object?>{
        "strategy": "verifiedInstallerHandoff",
        "provider": "macosInstaller",
      },
    ],
    "minimumHelperProtocolVersion": 1,
  };
}

Map<String, dynamic> _copyMap(Object value) {
  return Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
}

Map<String, dynamic> _map(Map<String, dynamic> source, String key) {
  return source[key]! as Map<String, dynamic>;
}

Map<String, dynamic> _listMap(
  Map<String, dynamic> source,
  String key,
  int index,
) {
  return (source[key]! as List<dynamic>)[index] as Map<String, dynamic>;
}

Future<void> _writeJson(File file, Object? value) async {
  final sorted = jsonDecode(canonicalNativeInstallHelperJson(value));
  await _writeText(file, "${_jsonEncoder.convert(sorted)}\n");
}

Future<void> _writeText(File file, String value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
