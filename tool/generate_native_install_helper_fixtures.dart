import "dart:collection";
import "dart:convert";
import "dart:io";

import "package:path/path.dart" as path;

const nativeInstallHelperFixtureRoot =
    "fixtures/compat/native-install-helper/v1";

const nativeInstallHelperStrategies = <String>[
  "directoryReplace",
  "singleFileReplace",
  "verifiedInstallerHandoff",
  "systemPackageTransaction",
  "externalManagedRefresh",
];

const nativeInstallHelperResultCodes = <String>[
  "helperUnavailable",
  "helperTrustFailure",
  "authorizationDenied",
  "targetValidationFailure",
  "stageProvenanceFailure",
  "transactionBusy",
  "journalCorrupt",
  "recoveryRequired",
  "rolledBack",
  "externalManagerPending",
  "manualActionRequired",
  "packageManagerFailure",
  "relaunchFailure",
  "completed",
];

const nativeInstallHelperDiagnosticEvents = <String>[
  "helper authenticated",
  "target lock acquired",
  "transaction journal persisted",
  "caller exit observed",
  "recovery detected",
  "backup restored",
  "activation verified",
  "package manager state verified",
  "manual action required",
  "transaction completed",
];

const _jsonEncoder = JsonEncoder.withIndent("  ");
const _shaA =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const _shaB =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const _shaC =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const _shaD =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const _shaE =
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

Future<void> main(List<String> arguments) async {
  try {
    await _run(arguments);
  } on NativeInstallHelperContractFailure catch (error) {
    stderr.writeln(error.code);
    exitCode = 1;
  } on FormatException {
    stderr.writeln("invalidJson");
    exitCode = 1;
  }
}

Future<void> _run(List<String> arguments) async {
  var check = false;
  String? outputPath;
  String? validateRequestPath;
  String? canonicalizePath;

  for (var index = 0; index < arguments.length; index += 1) {
    switch (arguments[index]) {
      case "--check":
        check = true;
      case "--output":
        outputPath = _nextArgument(arguments, ++index, "--output");
      case "--validate-request":
        validateRequestPath =
            _nextArgument(arguments, ++index, "--validate-request");
      case "--canonicalize":
        canonicalizePath = _nextArgument(arguments, ++index, "--canonicalize");
      default:
        throw FormatException("Unknown argument: ${arguments[index]}");
    }
  }

  final selectedModes = <bool>[
    check,
    outputPath != null,
    validateRequestPath != null,
    canonicalizePath != null,
  ].where((selected) => selected).length;
  if (selectedModes > 1) {
    throw const FormatException("Generator modes cannot be combined.");
  }

  if (validateRequestPath != null) {
    validateNativeInstallHelperRequestJson(
      await File(validateRequestPath).readAsString(),
    );
    stdout.writeln("valid");
    return;
  }
  if (canonicalizePath != null) {
    stdout.writeln(
      canonicalizeNativeInstallHelperJson(
        await File(canonicalizePath).readAsString(),
      ),
    );
    return;
  }
  if (check) {
    await checkNativeInstallHelperFixtures();
    stdout.writeln("Native install helper fixtures are up to date.");
    return;
  }

  final outputDirectory =
      Directory(outputPath ?? nativeInstallHelperFixtureRoot);
  await generateNativeInstallHelperFixtures(outputDirectory: outputDirectory);
  stdout.writeln(
    "Generated native install helper fixtures at ${outputDirectory.path}.",
  );
}

String _nextArgument(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException("$option requires a path.");
  }
  return arguments[index];
}

Future<void> generateNativeInstallHelperFixtures({
  required Directory outputDirectory,
}) async {
  final validRequests = _validRequestCases();
  final invalidRequests = _invalidRequestCases();

  for (final entry in validRequests) {
    validateNativeInstallHelperRequestJson(jsonEncode(entry["request"]));
  }
  for (final entry in invalidRequests) {
    final source = entry["rawJson"] as String? ?? jsonEncode(entry["request"]);
    try {
      validateNativeInstallHelperRequestJson(source);
    } on NativeInstallHelperContractFailure catch (error) {
      if (error.code == entry["expectedFailure"]) {
        continue;
      }
      throw StateError(
        "${entry["name"]}: expected ${entry["expectedFailure"]}, "
        "got ${error.code}",
      );
    }
    throw StateError("${entry["name"]}: invalid request was accepted");
  }

  await _writeJson(
    File(path.join(outputDirectory.path, "valid-requests.json")),
    <String, Object?>{
      "schemaVersion": 1,
      "cases": validRequests,
    },
  );
  await _writeJson(
    File(path.join(outputDirectory.path, "invalid-requests.json")),
    <String, Object?>{
      "schemaVersion": 1,
      "coveredRequestFields": _coveredRequestFields,
      "cases": invalidRequests,
    },
  );
  await _writeJson(
    File(path.join(outputDirectory.path, "journal-transitions.json")),
    _journalTransitionsFixture(),
  );
  await _writeJson(
    File(path.join(outputDirectory.path, "diagnostic-results.json")),
    _diagnosticResultsFixture(),
  );
  await _writeJson(
    File(path.join(outputDirectory.path, "canonical-json.json")),
    _canonicalJsonFixture(),
  );
}

Future<void> checkNativeInstallHelperFixtures() async {
  final temporaryRoot =
      await Directory.systemTemp.createTemp("native_install_helper_check_");
  try {
    final generated = Directory(path.join(temporaryRoot.path, "v1"));
    await generateNativeInstallHelperFixtures(outputDirectory: generated);
    final expected = await _readTree(generated);
    final actual = await _readTree(Directory(nativeInstallHelperFixtureRoot));
    if (!_treeContains(actual, expected)) {
      throw const NativeInstallHelperContractFailure("fixturesOutOfDate");
    }
  } finally {
    await temporaryRoot.delete(recursive: true);
  }
}

void validateNativeInstallHelperRequestJson(String source) {
  final value = decodeStrictNativeInstallHelperJson(source);
  if (value is! Map<String, dynamic>) {
    throw const NativeInstallHelperContractFailure("invalidType:request");
  }
  validateNativeInstallHelperRequest(value);
}

void validateNativeInstallHelperRequest(Map<String, dynamic> request) {
  _requireExactKeys(
    request,
    required: const <String>{
      "schemaVersion",
      "protocolVersion",
      "transactionId",
      "policyId",
      "packageId",
      "strategy",
      "provider",
      "target",
      "currentIdentity",
      "desiredIdentity",
      "stage",
      "signedDescriptor",
      "caller",
      "requestNonce",
    },
    optional: const <String>{"diagnosticsDestination"},
  );

  if (request["schemaVersion"] != 1) {
    throw const NativeInstallHelperContractFailure(
      "unsupportedSchemaVersion",
    );
  }
  if (request["protocolVersion"] != 1) {
    throw const NativeInstallHelperContractFailure(
      "unsupportedProtocolVersion",
    );
  }
  _requirePattern(
    request["transactionId"],
    "transactionId",
    _lowercaseUuidPattern,
    "invalidTransactionId",
  );
  _requirePattern(
    request["policyId"],
    "policyId",
    _dottedIdentifierPattern,
    "invalidPolicyId",
  );
  final packageId = _requirePattern(
    request["packageId"],
    "packageId",
    _dottedIdentifierPattern,
    "invalidPackageId",
  );

  final strategy = _requireEnum(
    request["strategy"],
    "strategy",
    nativeInstallHelperStrategies.toSet(),
    "unknownStrategy",
  );
  final provider = _requireEnum(
    request["provider"],
    "provider",
    _providers,
    "unknownProvider",
  );
  if (!_strategyProviders[strategy]!.contains(provider)) {
    throw const NativeInstallHelperContractFailure("strategyProviderMismatch");
  }

  _validateTarget(
    _requireMap(request["target"], "target"),
    strategy: strategy,
  );
  _validateVersionIdentity(
    _requireMap(request["currentIdentity"], "currentIdentity"),
    "currentIdentity",
  );
  _validateVersionIdentity(
    _requireMap(request["desiredIdentity"], "desiredIdentity"),
    "desiredIdentity",
  );
  _validateStage(_requireMap(request["stage"], "stage"));
  _validateSignedDescriptor(
    _requireMap(request["signedDescriptor"], "signedDescriptor"),
  );
  _validateCaller(
    _requireMap(request["caller"], "caller"),
    expectedPackageId: packageId,
  );
  _requirePattern(
    request["requestNonce"],
    "requestNonce",
    _readyTokenPattern,
    "invalidRequestNonce",
  );
  if (request.containsKey("diagnosticsDestination")) {
    _validateDiagnosticsDestination(
      _requireMap(
        request["diagnosticsDestination"],
        "diagnosticsDestination",
      ),
    );
  }
}

void _validateTarget(
  Map<String, dynamic> target, {
  required String strategy,
}) {
  _requireExactKeys(
    target,
    path: "target",
    required: const <String>{
      "class",
      "pathHint",
      "targetNameHint",
      "executableRelativePath",
      "identityProofSha256",
    },
  );
  final targetClass = _requireEnum(
    target["class"],
    "target.class",
    _targetClasses,
    "unknownTargetClass",
  );
  if (!_strategyTargetClasses[strategy]!.contains(targetClass)) {
    throw const NativeInstallHelperContractFailure("strategyTargetMismatch");
  }
  _requireBoundedString(target["pathHint"], "target.pathHint", max: 4096);
  _requireSafeSiblingName(target["targetNameHint"], "targetNameHint");
  _requireSafeRelativePath(
    target["executableRelativePath"],
    "executableRelativePath",
  );
  _requireSha256(target["identityProofSha256"], "target.identityProofSha256");
}

void _validateVersionIdentity(Map<String, dynamic> identity, String field) {
  _requireExactKeys(
    identity,
    path: field,
    required: const <String>{
      "version",
      "buildNumber",
      "packageIdentitySha256",
    },
  );
  _requireBoundedString(identity["version"], "$field.version", max: 128);
  _requireInteger(
    identity["buildNumber"],
    "$field.buildNumber",
    minimum: 0,
  );
  _requireSha256(
    identity["packageIdentitySha256"],
    "$field.packageIdentitySha256",
  );
}

void _validateStage(Map<String, dynamic> stage) {
  _requireExactKeys(
    stage,
    path: "stage",
    required: const <String>{
      "pathHint",
      "ownershipNonce",
      "provenanceSha256",
      "artifactSha256",
      "artifactLength",
    },
  );
  _requireBoundedString(stage["pathHint"], "stage.pathHint", max: 4096);
  _requirePattern(
    stage["ownershipNonce"],
    "stage.ownershipNonce",
    _sha256Pattern,
    "invalidStageOwnershipNonce",
  );
  _requireSha256(stage["provenanceSha256"], "stage.provenanceSha256");
  _requireSha256(stage["artifactSha256"], "stage.artifactSha256");
  _requireInteger(
    stage["artifactLength"],
    "stage.artifactLength",
    minimum: 1,
    maximum: 9223372036854775807,
  );
}

void _validateSignedDescriptor(Map<String, dynamic> descriptor) {
  _requireExactKeys(
    descriptor,
    path: "signedDescriptor",
    required: const <String>{
      "canonicalSha256",
      "signatureAlgorithm",
      "keyId",
      "signatureBase64",
    },
  );
  _requireSha256(
    descriptor["canonicalSha256"],
    "signedDescriptor.canonicalSha256",
  );
  if (descriptor["signatureAlgorithm"] != "ed25519") {
    throw const NativeInstallHelperContractFailure(
      "unsupportedDescriptorSignatureAlgorithm",
    );
  }
  _requirePattern(
    descriptor["keyId"],
    "signedDescriptor.keyId",
    _keyIdPattern,
    "invalidDescriptorKeyId",
  );
  final signature = _requirePattern(
    descriptor["signatureBase64"],
    "signedDescriptor.signatureBase64",
    _signaturePattern,
    "invalidDescriptorSignature",
  );
  try {
    if (base64Decode(signature).length != 64) {
      throw const FormatException();
    }
  } on FormatException {
    throw const NativeInstallHelperContractFailure(
      "invalidDescriptorSignature",
    );
  }
}

void _validateCaller(
  Map<String, dynamic> caller, {
  required String expectedPackageId,
}) {
  _requireExactKeys(
    caller,
    path: "caller",
    required: const <String>{
      "processId",
      "processStartIdentity",
      "executableSha256",
      "packageId",
      "signerIdentity",
    },
  );
  _requireInteger(
    caller["processId"],
    "caller.processId",
    minimum: 1,
    maximum: 4294967295,
  );
  _requireBoundedString(
    caller["processStartIdentity"],
    "caller.processStartIdentity",
    max: 256,
  );
  _requireSha256(caller["executableSha256"], "caller.executableSha256");
  final callerPackageId = _requirePattern(
    caller["packageId"],
    "caller.packageId",
    _dottedIdentifierPattern,
    "invalidCallerPackageId",
  );
  if (callerPackageId != expectedPackageId) {
    throw const NativeInstallHelperContractFailure("callerPackageIdMismatch");
  }
  _requireBoundedString(
    caller["signerIdentity"],
    "caller.signerIdentity",
    max: 512,
  );
}

void _validateDiagnosticsDestination(Map<String, dynamic> destination) {
  _requireExactKeys(
    destination,
    path: "diagnosticsDestination",
    required: const <String>{"kind"},
    optional: const <String>{"stream"},
  );
  final kind = _requireEnum(
    destination["kind"],
    "diagnosticsDestination.kind",
    const <String>{"platformLog", "inheritedStream"},
    "invalidDiagnosticsDestination",
  );
  if (kind == "inheritedStream") {
    if (destination["stream"] != "stderr") {
      throw const NativeInstallHelperContractFailure(
        "invalidDiagnosticsDestination",
      );
    }
  } else if (destination.containsKey("stream")) {
    throw const NativeInstallHelperContractFailure(
      "invalidDiagnosticsDestination",
    );
  }
}

Object? decodeStrictNativeInstallHelperJson(String source) {
  _DuplicateKeyScanner(source).scan();
  try {
    return jsonDecode(source);
  } on FormatException {
    throw const NativeInstallHelperContractFailure("invalidJson");
  }
}

String canonicalizeNativeInstallHelperJson(String source) {
  return canonicalNativeInstallHelperJson(
    decodeStrictNativeInstallHelperJson(source),
  );
}

String canonicalNativeInstallHelperJson(Object? value) {
  return jsonEncode(_sortJson(value));
}

Object? _sortJson(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>(_compareUtf8Strings);
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const NativeInstallHelperContractFailure("nonStringObjectKey");
      }
      sorted[entry.key as String] = _sortJson(entry.value);
    }
    return sorted;
  }
  if (value is List) {
    return value.map(_sortJson).toList();
  }
  if (value is double && !value.isFinite) {
    throw const NativeInstallHelperContractFailure("nonFiniteNumber");
  }
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  throw const NativeInstallHelperContractFailure("unsupportedJsonValue");
}

int _compareUtf8Strings(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final sharedLength = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < sharedLength; index += 1) {
    final comparison = leftBytes[index].compareTo(rightBytes[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return leftBytes.length.compareTo(rightBytes.length);
}

List<Map<String, Object?>> _validRequestCases() {
  const specs = <({
    String name,
    String strategy,
    String provider,
    String targetClass,
    String pathHint,
    String targetName,
    String executableRelativePath,
  })>[
    (
      name: "portable directory replacement",
      strategy: "directoryReplace",
      provider: "platformDirectory",
      targetClass: "applicationDirectory",
      pathHint: "/opt/example",
      targetName: "example",
      executableRelativePath: "bin/example",
    ),
    (
      name: "writable AppImage replacement",
      strategy: "singleFileReplace",
      provider: "platformFile",
      targetClass: "singleExecutable",
      pathHint: "/home/example/Example.AppImage",
      targetName: "Example.AppImage",
      executableRelativePath: "Example.AppImage",
    ),
    (
      name: "verified macOS installer handoff",
      strategy: "verifiedInstallerHandoff",
      provider: "macosInstaller",
      targetClass: "applicationBundle",
      pathHint: "/Applications/Example.app",
      targetName: "Example.app",
      executableRelativePath: "Contents/MacOS/Example",
    ),
    (
      name: "sealed APT package transaction",
      strategy: "systemPackageTransaction",
      provider: "apt",
      targetClass: "systemPackage",
      pathHint: "/var/lib/dpkg/status",
      targetName: "example",
      executableRelativePath: "opt/example/bin/example",
    ),
    (
      name: "signed Flatpak managed refresh",
      strategy: "externalManagedRefresh",
      provider: "flatpak",
      targetClass: "externalManaged",
      pathHint: "/var/lib/flatpak/app/com.example.App",
      targetName: "com.example.App",
      executableRelativePath: "files/bin/example",
    ),
  ];

  return <Map<String, Object?>>[
    for (var index = 0; index < specs.length; index += 1)
      <String, Object?>{
        "name": specs[index].name,
        "strategy": specs[index].strategy,
        "request": _requestFor(specs[index], index + 1),
      },
  ];
}

Map<String, Object?> _requestFor(
  ({
    String name,
    String strategy,
    String provider,
    String targetClass,
    String pathHint,
    String targetName,
    String executableRelativePath,
  }) spec,
  int index,
) {
  return <String, Object?>{
    "schemaVersion": 1,
    "protocolVersion": 1,
    "transactionId":
        "00000000-0000-4000-8000-${index.toString().padLeft(12, "0")}",
    "policyId": "com.example.desktop-updater",
    "packageId": "com.example.app",
    "strategy": spec.strategy,
    "provider": spec.provider,
    "target": <String, Object?>{
      "class": spec.targetClass,
      "pathHint": spec.pathHint,
      "targetNameHint": spec.targetName,
      "executableRelativePath": spec.executableRelativePath,
      "identityProofSha256": _shaA,
    },
    "currentIdentity": <String, Object?>{
      "version": "2.7.0",
      "buildNumber": 270,
      "packageIdentitySha256": _shaB,
    },
    "desiredIdentity": <String, Object?>{
      "version": "2.8.0",
      "buildNumber": 280,
      "packageIdentitySha256": _shaC,
    },
    "stage": <String, Object?>{
      "pathHint": "/var/tmp/.desktop_updater_stage_$index",
      "ownershipNonce": _shaD,
      "provenanceSha256": _shaE,
      "artifactSha256": _shaC,
      "artifactLength": int.parse("9007199254740993"),
    },
    "signedDescriptor": <String, Object?>{
      "canonicalSha256": _shaB,
      "signatureAlgorithm": "ed25519",
      "keyId": "stable-2026",
      "signatureBase64": base64Encode(List<int>.filled(64, index)),
    },
    "caller": <String, Object?>{
      "processId": 4242 + index,
      "processStartIdentity": "pid-start-$index",
      "executableSha256": _shaA,
      "packageId": "com.example.app",
      "signerIdentity": "Example Publisher",
    },
    "requestNonce": base64Url
        .encode(List<int>.generate(32, (byte) => byte + index))
        .replaceAll("=", ""),
    "diagnosticsDestination": <String, Object?>{
      "kind": "platformLog",
    },
  };
}

List<Map<String, Object?>> _invalidRequestCases() {
  final base = _copyMap(_validRequestCases().first["request"]!);
  final cases = <Map<String, Object?>>[];

  void add(
    String name,
    String expectedFailure,
    void Function(Map<String, dynamic>) mutate,
  ) {
    final request = _copyMap(base);
    mutate(request);
    cases.add(<String, Object?>{
      "name": name,
      "request": request,
      "expectedFailure": expectedFailure,
    });
  }

  add("unknown schema major", "unsupportedSchemaVersion", (request) {
    request["schemaVersion"] = 2;
  });
  add("unknown protocol major", "unsupportedProtocolVersion", (request) {
    request["protocolVersion"] = 2;
  });
  add("non-canonical uppercase UUID", "invalidTransactionId", (request) {
    request["transactionId"] = "00000000-0000-4000-8000-00000000000A";
  });
  add("invalid policy ID", "invalidPolicyId", (request) {
    request["policyId"] = "../policy";
  });
  add("invalid package ID", "invalidPackageId", (request) {
    request["packageId"] = "COM EXAMPLE";
  });
  add("unknown strategy", "unknownStrategy", (request) {
    request["strategy"] = "recursiveCopy";
  });
  add("unknown provider", "unknownProvider", (request) {
    request["provider"] = "callerCommand";
  });
  add("strategy provider mismatch", "strategyProviderMismatch", (request) {
    request["provider"] = "apt";
  });
  add("missing target", "missingField:target", (request) {
    request.remove("target");
  });
  add("unknown target field", "unknownField:target.parentPath", (request) {
    _nested(request, "target")["parentPath"] = "/tmp";
  });
  add("unknown target class", "unknownTargetClass", (request) {
    _nested(request, "target")["class"] = "filesystemRoot";
  });
  add("strategy target mismatch", "strategyTargetMismatch", (request) {
    _nested(request, "target")["class"] = "systemPackage";
  });
  add("blank target path hint", "invalidString:target.pathHint", (request) {
    _nested(request, "target")["pathHint"] = "";
  });
  add("absolute sibling name", "invalidTargetNameHint", (request) {
    _nested(request, "target")["targetNameHint"] = "/tmp/backup";
  });
  add("relative path traversal", "invalidExecutableRelativePath", (request) {
    _nested(request, "target")["executableRelativePath"] = "../bin/example";
  });
  add("absolute executable proof", "invalidExecutableRelativePath", (request) {
    _nested(request, "target")["executableRelativePath"] = "/bin/example";
  });
  add("invalid target identity digest",
      "invalidSha256:target.identityProofSha256", (request) {
    _nested(request, "target")["identityProofSha256"] = "ABC";
  });
  add("blank current version", "invalidString:currentIdentity.version",
      (request) {
    _nested(request, "currentIdentity")["version"] = " ";
  });
  add("negative current build", "invalidInteger:currentIdentity.buildNumber",
      (request) {
    _nested(request, "currentIdentity")["buildNumber"] = -1;
  });
  add(
    "invalid current package identity digest",
    "invalidSha256:currentIdentity.packageIdentitySha256",
    (request) {
      _nested(request, "currentIdentity")["packageIdentitySha256"] = "0";
    },
  );
  add("blank desired version", "invalidString:desiredIdentity.version",
      (request) {
    _nested(request, "desiredIdentity")["version"] = "";
  });
  add("non-integer desired build", "invalidInteger:desiredIdentity.buildNumber",
      (request) {
    _nested(request, "desiredIdentity")["buildNumber"] = 2.8;
  });
  add(
    "invalid desired package identity digest",
    "invalidSha256:desiredIdentity.packageIdentitySha256",
    (request) {
      _nested(request, "desiredIdentity")["packageIdentitySha256"] =
          List<String>.filled(63, "f").join();
    },
  );
  add("blank stage path hint", "invalidString:stage.pathHint", (request) {
    _nested(request, "stage")["pathHint"] = "";
  });
  add("invalid stage ownership nonce", "invalidStageOwnershipNonce", (request) {
    _nested(request, "stage")["ownershipNonce"] = "short";
  });
  add("invalid stage provenance digest", "invalidSha256:stage.provenanceSha256",
      (request) {
    _nested(request, "stage")["provenanceSha256"] =
        List<String>.filled(64, "z").join();
  });
  add("invalid artifact digest", "invalidSha256:stage.artifactSha256",
      (request) {
    _nested(request, "stage")["artifactSha256"] =
        List<String>.filled(64, "A").join();
  });
  add("zero artifact length", "invalidInteger:stage.artifactLength", (request) {
    _nested(request, "stage")["artifactLength"] = 0;
  });
  add(
    "invalid descriptor binding digest",
    "invalidSha256:signedDescriptor.canonicalSha256",
    (request) {
      _nested(request, "signedDescriptor")["canonicalSha256"] = "bad";
    },
  );
  add(
    "unsupported descriptor signature algorithm",
    "unsupportedDescriptorSignatureAlgorithm",
    (request) {
      _nested(request, "signedDescriptor")["signatureAlgorithm"] = "rsa";
    },
  );
  add("invalid descriptor key ID", "invalidDescriptorKeyId", (request) {
    _nested(request, "signedDescriptor")["keyId"] = "caller key!";
  });
  add("invalid descriptor signature", "invalidDescriptorSignature", (request) {
    _nested(request, "signedDescriptor")["signatureBase64"] = "not-base64";
  });
  add("zero caller process ID", "invalidInteger:caller.processId", (request) {
    _nested(request, "caller")["processId"] = 0;
  });
  add("blank caller start identity",
      "invalidString:caller.processStartIdentity", (request) {
    _nested(request, "caller")["processStartIdentity"] = "";
  });
  add("invalid caller executable digest",
      "invalidSha256:caller.executableSha256", (request) {
    _nested(request, "caller")["executableSha256"] =
        List<String>.filled(65, "0").join();
  });
  add("invalid caller package ID", "invalidCallerPackageId", (request) {
    _nested(request, "caller")["packageId"] = "INVALID ID";
  });
  add("caller package mismatch", "callerPackageIdMismatch", (request) {
    _nested(request, "caller")["packageId"] = "com.example.other";
  });
  add("blank caller signer", "invalidString:caller.signerIdentity", (request) {
    _nested(request, "caller")["signerIdentity"] = "";
  });
  add("short request nonce", "invalidRequestNonce", (request) {
    request["requestNonce"] = "short";
  });
  add("unknown diagnostics kind", "invalidDiagnosticsDestination", (request) {
    _nested(request, "diagnosticsDestination")["kind"] = "callerFile";
  });
  add("invalid inherited diagnostics stream", "invalidDiagnosticsDestination",
      (request) {
    request["diagnosticsDestination"] = <String, Object?>{
      "kind": "inheritedStream",
      "stream": "stdout",
    };
  });
  add("caller supplied release trust root",
      "unknownField:releaseRootPublicKeys", (request) {
    request["releaseRootPublicKeys"] = <String>["attacker-key"];
  });
  add(
    "caller supplied allowed install root",
    "unknownField:signedDescriptor.allowedInstallRoots",
    (request) {
      _nested(request, "signedDescriptor")["allowedInstallRoots"] = <String>[
        "/",
      ];
    },
  );
  add("caller supplied prepared sibling", "unknownField:preparedPath",
      (request) {
    request["preparedPath"] = "/tmp/attacker-prepared";
  });
  add("unknown request field", "unknownField:command", (request) {
    request["command"] = "caller-supplied-command";
  });

  cases.add(<String, Object?>{
    "name": "duplicate request field",
    "rawJson": '{"schemaVersion":1,"schemaVersion":1}',
    "expectedFailure": "duplicateKey:schemaVersion",
  });
  return cases;
}

Map<String, Object?> _journalTransitionsFixture() {
  const transitions = <({String machine, String from, String to})>[
    (machine: "swap", from: "prepared", to: "backupCreated"),
    (machine: "swap", from: "backupCreated", to: "targetActivated"),
    (machine: "swap", from: "targetActivated", to: "completed"),
    (machine: "manager", from: "prepared", to: "managerStarted"),
    (
      machine: "manager",
      from: "managerStarted",
      to: "verificationPending",
    ),
    (
      machine: "manager",
      from: "verificationPending",
      to: "completed",
    ),
    (machine: "swap", from: "prepared", to: "rolledBack"),
    (machine: "swap", from: "backupCreated", to: "rolledBack"),
    (machine: "swap", from: "targetActivated", to: "rolledBack"),
    (
      machine: "swap",
      from: "prepared",
      to: "manualActionRequired",
    ),
    (
      machine: "swap",
      from: "backupCreated",
      to: "manualActionRequired",
    ),
    (
      machine: "swap",
      from: "targetActivated",
      to: "manualActionRequired",
    ),
    (
      machine: "manager",
      from: "managerStarted",
      to: "manualActionRequired",
    ),
    (
      machine: "manager",
      from: "verificationPending",
      to: "manualActionRequired",
    ),
  ];
  return <String, Object?>{
    "schemaVersion": 1,
    "states": <String>[
      "prepared",
      "backupCreated",
      "targetActivated",
      "managerStarted",
      "verificationPending",
      "completed",
      "rolledBack",
      "manualActionRequired",
    ],
    "validTransitions": <Map<String, String>>[
      for (final transition in transitions)
        <String, String>{
          "machine": transition.machine,
          "from": transition.from,
          "to": transition.to,
        },
    ],
    "invalidTransitions": <Map<String, String>>[
      <String, String>{
        "name": "swap skips durable backup",
        "machine": "swap",
        "from": "prepared",
        "to": "targetActivated",
      },
      <String, String>{
        "name": "manager invents file rollback",
        "machine": "manager",
        "from": "managerStarted",
        "to": "rolledBack",
      },
      <String, String>{
        "name": "terminal state is immutable",
        "machine": "swap",
        "from": "completed",
        "to": "prepared",
      },
    ],
    "recoveryCases": _recoveryCases(),
    "journal": <String, Object?>{
      "schemaVersion": 1,
      "transactionId": "00000000-0000-4000-8000-000000000001",
      "policyId": "com.example.desktop-updater",
      "packageId": "com.example.app",
      "strategy": "directoryReplace",
      "targetName": "example",
      "preparedName": ".example.desktop-updater-prepared-00000000",
      "backupName": ".example.desktop-updater-backup-00000000",
      "journalName": ".example.desktop-updater-journal-00000000.json",
      "lockName": ".example.desktop-updater-lock",
      "provenanceSha256": _shaE,
      "artifactSha256": _shaC,
      "ownerGeneration": 1,
      "state": "prepared",
      "evidence": <String, Object?>{
        "targetIdentitySha256": _shaA,
      },
    },
  };
}

List<Map<String, Object?>> _recoveryCases() {
  return <Map<String, Object?>>[
    _recoveryCase(
      "swap death before prepared journal durable",
      machine: "swap",
      state: "prepared",
      journalDurable: false,
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "journalNotDurable",
    ),
    _recoveryCase(
      "swap death after prepared durable",
      machine: "swap",
      state: "prepared",
      prepared: "verifiedNew",
      outcome: "verifiedOldTarget",
      action: "discardPrepared",
      cleanupAuthorized: true,
      reason: "preparedTargetAuthoritative",
    ),
    _recoveryCase(
      "swap death before backupCreated durable",
      machine: "swap",
      state: "prepared",
      prepared: "verifiedNew",
      outcome: "verifiedOldTarget",
      action: "discardPrepared",
      cleanupAuthorized: true,
      reason: "preparedTargetAuthoritative",
    ),
    _recoveryCase(
      "swap death after backupCreated durable",
      machine: "swap",
      state: "backupCreated",
      target: "missing",
      prepared: "verifiedNew",
      backup: "verifiedOld",
      outcome: "verifiedOldTarget",
      action: "restoreBackup",
      cleanupAuthorized: true,
      reason: "backupReadyToRestore",
    ),
    _recoveryCase(
      "swap death before targetActivated durable",
      machine: "swap",
      state: "backupCreated",
      target: "missing",
      prepared: "verifiedNew",
      backup: "verifiedOld",
      outcome: "verifiedOldTarget",
      action: "restoreBackup",
      cleanupAuthorized: true,
      reason: "backupReadyToRestore",
    ),
    _recoveryCase(
      "swap death after targetActivated durable",
      machine: "swap",
      state: "targetActivated",
      target: "verifiedNew",
      backup: "verifiedOld",
      outcome: "verifiedNewTarget",
      action: "acceptActivated",
      cleanupAuthorized: true,
      reason: "activatedTargetVerified",
    ),
    _recoveryCase(
      "swap death before completed durable",
      machine: "swap",
      state: "targetActivated",
      target: "verifiedNew",
      backup: "verifiedOld",
      outcome: "verifiedNewTarget",
      action: "acceptActivated",
      cleanupAuthorized: true,
      reason: "activatedTargetVerified",
    ),
    _recoveryCase(
      "swap death after completed durable",
      machine: "swap",
      state: "completed",
      target: "verifiedNew",
      outcome: "verifiedNewTarget",
      action: "none",
      cleanupAuthorized: true,
      reason: "completedTargetVerified",
    ),
    _recoveryCase(
      "manager death before prepared journal durable",
      machine: "manager",
      state: "prepared",
      journalDurable: false,
      manager: "verifiedOld",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "journalNotDurable",
    ),
    _recoveryCase(
      "manager death after prepared durable",
      machine: "manager",
      state: "prepared",
      manager: "verifiedOld",
      outcome: "verifiedOldTarget",
      action: "none",
      cleanupAuthorized: true,
      reason: "managerOldStateVerified",
    ),
    _recoveryCase(
      "manager death before managerStarted durable",
      machine: "manager",
      state: "prepared",
      manager: "verifiedOld",
      outcome: "verifiedOldTarget",
      action: "none",
      cleanupAuthorized: true,
      reason: "managerOldStateVerified",
    ),
    _recoveryCase(
      "manager death after managerStarted durable",
      machine: "manager",
      state: "managerStarted",
      manager: "pending",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "managerVerificationPending",
    ),
    _recoveryCase(
      "manager death before verificationPending durable",
      machine: "manager",
      state: "managerStarted",
      manager: "pending",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "managerVerificationPending",
    ),
    _recoveryCase(
      "manager death after verificationPending durable",
      machine: "manager",
      state: "verificationPending",
      manager: "pending",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "managerVerificationPending",
    ),
    _recoveryCase(
      "manager death before completed durable",
      machine: "manager",
      state: "verificationPending",
      manager: "verifiedNew",
      outcome: "verifiedNewTarget",
      action: "acceptManagerState",
      cleanupAuthorized: true,
      reason: "managerNewStateVerified",
    ),
    _recoveryCase(
      "manager death after completed durable",
      machine: "manager",
      state: "completed",
      manager: "verifiedNew",
      outcome: "verifiedNewTarget",
      action: "none",
      cleanupAuthorized: true,
      reason: "completedManagerStateVerified",
    ),
    _recoveryCase(
      "repeated recovery after rollback",
      machine: "swap",
      state: "rolledBack",
      outcome: "verifiedOldTarget",
      action: "none",
      cleanupAuthorized: true,
      reason: "rollbackVerified",
    ),
    _recoveryCase(
      "repeated recovery after completion",
      machine: "swap",
      state: "completed",
      target: "verifiedNew",
      outcome: "verifiedNewTarget",
      action: "none",
      cleanupAuthorized: true,
      reason: "completedTargetVerified",
    ),
    _recoveryCase(
      "live owner recovery rejection",
      machine: "swap",
      state: "prepared",
      ownerLive: true,
      prepared: "verifiedNew",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "transactionBusy",
    ),
    _recoveryCase(
      "torn journal write",
      machine: "swap",
      state: "backupCreated",
      envelopeValid: false,
      target: "missing",
      backup: "verifiedOld",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "journalCorrupt",
    ),
    _recoveryCase(
      "short journal write",
      machine: "swap",
      state: "targetActivated",
      envelopeValid: false,
      target: "verifiedNew",
      backup: "verifiedOld",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "journalCorrupt",
    ),
    _recoveryCase(
      "disk full before journal replacement",
      machine: "swap",
      state: "backupCreated",
      journalDurable: false,
      target: "missing",
      backup: "verifiedOld",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "journalNotDurable",
    ),
    _recoveryCase(
      "directory flush failure",
      machine: "swap",
      state: "backupCreated",
      directoryFlushSucceeded: false,
      target: "missing",
      backup: "verifiedOld",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "journalDirectoryFlushFailed",
    ),
    _recoveryCase(
      "corrupt journal",
      machine: "swap",
      state: "prepared",
      envelopeValid: false,
      prepared: "verifiedNew",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "journalCorrupt",
    ),
    _recoveryCase(
      "unknown journal version",
      machine: "swap",
      state: "prepared",
      schemaVersion: 2,
      prepared: "verifiedNew",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "unsupportedJournalVersion",
    ),
    _recoveryCase(
      "injected prepared sibling name",
      machine: "swap",
      state: "prepared",
      siblingNamesMatch: false,
      prepared: "verifiedNew",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "siblingNameMismatch",
    ),
    _recoveryCase(
      "owner generation mismatch",
      machine: "swap",
      state: "prepared",
      observedOwnerGeneration: 2,
      prepared: "verifiedNew",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "ownerGenerationMismatch",
    ),
    _recoveryCase(
      "ambiguous target and backup state",
      machine: "swap",
      state: "backupCreated",
      observationsUnambiguous: false,
      backup: "verifiedOld",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "ambiguousObservedState",
    ),
    _recoveryCase(
      "activated target fails verification with valid backup",
      machine: "swap",
      state: "targetActivated",
      target: "unknown",
      backup: "verifiedOld",
      outcome: "verifiedOldTarget",
      action: "restoreBackup",
      cleanupAuthorized: true,
      reason: "activatedTargetRejected",
    ),
    _recoveryCase(
      "package manager state is unknown",
      machine: "manager",
      state: "verificationPending",
      manager: "unknown",
      outcome: "manualActionRequired",
      action: "none",
      cleanupAuthorized: false,
      reason: "managerStateUnknown",
    ),
  ];
}

Map<String, Object?> _recoveryCase(
  String name, {
  required String machine,
  required String state,
  required String outcome,
  required String action,
  required bool cleanupAuthorized,
  required String reason,
  int schemaVersion = 1,
  int ownerGeneration = 1,
  bool envelopeValid = true,
  bool journalDurable = true,
  bool directoryFlushSucceeded = true,
  bool ownerLive = false,
  int observedOwnerGeneration = 1,
  bool siblingNamesMatch = true,
  bool observationsUnambiguous = true,
  String target = "verifiedOld",
  String prepared = "missing",
  String backup = "missing",
  String manager = "notApplicable",
}) {
  return <String, Object?>{
    "name": name,
    "journal": <String, Object?>{
      "schemaVersion": schemaVersion,
      "machine": machine,
      "state": state,
      "ownerGeneration": ownerGeneration,
      "envelopeValid": envelopeValid,
    },
    "observed": <String, Object?>{
      "journalDurable": journalDurable,
      "directoryFlushSucceeded": directoryFlushSucceeded,
      "ownerLive": ownerLive,
      "observedOwnerGeneration": observedOwnerGeneration,
      "siblingNamesMatch": siblingNamesMatch,
      "observationsUnambiguous": observationsUnambiguous,
      "target": target,
      "prepared": prepared,
      "backup": backup,
      "manager": manager,
    },
    "expected": <String, Object?>{
      "outcome": outcome,
      "action": action,
      "cleanupAuthorized": cleanupAuthorized,
      "reason": reason,
    },
  };
}

Map<String, Object?> _diagnosticResultsFixture() {
  final events = <Map<String, Object?>>[
    for (var index = 0;
        index < nativeInstallHelperDiagnosticEvents.length;
        index += 1)
      <String, Object?>{
        "sequence": index,
        "name": nativeInstallHelperDiagnosticEvents[index],
        "detailCode": _diagnosticDetailCode(index),
      },
  ];
  final reservation = <String, Object?>{
    "protocolVersion": 1,
    "transactionId": "00000000-0000-4000-8000-000000000001",
    "readyToken": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "journalSha256": _shaA,
    "helperEndpointIdentitySha256": _shaB,
    "expiresAtUnixMilliseconds": 1783987200000,
  };
  final transactionStatus = <String, Object?>{
    "protocolVersion": 1,
    "transactionId": "00000000-0000-4000-8000-000000000001",
    "state": "completed",
    "resultCode": "completed",
    "journalSha256": _shaA,
  };
  final recoveryResult = <String, Object?>{
    "protocolVersion": 1,
    "transactionId": "00000000-0000-4000-8000-000000000001",
    "resultCode": "rolledBack",
    "verifiedOutcome": "oldTarget",
    "journalSha256": _shaA,
  };
  final diagnosticResult = <String, Object?>{
    "schemaVersion": 1,
    "transactionId": "00000000-0000-4000-8000-000000000001",
    "resultCode": "completed",
    "events": events,
  };
  final invalidResults = <Map<String, Object?>>[
    _invalidResult(
      "reservation.protocolVersion",
      reservation,
      "unsupportedProtocolVersion",
      (candidate) => candidate["protocolVersion"] = 2,
    ),
    _invalidResult(
      "reservation.transactionId",
      reservation,
      "invalidTransactionId",
      (candidate) => candidate["transactionId"] = "UPPERCASE",
    ),
    _invalidResult(
      "reservation.readyToken",
      reservation,
      "invalidReadyToken",
      (candidate) => candidate["readyToken"] = "short",
    ),
    _invalidResult(
      "reservation.journalSha256",
      reservation,
      "invalidSha256:reservation.journalSha256",
      (candidate) => candidate["journalSha256"] = "bad",
    ),
    _invalidResult(
      "reservation.helperEndpointIdentitySha256",
      reservation,
      "invalidSha256:reservation.helperEndpointIdentitySha256",
      (candidate) => candidate["helperEndpointIdentitySha256"] = "bad",
    ),
    _invalidResult(
      "reservation.expiresAtUnixMilliseconds",
      reservation,
      "invalidInteger:reservation.expiresAtUnixMilliseconds",
      (candidate) => candidate["expiresAtUnixMilliseconds"] = -1,
    ),
    _invalidResult(
      "transactionStatus.protocolVersion",
      transactionStatus,
      "unsupportedProtocolVersion",
      (candidate) => candidate["protocolVersion"] = 2,
    ),
    _invalidResult(
      "transactionStatus.transactionId",
      transactionStatus,
      "invalidTransactionId",
      (candidate) => candidate["transactionId"] = "bad",
    ),
    _invalidResult(
      "transactionStatus.state",
      transactionStatus,
      "unknownJournalState",
      (candidate) => candidate["state"] = "cleaned",
    ),
    _invalidResult(
      "transactionStatus.resultCode",
      transactionStatus,
      "unknownResultCode",
      (candidate) => candidate["resultCode"] = "success",
    ),
    _invalidResult(
      "transactionStatus.journalSha256",
      transactionStatus,
      "invalidSha256:transactionStatus.journalSha256",
      (candidate) => candidate["journalSha256"] = "bad",
    ),
    _invalidResult(
      "recoveryResult.protocolVersion",
      recoveryResult,
      "unsupportedProtocolVersion",
      (candidate) => candidate["protocolVersion"] = 2,
    ),
    _invalidResult(
      "recoveryResult.transactionId",
      recoveryResult,
      "invalidTransactionId",
      (candidate) => candidate["transactionId"] = "bad",
    ),
    _invalidResult(
      "recoveryResult.resultCode",
      recoveryResult,
      "unknownResultCode",
      (candidate) => candidate["resultCode"] = "success",
    ),
    _invalidResult(
      "recoveryResult.verifiedOutcome",
      recoveryResult,
      "unknownVerifiedOutcome",
      (candidate) => candidate["verifiedOutcome"] = "maybe",
    ),
    _invalidResult(
      "recoveryResult.journalSha256",
      recoveryResult,
      "invalidSha256:recoveryResult.journalSha256",
      (candidate) => candidate["journalSha256"] = "bad",
    ),
    _invalidResult(
      "diagnosticResult.schemaVersion",
      diagnosticResult,
      "unsupportedSchemaVersion",
      (candidate) => candidate["schemaVersion"] = 2,
    ),
    _invalidResult(
      "diagnosticResult.transactionId",
      diagnosticResult,
      "invalidTransactionId",
      (candidate) => candidate["transactionId"] = "bad",
    ),
    _invalidResult(
      "diagnosticResult.resultCode",
      diagnosticResult,
      "unknownResultCode",
      (candidate) => candidate["resultCode"] = "success",
    ),
    _invalidResult(
      "diagnosticResult.events",
      diagnosticResult,
      "invalidType:diagnosticResult.events",
      (candidate) => candidate["events"] = "not-an-array",
    ),
    _invalidDiagnosticEvent(
      "diagnosticEvent.sequence",
      diagnosticResult,
      "invalidInteger:diagnosticEvent.sequence",
      (event) => event["sequence"] = -1,
    ),
    _invalidDiagnosticEvent(
      "diagnosticEvent.name",
      diagnosticResult,
      "unknownDiagnosticEvent",
      (event) => event["name"] = "raw path emitted",
    ),
    _invalidDiagnosticEvent(
      "diagnosticEvent.detailCode",
      diagnosticResult,
      "invalidDiagnosticDetailCode",
      (event) => event["detailCode"] = "/Users/example/secret",
    ),
  ];
  return <String, Object?>{
    "schemaVersion": 1,
    "events": nativeInstallHelperDiagnosticEvents,
    "resultCodes": nativeInstallHelperResultCodes,
    "reservation": reservation,
    "transactionStatus": transactionStatus,
    "recoveryResult": recoveryResult,
    "coveredResultFields": <String>[
      for (final entry in invalidResults) entry["field"]! as String,
    ],
    "invalidResults": invalidResults,
    "diagnosticResults": <Map<String, Object?>>[
      for (final resultCode in nativeInstallHelperResultCodes)
        <String, Object?>{
          "schemaVersion": 1,
          "transactionId": "00000000-0000-4000-8000-000000000001",
          "resultCode": resultCode,
          "events": events,
        },
    ],
    "redactionRules": <String>[
      "never emit readyToken or requestNonce",
      "never emit release keys, signatures, headers, or credentials",
      "replace full user paths with target class and basename",
      "retain transaction ID, state, package ID, event name, and detail code",
    ],
  };
}

Map<String, Object?> _invalidResult(
  String field,
  Map<String, Object?> source,
  String expectedFailure,
  void Function(Map<String, dynamic>) mutate,
) {
  final candidate = _copyMap(source);
  mutate(candidate);
  return <String, Object?>{
    "field": field,
    "candidate": candidate,
    "expectedFailure": expectedFailure,
  };
}

Map<String, Object?> _invalidDiagnosticEvent(
  String field,
  Map<String, Object?> source,
  String expectedFailure,
  void Function(Map<String, dynamic>) mutate,
) {
  final candidate = _copyMap(source);
  final events = candidate["events"]! as List<dynamic>;
  mutate(events.first as Map<String, dynamic>);
  return <String, Object?>{
    "field": field,
    "candidate": candidate,
    "expectedFailure": expectedFailure,
  };
}

String _diagnosticDetailCode(int index) {
  const values = <String>[
    "helperAuthenticated",
    "targetLockAcquired",
    "journalPersisted",
    "callerExitObserved",
    "recoveryDetected",
    "backupRestored",
    "activationVerified",
    "packageManagerVerified",
    "manualActionRequired",
    "transactionCompleted",
  ];
  return values[index];
}

Map<String, Object?> _canonicalJsonFixture() {
  return <String, Object?>{
    "schemaVersion": 1,
    "encoding": "UTF-8",
    "keyOrder": "ascending Unicode scalar value (equivalent UTF-8 byte order)",
    "cases": <Map<String, Object?>>[
      <String, Object?>{
        "name": "sorts nested object keys by Unicode scalar value",
        "inputJson": '{"😀":1,"a":{"z":2,"ä":3,"b":1},"Z":0}',
        "canonicalJson": '{"Z":0,"a":{"b":1,"z":2,"ä":3},"😀":1}',
      },
      <String, Object?>{
        "name": "preserves large integer values",
        "inputJson": '{"value":9007199254740993,"small":1}',
        "canonicalJson": '{"small":1,"value":9007199254740993}',
      },
      <String, Object?>{
        "name": "rejects duplicate object keys",
        "inputJson": '{"a":1,"a":2}',
        "expectedFailure": "duplicateKey:a",
      },
    ],
  };
}

Map<String, dynamic> _copyMap(Object value) {
  return Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
}

Map<String, dynamic> _nested(Map<String, dynamic> source, String key) {
  return source[key]! as Map<String, dynamic>;
}

void _requireExactKeys(
  Map<String, dynamic> value, {
  required Set<String> required,
  Set<String> optional = const <String>{},
  String path = "",
}) {
  for (final key in required) {
    if (!value.containsKey(key)) {
      throw NativeInstallHelperContractFailure(
        "missingField:${_field(path, key)}",
      );
    }
  }
  final allowed = <String>{...required, ...optional};
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw NativeInstallHelperContractFailure(
        "unknownField:${_field(path, key)}",
      );
    }
  }
}

String _field(String path, String key) => path.isEmpty ? key : "$path.$key";

Map<String, dynamic> _requireMap(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw NativeInstallHelperContractFailure("invalidType:$field");
  }
  return value;
}

String _requirePattern(
  Object? value,
  String field,
  RegExp pattern,
  String failure,
) {
  if (value is! String) {
    throw NativeInstallHelperContractFailure("invalidType:$field");
  }
  if (!pattern.hasMatch(value)) {
    throw NativeInstallHelperContractFailure(failure);
  }
  return value;
}

String _requireEnum(
  Object? value,
  String field,
  Set<String> allowed,
  String failure,
) {
  if (value is! String) {
    throw NativeInstallHelperContractFailure("invalidType:$field");
  }
  if (!allowed.contains(value)) {
    throw NativeInstallHelperContractFailure(failure);
  }
  return value;
}

String _requireBoundedString(Object? value, String field, {required int max}) {
  if (value is! String) {
    throw NativeInstallHelperContractFailure("invalidType:$field");
  }
  if (value.trim().isEmpty || value.length > max) {
    throw NativeInstallHelperContractFailure("invalidString:$field");
  }
  return value;
}

void _requireInteger(
  Object? value,
  String field, {
  required int minimum,
  int? maximum,
}) {
  if (value is! int ||
      value < minimum ||
      (maximum != null && value > maximum)) {
    throw NativeInstallHelperContractFailure("invalidInteger:$field");
  }
}

void _requireSha256(Object? value, String field) {
  _requirePattern(value, field, _sha256Pattern, "invalidSha256:$field");
}

void _requireSafeSiblingName(Object? value, String field) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 255 ||
      value == "." ||
      value == ".." ||
      value.contains("/") ||
      value.contains(r"\") ||
      value.contains(":")) {
    throw const NativeInstallHelperContractFailure("invalidTargetNameHint");
  }
}

void _requireSafeRelativePath(Object? value, String field) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 1024 ||
      value.startsWith("/") ||
      value.contains(r"\") ||
      RegExp(r"^[A-Za-z]:").hasMatch(value)) {
    throw const NativeInstallHelperContractFailure(
      "invalidExecutableRelativePath",
    );
  }
  final segments = value.split("/");
  if (segments.any(
    (segment) => segment.isEmpty || segment == "." || segment == "..",
  )) {
    throw const NativeInstallHelperContractFailure(
      "invalidExecutableRelativePath",
    );
  }
}

Future<void> _writeJson(File file, Object? value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString("${_jsonEncoder.convert(_sortJson(value))}\n");
}

Future<Map<String, List<int>>> _readTree(Directory root) async {
  final files = <String, List<int>>{};
  if (!root.existsSync()) {
    return files;
  }
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final relative =
          path.relative(entity.path, from: root.path).replaceAll(r"\", "/");
      files[relative] = await entity.readAsBytes();
    }
  }
  return Map<String, List<int>>.fromEntries(
    files.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key)),
  );
}

bool _treeContains(
  Map<String, List<int>> actual,
  Map<String, List<int>> expected,
) {
  for (final entry in expected.entries) {
    final other = actual[entry.key];
    if (other == null) {
      return false;
    }
    if (entry.value.length != other.length) {
      return false;
    }
    for (var index = 0; index < entry.value.length; index += 1) {
      if (entry.value[index] != other[index]) {
        return false;
      }
    }
  }
  return true;
}

const _coveredRequestFields = <String>[
  "schemaVersion",
  "protocolVersion",
  "transactionId",
  "policyId",
  "packageId",
  "strategy",
  "provider",
  "target.class",
  "target.pathHint",
  "target.targetNameHint",
  "target.executableRelativePath",
  "target.identityProofSha256",
  "currentIdentity.version",
  "currentIdentity.buildNumber",
  "currentIdentity.packageIdentitySha256",
  "desiredIdentity.version",
  "desiredIdentity.buildNumber",
  "desiredIdentity.packageIdentitySha256",
  "stage.pathHint",
  "stage.ownershipNonce",
  "stage.provenanceSha256",
  "stage.artifactSha256",
  "stage.artifactLength",
  "signedDescriptor.canonicalSha256",
  "signedDescriptor.signatureAlgorithm",
  "signedDescriptor.keyId",
  "signedDescriptor.signatureBase64",
  "caller.processId",
  "caller.processStartIdentity",
  "caller.executableSha256",
  "caller.packageId",
  "caller.signerIdentity",
  "requestNonce",
  "diagnosticsDestination.kind",
  "diagnosticsDestination.stream",
];

final _lowercaseUuidPattern = RegExp(
  r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
);
final _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");
final _readyTokenPattern = RegExp(r"^[A-Za-z0-9_-]{43}$");
final _dottedIdentifierPattern = RegExp(
  r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{1,126}[A-Za-z0-9])?$",
);
final _keyIdPattern = RegExp(r"^[A-Za-z0-9._-]{1,128}$");
final _signaturePattern = RegExp(r"^[A-Za-z0-9+/]{86}==$");

const _providers = <String>{
  "platformDirectory",
  "platformFile",
  "macosInstaller",
  "windowsInno",
  "apt",
  "dnf",
  "flatpak",
  "snap",
};

const _strategyProviders = <String, Set<String>>{
  "directoryReplace": <String>{"platformDirectory"},
  "singleFileReplace": <String>{"platformFile"},
  "verifiedInstallerHandoff": <String>{"macosInstaller", "windowsInno"},
  "systemPackageTransaction": <String>{"apt", "dnf"},
  "externalManagedRefresh": <String>{"flatpak", "snap"},
};

const _targetClasses = <String>{
  "applicationBundle",
  "applicationDirectory",
  "singleExecutable",
  "systemPackage",
  "externalManaged",
};

const _strategyTargetClasses = <String, Set<String>>{
  "directoryReplace": <String>{"applicationBundle", "applicationDirectory"},
  "singleFileReplace": <String>{"singleExecutable"},
  "verifiedInstallerHandoff": <String>{
    "applicationBundle",
    "applicationDirectory",
  },
  "systemPackageTransaction": <String>{"systemPackage"},
  "externalManagedRefresh": <String>{"externalManaged"},
};

final class NativeInstallHelperContractFailure implements Exception {
  const NativeInstallHelperContractFailure(this.code);

  final String code;

  @override
  String toString() => code;
}

final class _DuplicateKeyScanner {
  _DuplicateKeyScanner(this.source);

  final String source;
  int _index = 0;

  void scan() {
    _skipWhitespace();
    _scanValue();
    _skipWhitespace();
    if (_index != source.length) {
      _invalid();
    }
  }

  void _scanValue() {
    if (_index >= source.length) {
      _invalid();
    }
    switch (source.codeUnitAt(_index)) {
      case 0x7b:
        _scanObject();
      case 0x5b:
        _scanArray();
      case 0x22:
        _scanString();
      case 0x74:
        _scanLiteral("true");
      case 0x66:
        _scanLiteral("false");
      case 0x6e:
        _scanLiteral("null");
      default:
        _scanNumber();
    }
  }

  void _scanObject() {
    _index += 1;
    _skipWhitespace();
    if (_consume(0x7d)) {
      return;
    }
    final keys = <String>{};
    while (true) {
      if (_index >= source.length || source.codeUnitAt(_index) != 0x22) {
        _invalid();
      }
      final key = _scanString();
      if (!keys.add(key)) {
        throw NativeInstallHelperContractFailure("duplicateKey:$key");
      }
      _skipWhitespace();
      if (!_consume(0x3a)) {
        _invalid();
      }
      _skipWhitespace();
      _scanValue();
      _skipWhitespace();
      if (_consume(0x7d)) {
        return;
      }
      if (!_consume(0x2c)) {
        _invalid();
      }
      _skipWhitespace();
    }
  }

  void _scanArray() {
    _index += 1;
    _skipWhitespace();
    if (_consume(0x5d)) {
      return;
    }
    while (true) {
      _scanValue();
      _skipWhitespace();
      if (_consume(0x5d)) {
        return;
      }
      if (!_consume(0x2c)) {
        _invalid();
      }
      _skipWhitespace();
    }
  }

  String _scanString() {
    final start = _index;
    _index += 1;
    var escaped = false;
    while (_index < source.length) {
      final codeUnit = source.codeUnitAt(_index);
      _index += 1;
      if (escaped) {
        escaped = false;
        if (codeUnit == 0x75) {
          for (var count = 0; count < 4; count += 1) {
            if (_index >= source.length || !_isHex(source.codeUnitAt(_index))) {
              _invalid();
            }
            _index += 1;
          }
        } else if (!const <int>{
          0x22,
          0x5c,
          0x2f,
          0x62,
          0x66,
          0x6e,
          0x72,
          0x74,
        }.contains(codeUnit)) {
          _invalid();
        }
        continue;
      }
      if (codeUnit == 0x5c) {
        escaped = true;
      } else if (codeUnit == 0x22) {
        final literal = source.substring(start, _index);
        try {
          return jsonDecode(literal) as String;
        } on FormatException {
          _invalid();
        }
      } else if (codeUnit < 0x20) {
        _invalid();
      }
    }
    _invalid();
  }

  void _scanLiteral(String literal) {
    if (!source.startsWith(literal, _index)) {
      _invalid();
    }
    _index += literal.length;
  }

  void _scanNumber() {
    final match = _numberPattern.matchAsPrefix(source, _index);
    if (match == null) {
      _invalid();
    }
    _index = match.end;
  }

  void _skipWhitespace() {
    while (_index < source.length &&
        const <int>{0x20, 0x0a, 0x0d, 0x09}
            .contains(source.codeUnitAt(_index))) {
      _index += 1;
    }
  }

  bool _consume(int codeUnit) {
    if (_index < source.length && source.codeUnitAt(_index) == codeUnit) {
      _index += 1;
      return true;
    }
    return false;
  }

  Never _invalid() {
    throw const NativeInstallHelperContractFailure("invalidJson");
  }
}

bool _isHex(int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}

final _numberPattern = RegExp(
  r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?",
);
