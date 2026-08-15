import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "support/dart_cli.dart";

void main() {
  const fixtureRoot = "fixtures/compat/native-install-helper/v1";
  const generatorPath = "tool/generate_native_install_helper_fixtures.dart";

  test("helper protocol schema, fixtures, generator, and docs exist", () {
    for (final requiredPath in <String>[
      "schemas/native-install-helper-v1.schema.json",
      "$fixtureRoot/valid-requests.json",
      "$fixtureRoot/invalid-requests.json",
      "$fixtureRoot/journal-transitions.json",
      "$fixtureRoot/diagnostic-results.json",
      "$fixtureRoot/canonical-json.json",
      generatorPath,
      "docs/native-install-helper-protocol.md",
    ]) {
      expect(
        File(requiredPath).existsSync(),
        isTrue,
        reason: "$requiredPath must exist",
      );
    }
  });

  test("helper protocol fixture generation is byte-for-byte deterministic",
      () async {
    final root = await Directory.systemTemp.createTemp("helper_contract_");
    final first = Directory(path.join(root.path, "first"));
    final second = Directory(path.join(root.path, "second"));
    try {
      await _runGenerator(generatorPath, <String>["--output", first.path]);
      await _runGenerator(generatorPath, <String>["--output", second.path]);

      expect(await _readTree(first), await _readTree(second));
      expect(await _readTree(first), await _readTree(Directory(fixtureRoot)));
    } finally {
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("request schema seals every authority-bearing object", () async {
    final schema = await _readJson(
      "schemas/native-install-helper-v1.schema.json",
    );
    expect(schema[r"$schema"], contains("2020-12"));
    expect(schema["type"], "object");
    expect(schema["additionalProperties"], isFalse);
    expect(
      (schema["required"] as List).cast<String>(),
      containsAll(<String>[
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
      ]),
    );

    final definitions = Map<String, dynamic>.from(schema[r"$defs"] as Map);
    for (final name in <String>[
      "target",
      "versionIdentity",
      "stage",
      "signedDescriptor",
      "caller",
      "diagnosticsDestination",
      "reservation",
      "journal",
      "transactionStatus",
      "recoveryResult",
      "diagnosticResult",
    ]) {
      final definition = Map<String, dynamic>.from(definitions[name] as Map);
      expect(
        definition["additionalProperties"],
        isFalse,
        reason: "${r"$defs"}.$name must reject unknown fields",
      );
    }
  });

  test("every generated valid request passes the strict validator", () async {
    final fixture = await _readJson("$fixtureRoot/valid-requests.json");
    final cases = _mapList(fixture, "cases");
    expect(
      cases.map((entry) => entry["strategy"]),
      containsAll(<String>[
        "directoryReplace",
        "singleFileReplace",
        "verifiedInstallerHandoff",
        "systemPackageTransaction",
        "externalManagedRefresh",
      ]),
    );

    for (final entry in cases) {
      final result = await _validateRequest(
        generatorPath,
        jsonEncode(entry["request"]),
      );
      expect(
        result.exitCode,
        0,
        reason: _processReason(entry["name"] as String, result),
      );
      expect((result.stdout as String).trim(), "valid");
      expect(result.stderr, isEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    "every generated invalid request has a stable failure",
    () async {
      final fixture = await _readJson("$fixtureRoot/invalid-requests.json");
      final cases = _mapList(fixture, "cases");
      expect(cases, isNotEmpty);

      for (final entry in cases) {
        final result = await _validateRequest(
          generatorPath,
          entry["rawJson"] as String? ?? jsonEncode(entry["request"]),
        );
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
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test("canonical JSON is UTF-8, sorted, integer-preserving, and strict",
      () async {
    final fixture = await _readJson("$fixtureRoot/canonical-json.json");
    final cases = _mapList(fixture, "cases");
    expect(
      cases.map((entry) => entry["name"]),
      containsAll(<String>[
        "sorts nested object keys by Unicode scalar value",
        "preserves large integer values",
        "rejects duplicate object keys",
      ]),
    );

    for (final entry in cases) {
      final result = await _canonicalize(
        generatorPath,
        entry["inputJson"] as String,
      );
      final expectedFailure = entry["expectedFailure"] as String?;
      if (expectedFailure != null) {
        expect(
          result.exitCode,
          1,
          reason: _processReason(entry["name"] as String, result),
        );
        expect(result.stdout, isEmpty);
        expect((result.stderr as String).trim(), expectedFailure);
      } else {
        expect(
          result.exitCode,
          0,
          reason: _processReason(entry["name"] as String, result),
        );
        expect((result.stdout as String).trim(), entry["canonicalJson"]);
        expect(result.stderr, isEmpty);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("journal fixtures contain only normative state transitions", () async {
    final fixture = await _readJson("$fixtureRoot/journal-transitions.json");
    final transitions = _mapList(fixture, "validTransitions");
    const normative = <String>{
      "prepared->backupCreated",
      "backupCreated->targetActivated",
      "targetActivated->completed",
      "prepared->managerStarted",
      "managerStarted->verificationPending",
      "verificationPending->completed",
      "prepared->rolledBack",
      "backupCreated->rolledBack",
      "targetActivated->rolledBack",
      "prepared->manualActionRequired",
      "backupCreated->manualActionRequired",
      "targetActivated->manualActionRequired",
      "managerStarted->manualActionRequired",
      "verificationPending->manualActionRequired",
    };

    final actual =
        transitions.map((entry) => "${entry["from"]}->${entry["to"]}").toSet();
    expect(actual, isNotEmpty);
    expect(actual.difference(normative), isEmpty);
    expect(
      actual,
      containsAll(<String>[
        "prepared->backupCreated",
        "backupCreated->targetActivated",
        "targetActivated->completed",
        "prepared->managerStarted",
        "managerStarted->verificationPending",
        "verificationPending->completed",
      ]),
    );
  });

  test("diagnostic fixtures freeze every event and result code", () async {
    final fixture = await _readJson("$fixtureRoot/diagnostic-results.json");
    expect(
      (fixture["events"] as List).cast<String>().toSet(),
      <String>{
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
      },
    );
    expect(
      (fixture["resultCodes"] as List).cast<String>().toSet(),
      <String>{
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
      },
    );
    expect(
      Map<String, dynamic>.from(fixture["reservation"] as Map).keys,
      containsAll(<String>[
        "protocolVersion",
        "transactionId",
        "readyToken",
        "journalSha256",
        "helperEndpointIdentitySha256",
        "expiresAtUnixMilliseconds",
      ]),
    );
    expect(
      Map<String, dynamic>.from(fixture["transactionStatus"] as Map).keys,
      containsAll(<String>[
        "protocolVersion",
        "transactionId",
        "state",
        "resultCode",
        "journalSha256",
      ]),
    );
    expect(
      Map<String, dynamic>.from(fixture["recoveryResult"] as Map).keys,
      containsAll(<String>[
        "protocolVersion",
        "transactionId",
        "resultCode",
        "verifiedOutcome",
        "journalSha256",
      ]),
    );
  });

  test(
      "fixtures record adversarial coverage for every request and result field",
      () async {
    final invalidRequests =
        await _readJson("$fixtureRoot/invalid-requests.json");
    expect(
      (invalidRequests["coveredRequestFields"] as List).cast<String>().toSet(),
      <String>{
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
      },
    );

    final diagnosticResults =
        await _readJson("$fixtureRoot/diagnostic-results.json");
    final covered = (diagnosticResults["coveredResultFields"] as List)
        .cast<String>()
        .toSet();
    final invalidCases = _mapList(diagnosticResults, "invalidResults");
    expect(invalidCases.map((entry) => entry["field"]).toSet(), covered);
    expect(
      covered,
      <String>{
        "reservation.protocolVersion",
        "reservation.transactionId",
        "reservation.readyToken",
        "reservation.journalSha256",
        "reservation.helperEndpointIdentitySha256",
        "reservation.expiresAtUnixMilliseconds",
        "transactionStatus.protocolVersion",
        "transactionStatus.transactionId",
        "transactionStatus.state",
        "transactionStatus.resultCode",
        "transactionStatus.journalSha256",
        "recoveryResult.protocolVersion",
        "recoveryResult.transactionId",
        "recoveryResult.resultCode",
        "recoveryResult.verifiedOutcome",
        "recoveryResult.journalSha256",
        "diagnosticResult.schemaVersion",
        "diagnosticResult.transactionId",
        "diagnosticResult.resultCode",
        "diagnosticResult.events",
        "diagnosticEvent.sequence",
        "diagnosticEvent.name",
        "diagnosticEvent.detailCode",
      },
    );
    for (final entry in invalidCases) {
      expect(entry["candidate"], isA<Map>());
      expect(entry["expectedFailure"], isA<String>());
      expect(entry["expectedFailure"], isNotEmpty);
    }
  });
}

Future<ProcessResult> _validateRequest(
  String generatorPath,
  String requestJson,
) async {
  final root = await Directory.systemTemp.createTemp("helper_request_");
  try {
    final input = File(path.join(root.path, "request.json"));
    await input.writeAsString(requestJson);
    return await _runGeneratorResult(
      generatorPath,
      <String>["--validate-request", input.path],
    );
  } finally {
    await root.delete(recursive: true);
  }
}

String _processReason(String name, ProcessResult result) {
  return "$name\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}";
}

Future<ProcessResult> _canonicalize(
  String generatorPath,
  String inputJson,
) async {
  final root = await Directory.systemTemp.createTemp("helper_canonical_");
  try {
    final input = File(path.join(root.path, "input.json"));
    await input.writeAsString(inputJson);
    return await _runGeneratorResult(
      generatorPath,
      <String>["--canonicalize", input.path],
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _runGenerator(String generatorPath, List<String> arguments) async {
  final result = await _runGeneratorResult(generatorPath, arguments);
  expect(
    result.exitCode,
    0,
    reason: "${result.stdout}\n${result.stderr}",
  );
}

Future<ProcessResult> _runGeneratorResult(
  String generatorPath,
  List<String> arguments,
) {
  return Process.run(
    resolveDartExecutable(),
    <String>[generatorPath, ...arguments],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: <String, String>{
      ...Platform.environment,
      "DART_TOOL_DISABLE_ANALYTICS": "1",
    },
  );
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

Future<Map<String, List<int>>> _readTree(Directory root) async {
  const generatedContractFixtures = <String>{
    "canonical-json.json",
    "diagnostic-results.json",
    "invalid-requests.json",
    "journal-transitions.json",
    "valid-requests.json",
  };
  final files = <String, List<int>>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final relative =
          path.relative(entity.path, from: root.path).replaceAll(r"\", "/");
      if (!generatedContractFixtures.contains(relative)) {
        continue;
      }
      files[relative] = await entity.readAsBytes();
    }
  }
  return Map<String, List<int>>.fromEntries(
    files.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key)),
  );
}
