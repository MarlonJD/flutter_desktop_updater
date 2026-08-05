import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:path/path.dart" as path;

import "generate_native_install_helper_fixtures.dart";

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

ValidatedHelperPolicy validateHelperPolicyJson(
  String source, {
  required String expectedApplicationPackageId,
  required int minimumAcceptedPolicyVersion,
}) {
  final decoded = decodeStrictNativeInstallHelperJson(source);
  if (decoded is! Map<String, dynamic>) {
    throw const HelperPolicyValidationFailure("invalidType:policy");
  }
  return validateHelperPolicy(
    decoded,
    expectedApplicationPackageId: expectedApplicationPackageId,
    minimumAcceptedPolicyVersion: minimumAcceptedPolicyVersion,
  );
}

ValidatedHelperPolicy validateHelperPolicy(
  Map<String, dynamic> policy, {
  required String expectedApplicationPackageId,
  required int minimumAcceptedPolicyVersion,
}) {
  _requireExactKeys(
    policy,
    required: _policyFields,
  );
  final policyVersion = _requireInteger(
    policy["policyVersion"],
    "policyVersion",
    minimum: 1,
  );
  if (policyVersion < minimumAcceptedPolicyVersion) {
    throw const HelperPolicyValidationFailure("policyRollback");
  }
  _requireIdentifier(policy["policyId"], "policyId");
  final applicationPackageId = _requireIdentifier(
    policy["applicationPackageId"],
    "applicationPackageId",
  );
  if (applicationPackageId != expectedApplicationPackageId) {
    throw const HelperPolicyValidationFailure("applicationPackageIdMismatch");
  }
  _requireIdentifier(policy["helperServiceId"], "helperServiceId");
  _validateSigner(
    _requireMap(policy["allowedApplicationSigner"], "allowedApplicationSigner"),
    "allowedApplicationSigner",
  );
  _validateSigner(
    _requireMap(policy["allowedHelperSigner"], "allowedHelperSigner"),
    "allowedHelperSigner",
  );

  final targetClasses = _requireStringList(
    policy["allowedTargetClasses"],
    "allowedTargetClasses",
    allowEmpty: false,
  );
  if (targetClasses.any((value) => !_targetClasses.contains(value))) {
    throw const HelperPolicyValidationFailure("unknownTargetClass");
  }
  if (targetClasses.toSet().length != targetClasses.length) {
    throw const HelperPolicyValidationFailure("duplicateTargetClass");
  }

  final installRoots = _requireStringList(
    policy["allowedInstallRoots"],
    "allowedInstallRoots",
    allowEmpty: true,
  );
  final rootSet = <String>{};
  for (final root in installRoots) {
    _validateInstallRoot(root);
    if (!rootSet.add(root)) {
      throw const HelperPolicyValidationFailure("duplicateInstallRoot");
    }
  }

  _validateReleaseRootPublicKeys(policy["releaseRootPublicKeys"]);
  final strategies = _validateStrategies(policy["allowedStrategies"]);
  _requireInteger(
    policy["minimumHelperProtocolVersion"],
    "minimumHelperProtocolVersion",
    minimum: 1,
  );

  final portable = installRoots.isEmpty;
  if (portable &&
      (targetClasses.any((value) => value != "sameUserWritable") ||
          strategies.any(
            (entry) =>
                entry.strategy != "directoryReplace" &&
                entry.strategy != "singleFileReplace",
          ))) {
    throw const HelperPolicyValidationFailure(
      "portablePolicyRequestsElevation",
    );
  }

  final canonicalJson = canonicalNativeInstallHelperJson(policy);
  return ValidatedHelperPolicy(
    canonicalJson: canonicalJson,
    canonicalSha256:
        crypto.sha256.convert(utf8.encode(canonicalJson)).toString(),
  );
}

void _validateSigner(Map<String, dynamic> signer, String field) {
  _requireExactKeys(
    signer,
    path: field,
    required: const <String>{"kind", "value"},
  );
  final kind = _requireString(signer["kind"], "$field.kind");
  if (!_signerKinds.contains(kind)) {
    throw const HelperPolicyValidationFailure("invalidSigner");
  }
  final value = _requireString(signer["value"], "$field.value");
  if (value.contains("*") || value.contains("?")) {
    throw const HelperPolicyValidationFailure("wildcardSigner");
  }
  if (kind == "sha256" && !_sha256Pattern.hasMatch(value)) {
    throw const HelperPolicyValidationFailure("invalidSigner");
  }
}

void _validateInstallRoot(String root) {
  if (root == "/" || RegExp(r"^[A-Za-z]:[\\/]?$").hasMatch(root)) {
    throw const HelperPolicyValidationFailure("rootFilesystemAuthorization");
  }
  final absolute =
      root.startsWith("/") || RegExp(r"^[A-Za-z]:[\\/]").hasMatch(root);
  if (!absolute) {
    throw const HelperPolicyValidationFailure("relativeInstallRoot");
  }
  final segments = root.split(RegExp(r"[\\/]"));
  if (segments.any((segment) => segment == "." || segment == "..") ||
      root.contains("*") ||
      root.contains("?")) {
    throw const HelperPolicyValidationFailure("invalidInstallRoot");
  }
}

void _validateReleaseRootPublicKeys(Object? value) {
  if (value is! List || value.isEmpty) {
    throw const HelperPolicyValidationFailure("emptyReleaseRootPublicKeys");
  }
  final keyIds = <String>{};
  for (final entry in value) {
    final key = _requireMap(entry, "releaseRootPublicKeys");
    _requireExactKeys(
      key,
      path: "releaseRootPublicKeys",
      required: const <String>{"keyId", "algorithm", "publicKeyBase64"},
    );
    final keyId = _requireString(key["keyId"], "releaseRootPublicKeys.keyId");
    if (!_keyIdPattern.hasMatch(keyId)) {
      throw const HelperPolicyValidationFailure("invalidReleaseKeyId");
    }
    if (!keyIds.add(keyId)) {
      throw const HelperPolicyValidationFailure("duplicateReleaseKeyId");
    }
    if (key["algorithm"] != "ed25519") {
      throw const HelperPolicyValidationFailure("invalidReleaseKeyAlgorithm");
    }
    final rawEncoded = key["publicKeyBase64"];
    if (rawEncoded is! String) {
      throw const HelperPolicyValidationFailure(
        "invalidType:releaseRootPublicKeys.publicKeyBase64",
      );
    }
    if (rawEncoded.isEmpty) {
      throw const HelperPolicyValidationFailure("emptyReleaseRootPublicKey");
    }
    final encoded = rawEncoded;
    try {
      if (base64Decode(encoded).length != 32) {
        throw const FormatException();
      }
    } on FormatException {
      throw const HelperPolicyValidationFailure("emptyReleaseRootPublicKey");
    }
  }
}

List<ValidatedAllowedStrategy> _validateStrategies(Object? value) {
  if (value is! List || value.isEmpty) {
    throw const HelperPolicyValidationFailure("emptyAllowedStrategies");
  }
  final result = <ValidatedAllowedStrategy>[];
  final seen = <String>{};
  for (final entry in value) {
    final strategy = _requireMap(entry, "allowedStrategies");
    _requireExactKeys(
      strategy,
      path: "allowedStrategies",
      required: const <String>{"strategy", "provider"},
    );
    final strategyName =
        _requireString(strategy["strategy"], "allowedStrategies.strategy");
    if (!_strategyProviders.containsKey(strategyName)) {
      throw const HelperPolicyValidationFailure("unknownStrategy");
    }
    final provider =
        _requireString(strategy["provider"], "allowedStrategies.provider");
    if (!_strategyProviders[strategyName]!.contains(provider)) {
      throw const HelperPolicyValidationFailure("strategyProviderMismatch");
    }
    if (!seen.add("$strategyName\u0000$provider")) {
      throw const HelperPolicyValidationFailure("duplicateAllowedStrategy");
    }
    result.add(
      ValidatedAllowedStrategy(strategy: strategyName, provider: provider),
    );
  }
  return result;
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

void _requireExactKeys(
  Map<String, dynamic> value, {
  required Set<String> required,
  String path = "",
}) {
  for (final key in required) {
    if (!value.containsKey(key)) {
      throw HelperPolicyValidationFailure(
        "missingField:${_field(path, key)}",
      );
    }
  }
  for (final key in value.keys) {
    if (!required.contains(key)) {
      throw HelperPolicyValidationFailure(
        "unknownField:${_field(path, key)}",
      );
    }
  }
}

String _field(String prefix, String key) =>
    prefix.isEmpty ? key : "$prefix.$key";

Map<String, dynamic> _requireMap(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw HelperPolicyValidationFailure("invalidType:$field");
  }
  return value;
}

String _requireString(Object? value, String field) {
  if (value is! String) {
    throw HelperPolicyValidationFailure("invalidType:$field");
  }
  if (value.trim().isEmpty) {
    throw HelperPolicyValidationFailure("invalidString:$field");
  }
  return value;
}

String _requireIdentifier(Object? value, String field) {
  final identifier = _requireString(value, field);
  if (!_identifierPattern.hasMatch(identifier)) {
    throw HelperPolicyValidationFailure("invalidIdentifier:$field");
  }
  return identifier;
}

int _requireInteger(
  Object? value,
  String field, {
  required int minimum,
}) {
  if (value is! int || value < minimum) {
    throw HelperPolicyValidationFailure("invalidInteger:$field");
  }
  return value;
}

List<String> _requireStringList(
  Object? value,
  String field, {
  required bool allowEmpty,
}) {
  if (value is! List || (!allowEmpty && value.isEmpty)) {
    throw HelperPolicyValidationFailure("invalidArray:$field");
  }
  final result = <String>[];
  for (final entry in value) {
    result.add(_requireString(entry, field));
  }
  return result;
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

const _policyFields = <String>{
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
};

const _targetClasses = <String>{
  "sameUserWritable",
  "applicationBundle",
  "applicationDirectory",
  "singleExecutable",
  "protectedApplication",
  "systemPackage",
  "externalManaged",
};

const _signerKinds = <String>{
  "appleDesignatedRequirement",
  "authenticodePublisher",
  "sha256",
};

const _strategyProviders = <String, Set<String>>{
  "directoryReplace": <String>{"platformDirectory"},
  "singleFileReplace": <String>{"platformFile"},
  "verifiedInstallerHandoff": <String>{"macosInstaller", "windowsInno"},
  "systemPackageTransaction": <String>{"apt", "dnf"},
  "externalManagedRefresh": <String>{"flatpak", "snap"},
};

final _identifierPattern = RegExp(
  r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{1,126}[A-Za-z0-9])?$",
);
final _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");
final _keyIdPattern = RegExp(r"^[A-Za-z0-9._-]{1,128}$");

final class ValidatedHelperPolicy {
  const ValidatedHelperPolicy({
    required this.canonicalJson,
    required this.canonicalSha256,
  });

  final String canonicalJson;
  final String canonicalSha256;
}

final class ValidatedAllowedStrategy {
  const ValidatedAllowedStrategy({
    required this.strategy,
    required this.provider,
  });

  final String strategy;
  final String provider;
}

final class HelperPolicyValidationFailure implements Exception {
  const HelperPolicyValidationFailure(this.code);

  final String code;

  @override
  String toString() => code;
}
