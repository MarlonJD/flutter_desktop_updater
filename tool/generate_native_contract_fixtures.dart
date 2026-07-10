import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/update_diagnostics.dart";
import "package:desktop_updater/src/io/archive_path.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:path/path.dart" as path;

const _fixtureRoot = "fixtures/compat/native-contract";
const _publicKeyId = "native-contract-stable";
const _jsonEncoder = JsonEncoder.withIndent("  ");
final _generatedAt = DateTime.utc(2026, 7, 10);

const _helperEvents = <String>[
  "helper scheduled",
  "waiting for parent process",
  "parent process exited",
  "staging path validation",
  "backup start",
  "backup success",
  "backup failure",
  "move start",
  "move success",
  "move failure",
  "rollback start",
  "rollback success",
  "rollback failure",
  "cleanup start",
  "cleanup success",
  "cleanup failure",
  "relaunch attempt",
];

Future<void> main(List<String> arguments) async {
  var check = false;
  String? outputPath;
  for (var index = 0; index < arguments.length; index += 1) {
    switch (arguments[index]) {
      case "--check":
        check = true;
      case "--output":
        if (index + 1 >= arguments.length) {
          throw const FormatException("--output requires a directory path.");
        }
        outputPath = arguments[index + 1];
        index += 1;
      default:
        throw FormatException("Unknown argument: ${arguments[index]}");
    }
  }

  if (check) {
    if (outputPath != null) {
      throw const FormatException("--check and --output cannot be combined.");
    }
    await checkNativeContractFixtures();
    stdout.writeln("Native contract fixtures are up to date.");
    return;
  }

  final outputDirectory = Directory(outputPath ?? _fixtureRoot);
  await generateNativeContractFixtures(outputDirectory: outputDirectory);
  stdout.writeln(
    "Generated native contract fixtures at ${outputDirectory.path}.",
  );
}

/// Generates every native contract fixture beneath [outputDirectory].
Future<void> generateNativeContractFixtures({
  required Directory outputDirectory,
}) async {
  if (await outputDirectory.exists()) {
    await outputDirectory.delete(recursive: true);
  }
  await outputDirectory.create(recursive: true);

  await File(path.join(outputDirectory.path, "README.md"))
      .writeAsString(_readme);
  final descriptors = await _generateReleaseContract(outputDirectory);
  await _generateCanonicalSignatureCases(
    outputDirectory,
    descriptors.values.first,
  );
  await _generateDescriptorValidationCases(outputDirectory, descriptors);
  await _generateSelectionCases(outputDirectory, descriptors.values.first);
  await _generateSafePathCases(outputDirectory);
  await _generateDiagnosticsCases(outputDirectory);
  await _writeJson(
    File(path.join(outputDirectory.path, "helper-events.json")),
    {"schemaVersion": 1, "events": _helperEvents},
  );
}

/// Verifies committed fixtures against a fresh deterministic generation.
Future<void> checkNativeContractFixtures({
  Directory? fixtureDirectory,
}) async {
  final expected = fixtureDirectory ?? Directory(_fixtureRoot);
  if (!await expected.exists()) {
    throw FileSystemException(
      "Committed native contract fixtures are missing.",
      expected.path,
    );
  }

  final temporaryRoot =
      await Directory.systemTemp.createTemp("native_contract_check_");
  try {
    final generated = Directory(path.join(temporaryRoot.path, "generated"));
    await generateNativeContractFixtures(outputDirectory: generated);
    final expectedTree = await _readTree(expected);
    final generatedTree = await _readTree(generated);
    if (expectedTree.keys.join("\n") != generatedTree.keys.join("\n")) {
      throw StateError("Native contract fixture file list has drifted.");
    }
    for (final entry in expectedTree.entries) {
      if (!_bytesEqual(entry.value, generatedTree[entry.key])) {
        throw StateError("Native contract fixture has drifted: ${entry.key}");
      }
    }
  } finally {
    await temporaryRoot.delete(recursive: true);
  }
}

Future<Map<String, Map<String, dynamic>>> _generateReleaseContract(
  Directory outputDirectory,
) async {
  final root = Directory(path.join(outputDirectory.path, "release-contract"));
  await root.create(recursive: true);
  final specs = <({
    String id,
    String platform,
    String kind,
    String extension,
    int buildNumber,
  })>[
    (
      id: "macos-zip",
      platform: "macos",
      kind: "zip",
      extension: "zip",
      buildNumber: 270,
    ),
    (
      id: "macos-dmg",
      platform: "macos",
      kind: "dmg",
      extension: "dmg",
      buildNumber: 271,
    ),
    (
      id: "macos-pkg-installer",
      platform: "macos",
      kind: "pkgInstaller",
      extension: "pkg",
      buildNumber: 272,
    ),
    (
      id: "windows-zip",
      platform: "windows",
      kind: "zip",
      extension: "zip",
      buildNumber: 273,
    ),
    (
      id: "windows-inno-installer",
      platform: "windows",
      kind: "innoInstaller",
      extension: "exe",
      buildNumber: 274,
    ),
    (
      id: "linux-zip",
      platform: "linux",
      kind: "zip",
      extension: "zip",
      buildNumber: 275,
    ),
  ];
  final matrixCases = <Map<String, dynamic>>[];
  final descriptors = <String, Map<String, dynamic>>{};

  for (final spec in specs) {
    final caseDirectory = Directory(path.join(root.path, spec.id));
    await caseDirectory.create(recursive: true);
    final artifactName = "artifact.${spec.extension}";
    final artifact = File(path.join(caseDirectory.path, artifactName));
    final artifactBytes = utf8.encode(
      "desktop_updater native contract ${spec.platform}/${spec.kind}\n",
    );
    await artifact.writeAsBytes(artifactBytes);
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: "com.example.native-contract",
      appName: spec.platform == "macos" ? "Example.app" : "Example",
      version: "2.7.0",
      buildNumber: spec.buildNumber,
      platform: spec.platform,
      channel: "stable",
      artifact: ReleaseArtifact(
        kind: spec.kind,
        url: Uri.parse(
          "https://updates.example.test/release-contract/${spec.id}/"
          "$artifactName",
        ),
        sha256: crypto.sha256.convert(artifactBytes).toString(),
        length: artifactBytes.length,
      ),
      install: _installFor(spec.platform, spec.kind),
      minimumUpdaterVersion: _minimumUpdaterVersion(spec.kind),
      minimumOS: {spec.platform: _minimumOS(spec.platform)},
      generatedAt: _generatedAt,
    )..validate();
    final descriptorJson = descriptor.toJson();
    descriptors[spec.id] = descriptorJson;
    await _writeJson(
      File(path.join(caseDirectory.path, "release.json")),
      descriptorJson,
    );
    matrixCases.add({
      "id": spec.id,
      "platform": spec.platform,
      "artifactKind": spec.kind,
      "artifactPath": "${spec.id}/$artifactName",
      "descriptorPath": "${spec.id}/release.json",
    });
  }

  await _writeJson(
    File(path.join(root.path, "matrix.json")),
    {"schemaVersion": 1, "cases": matrixCases},
  );
  return descriptors;
}

ReleaseInstall _installFor(String platform, String kind) {
  if (kind == "dmg") {
    return const ReleaseInstall(
      strategy: "wholeBundleReplace",
      macosDmg: ReleaseMacOSDmgInstall(
        appBundleName: "Example.app",
        verifyPrimarySignature: true,
      ),
    );
  }
  if (kind == "pkgInstaller") {
    return const ReleaseInstall(
      strategy: "pkgInstaller",
      macosPkg: ReleaseMacOSPkgInstall(
        launchMode: "installerApp",
        expectedPackageIds: ["com.example.native-contract.pkg"],
        relaunchAfterInstall: false,
      ),
    );
  }
  if (kind == "innoInstaller") {
    return ReleaseInstall(
      strategy: "innoInstaller",
      inno: ReleaseInnoInstall(
        silentArgs: const ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        inheritInstallDirectory: true,
        logFileName: "desktop_updater_inno_install.log",
        relaunchAfterInstall: true,
        requiresElevation: "auto",
        authenticode: ReleaseAuthenticodePolicy(
          required: true,
          sha256Thumbprints: ["AB" * 32],
        ),
      ),
    );
  }
  return ReleaseInstall(
    strategy:
        platform == "macos" ? "wholeBundleReplace" : "wholeDirectoryReplace",
  );
}

String _minimumUpdaterVersion(String kind) {
  return switch (kind) {
    "innoInstaller" => "2.5.0",
    "dmg" || "pkgInstaller" => "2.6.0",
    _ => "2.0.0",
  };
}

String _minimumOS(String platform) {
  return switch (platform) {
    "macos" => "13.0",
    "windows" => "10.0.19045",
    "linux" => "glibc-2.35",
    _ => throw FormatException("Unsupported fixture platform: $platform"),
  };
}

Future<void> _generateCanonicalSignatureCases(
  Directory outputDirectory,
  Map<String, dynamic> baseDescriptor,
) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(
    List<int>.generate(32, (index) => index),
  );
  final wrongKeyPair = await algorithm.newKeyPairFromSeed(
    List<int>.generate(32, (index) => index + 32),
  );
  final publicKey = await keyPair.extractPublicKey();
  final wrongPublicKey = await wrongKeyPair.extractPublicKey();
  final descriptorToSign = ReleaseDescriptor.fromJson({
    ..._cloneMap(baseDescriptor),
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": _publicKeyId,
      "value": "",
    },
  });
  final signature = await algorithm.sign(
    descriptorToSign.canonicalSignatureBytes(),
    keyPair: keyPair,
  );
  final signedJson = descriptorToSign.toJson();
  _mapAt(signedJson, "signature")["value"] = base64Encode(signature.bytes);
  final signedDescriptor = ReleaseDescriptor.fromJson(signedJson);
  final canonicalOrderingInput = <String, dynamic>{
    "z": 1,
    "a": {"z": 2, "a": 3},
    "m": [
      {"z": 4, "a": 5},
    ],
  };
  final invalidSignature = _cloneMap(signedJson);
  _mapAt(invalidSignature, "signature")["value"] =
      base64Encode(List<int>.filled(64, 0));
  final unknownKey = _cloneMap(signedJson);
  _mapAt(unknownKey, "signature")["publicKeyId"] = "unknown-key";

  final cases = <Map<String, dynamic>>[
    _signatureCase("valid signature", signedJson, "valid", true),
    _signatureCase("missing public key id", unknownKey, "valid", false),
    _signatureCase("wrong pinned key", signedJson, "wrong", false),
    _signatureCase("wrong signature bytes", invalidSignature, "valid", false),
    _signatureCase(
      "wrong package identity",
      _mutate(signedJson, "packageId", "com.example.other"),
      "valid",
      false,
    ),
    _signatureCase(
      "wrong version",
      _mutate(signedJson, "version", "2.7.1"),
      "valid",
      false,
    ),
    _signatureCase(
      "wrong build number",
      _mutate(signedJson, "buildNumber", 999),
      "valid",
      false,
    ),
    _signatureCase(
      "wrong platform",
      _mutate(signedJson, "platform", "windows"),
      "valid",
      false,
    ),
    _signatureCase(
      "wrong channel",
      _mutate(signedJson, "channel", "beta"),
      "valid",
      false,
    ),
  ];

  await _writeJson(
    File(path.join(outputDirectory.path, "canonical-signature-cases.json")),
    {
      "schemaVersion": 1,
      "canonicalOrdering": {
        "input": canonicalOrderingInput,
        "expected": sortJsonValue(canonicalOrderingInput),
      },
      "signatureBlanking": {
        "signedDescriptor": signedDescriptor.toJson(),
        "canonicalJson": signedDescriptor.toCanonicalSignatureJson(),
        "canonicalUtf8Base64":
            base64Encode(signedDescriptor.canonicalSignatureBytes()),
      },
      "keySets": {
        "valid": {_publicKeyId: base64Encode(publicKey.bytes)},
        "wrong": {_publicKeyId: base64Encode(wrongPublicKey.bytes)},
        "empty": <String, String>{},
      },
      "cases": cases,
    },
  );
}

Map<String, dynamic> _signatureCase(
  String name,
  Map<String, dynamic> descriptor,
  String keySet,
  bool expectedValid,
) {
  return {
    "name": name,
    "descriptor": descriptor,
    "keySet": keySet,
    "expectedValid": expectedValid,
  };
}

Future<void> _generateDescriptorValidationCases(
  Directory outputDirectory,
  Map<String, Map<String, dynamic>> descriptors,
) async {
  final base = descriptors["macos-zip"]!;
  final invalidHash = _cloneMap(base);
  _mapAt(invalidHash, "artifact")["sha256"] = "not-a-sha256";
  final invalidLength = _cloneMap(base);
  _mapAt(invalidLength, "artifact")["length"] = -1;
  final invalidKind = _cloneMap(base);
  _mapAt(invalidKind, "artifact")["kind"] = "tarball";
  final missingStrategy = _cloneMap(base);
  _mapAt(missingStrategy, "install")["strategy"] = "";
  final invalidInno = _cloneMap(descriptors["windows-inno-installer"]!);
  _mapAt(_mapAt(invalidInno, "install"), "inno")["silentArgs"] = <String>[];
  final invalidDmg = _cloneMap(descriptors["macos-dmg"]!);
  _mapAt(_mapAt(invalidDmg, "install"), "macosDmg")["appBundleName"] =
      "Example";
  final invalidPkg = _cloneMap(descriptors["macos-pkg-installer"]!);
  _mapAt(_mapAt(invalidPkg, "install"), "macosPkg")["expectedPackageIds"] =
      <String>[];
  final inputs = <(String, Map<String, dynamic>)>[
    ("valid descriptor", base),
    ("wrong schema", _mutate(base, "schemaVersion", 2)),
    ("blank package identity", _mutate(base, "packageId", " ")),
    ("blank version", _mutate(base, "version", "")),
    ("negative build number", _mutate(base, "buildNumber", -1)),
    ("blank platform", _mutate(base, "platform", "")),
    ("invalid artifact hash", invalidHash),
    ("negative artifact length", invalidLength),
    ("unsupported artifact kind", invalidKind),
    ("missing install strategy", missingStrategy),
    ("incomplete Inno metadata", invalidInno),
    ("incomplete DMG metadata", invalidDmg),
    ("incomplete PKG metadata", invalidPkg),
  ];
  final cases = <Map<String, dynamic>>[];
  for (final input in inputs) {
    Object? error;
    try {
      ReleaseDescriptor.fromJson(input.$2);
    } on Object catch (caught) {
      error = caught;
    }
    cases.add({
      "name": input.$1,
      "descriptor": input.$2,
      "expectedValid": error == null,
      if (error != null) "expectedErrorContains": _errorMessage(error),
    });
  }
  await _writeJson(
    File(path.join(outputDirectory.path, "descriptor-validation-cases.json")),
    {"schemaVersion": 1, "cases": cases},
  );
}

Future<void> _generateSelectionCases(
  Directory outputDirectory,
  Map<String, dynamic> baseDescriptor,
) async {
  final versionInputs = <(String, String, String)>[
    ("newer build number wins", "2.7.0+271", "2.7.0+270"),
    ("older build number loses", "3.0.0+100", "2.7.0+270"),
    ("stable follows prerelease", "2.8.0", "2.8.0-beta.1"),
    ("prerelease precedes stable", "2.8.0-beta.1", "2.8.0"),
  ];
  final versionComparisons = [
    for (final input in versionInputs)
      {
        "name": input.$1,
        "candidate": input.$2,
        "current": input.$3,
        "expectedSign": compareDesktopVersions(
          DesktopVersionInfo.parse(input.$2),
          DesktopVersionInfo.parse(input.$3),
        ).sign,
      },
  ];
  const salt = "native-contract-rollout";
  const channel = "stable";
  final bucketZeroIdentity = _identityForBucket(0, salt, channel);
  final bucketOneIdentity = _identityForBucket(1, salt, channel);
  final bucket49Identity = _identityForBucket(49, salt, channel);
  final bucket50Identity = _identityForBucket(50, salt, channel);
  final rolloutInputs = <(String, int, String?)>[
    ("zero percent excludes", 0, bucketZeroIdentity),
    ("one percent includes bucket zero", 1, bucketZeroIdentity),
    ("one percent excludes bucket one", 1, bucketOneIdentity),
    ("fifty percent includes bucket forty-nine", 50, bucket49Identity),
    ("fifty percent excludes bucket fifty", 50, bucket50Identity),
    ("one hundred percent includes without identity", 100, null),
  ];
  final rolloutCases = [
    for (final input in rolloutInputs)
      {
        "name": input.$1,
        "percentage": input.$2,
        "salt": salt,
        "channel": channel,
        "identity": input.$3,
        "bucket":
            input.$3 == null ? null : _rolloutBucket(salt, channel, input.$3!),
        "expectedIncluded": ReleaseRollout(
          percentage: input.$2,
          salt: salt,
        ).includes(channel: channel, installationIdentity: input.$3),
      },
  ];

  final buildIndex = _indexJson([
    _indexItem(version: "2.7.0", buildNumber: 271),
    _indexItem(version: "2.7.0", buildNumber: 272),
  ]);
  final prereleaseIndex = _indexJson([
    _indexItem(version: "2.8.0", buildNumber: null),
  ]);
  final rolloutIndex = _indexJson([
    _indexItem(
      version: "2.9.0",
      buildNumber: null,
      rollout: const ReleaseRollout(percentage: 50, salt: salt),
    ),
  ]);
  final selectionCases = [
    _selectionCase(
      "build-number tiebreaker",
      buildIndex,
      currentVersion: "2.7.0+270",
    ),
    _selectionCase(
      "stable release follows prerelease",
      prereleaseIndex,
      currentVersion: "2.8.0-beta.1",
    ),
    _selectionCase(
      "rollout identity inside cohort",
      rolloutIndex,
      currentVersion: "2.8.0",
      identity: bucket49Identity,
    ),
    _selectionCase(
      "rollout identity outside cohort",
      rolloutIndex,
      currentVersion: "2.8.0",
      identity: bucket50Identity,
    ),
  ];

  final minimumUpdaterInputs = <(String, String)>[
    ("2.7.0", "2.6.0"),
    ("2.7.0", "2.7.0"),
    ("2.7.0", "2.8.0"),
  ];
  final minimumUpdaterCases = [
    for (final input in minimumUpdaterInputs)
      {
        "current": input.$1,
        "required": input.$2,
        "expectedSupported": compareDesktopVersions(
              DesktopVersionInfo.parse(input.$1),
              DesktopVersionInfo.parse(input.$2),
            ) >=
            0,
      },
  ];
  final minimumOSDescriptor = _cloneMap(baseDescriptor)
    ..["minimumOS"] = {"macos": "13.0"};
  final minimumOSCases = [
    {
      "name": "matching platform rejected by callback",
      "descriptor": minimumOSDescriptor,
      "platform": "macos",
      "callbackResult": false,
      "expectedAllowed": false,
    },
    {
      "name": "matching platform accepted by callback",
      "descriptor": minimumOSDescriptor,
      "platform": "macos",
      "callbackResult": true,
      "expectedAllowed": true,
    },
    {
      "name": "missing platform policy remains allowed",
      "descriptor": minimumOSDescriptor,
      "platform": "windows",
      "callbackResult": false,
      "expectedAllowed": true,
    },
  ];
  final policyJson = {
    "minimumSupportedVersion": "2.7.0",
    "enforcedAfter": "2026-07-15T00:00:00.000Z",
  };
  final policy = ReleaseSupportPolicy.fromJson(policyJson);
  final supportInputs = <(String, String)>[
    ("2.6.0", "2026-07-14T23:59:59.000Z"),
    ("2.6.0", "2026-07-15T00:00:00.000Z"),
    ("2.7.0", "2026-07-16T00:00:00.000Z"),
  ];
  final supportPolicyCases = [
    for (final input in supportInputs)
      {
        "policy": policyJson,
        "currentVersion": input.$1,
        "now": input.$2,
        "expectedApplies": policy.appliesTo(DesktopVersionInfo.parse(input.$1)),
        "expectedEnforced": policy.isEnforced(
          currentVersion: DesktopVersionInfo.parse(input.$1),
          now: DateTime.parse(input.$2),
        ),
      },
  ];
  final freshInstallInputs = [
    {
      "downloadUrl": "https://updates.example.test/download/latest",
      "message": "Install the current signed build.",
    },
    {"downloadUrl": "https://updates.example.test/download/latest"},
  ];

  await _writeJson(
    File(path.join(outputDirectory.path, "selection-cases.json")),
    {
      "schemaVersion": 1,
      "versionComparisons": versionComparisons,
      "rolloutCases": rolloutCases,
      "selectionCases": selectionCases,
      "minimumUpdaterCases": minimumUpdaterCases,
      "minimumOSCases": minimumOSCases,
      "supportPolicyCases": supportPolicyCases,
      "freshInstallCases": [
        for (final input in freshInstallInputs)
          {
            "input": input,
            "expected": ReleaseFreshInstall.fromJson(input).toJson(),
          },
      ],
    },
  );
}

Map<String, dynamic> _indexItem({
  required String version,
  required int? buildNumber,
  ReleaseRollout? rollout,
}) {
  return {
    "version": version,
    if (buildNumber != null) "buildNumber": buildNumber,
    "platform": "macos",
    "channel": "stable",
    "mandatory": false,
    "release":
        "https://updates.example.test/releases/$version/macos/release.json",
    if (rollout != null) "rollout": rollout.toJson(),
  };
}

Map<String, dynamic> _indexJson(List<Map<String, dynamic>> items) {
  return {"schemaVersion": 3, "appName": "Example.app", "items": items};
}

Map<String, dynamic> _selectionCase(
  String name,
  Map<String, dynamic> indexJson, {
  required String currentVersion,
  String? identity,
}) {
  final selected = selectReleaseIndexItem(
    index: ReleaseIndex.fromJson(indexJson),
    platform: "macos",
    channel: "stable",
    currentVersion: DesktopVersionInfo.parse(currentVersion),
    installationIdentity: identity,
  );
  return {
    "name": name,
    "index": indexJson,
    "platform": "macos",
    "channel": "stable",
    "currentVersion": currentVersion,
    "identity": identity,
    "selectedVersion": selected?.version,
    "selectedBuildNumber": selected?.buildNumber,
  };
}

String _identityForBucket(int bucket, String salt, String channel) {
  for (var index = 0; index < 10000; index += 1) {
    final candidate = "fixture-device-$index";
    if (_rolloutBucket(salt, channel, candidate) == bucket) {
      return candidate;
    }
  }
  throw StateError("Unable to find identity for rollout bucket $bucket.");
}

int _rolloutBucket(String salt, String channel, String identity) {
  final digest =
      crypto.sha256.convert(utf8.encode("$salt\n$channel\n$identity"));
  final value = digest.bytes.take(4).fold<int>(
        0,
        (previous, byte) => (previous << 8) + byte,
      );
  return value % 100;
}

Future<void> _generateSafePathCases(Directory outputDirectory) async {
  final archiveInputs = <(String, String)>[
    ("nested bundle path", "Example.app/Contents/MacOS/Example"),
    ("backslash normalization", r"folder\nested\file.txt"),
    ("dot segment normalization", "folder/./file.txt"),
    ("parent traversal", "../escape.txt"),
    ("absolute POSIX path", "/etc/passwd"),
    ("Windows drive-prefixed path", r"C:\Windows\System32"),
  ];
  final archivePathCases = <Map<String, dynamic>>[];
  for (final input in archiveInputs) {
    String? normalized;
    Object? error;
    try {
      normalized = normalizeArchivePath(input.$2);
    } on Object catch (caught) {
      error = caught;
    }
    archivePathCases.add({
      "name": input.$1,
      "input": input.$2,
      "expectedValid": error == null,
      "expectedNormalized": normalized,
      if (error != null) "expectedErrorContains": _errorMessage(error),
    });
  }
  const protectedRoots = [
    "/",
    "/bin",
    "/sbin",
    "/usr",
    "/usr/bin",
    "/usr/sbin",
    "/usr/local",
    "/usr/local/bin",
    "/opt",
    "/etc",
    "/var",
    "/home",
  ];
  await _writeJson(
    File(path.join(outputDirectory.path, "safe-path-cases.json")),
    {
      "schemaVersion": 1,
      "archivePathCases": archivePathCases,
      "symlinkTargetCases": [
        {
          "name": "nested relative symlink target",
          "target": "Versions/Current/Example",
          "expectedValid": true,
        },
        {
          "name": "absolute symlink target",
          "target": "/tmp/escape",
          "expectedValid": false,
        },
        {
          "name": "traversing symlink target",
          "target": "../escape",
          "expectedValid": false,
        },
        {
          "name": "drive-prefixed symlink target",
          "target": r"C:\escape",
          "expectedValid": false,
        },
      ],
      "rootBoundaryCases": [
        {
          "root": "/opt/example-app",
          "candidate": "/opt/example-app/bin/example",
          "expectedWithin": true,
        },
        {
          "root": "/opt/example-app",
          "candidate": "/opt/example-app-other/bin/example",
          "expectedWithin": false,
        },
        {
          "root": "/opt/example-app",
          "candidate": "/etc/passwd",
          "expectedWithin": false,
        },
      ],
      "entityTypeCases": [
        {"entityType": "directory", "expectedValid": true},
        {"entityType": "symbolicLink", "expectedValid": false},
      ],
      "linuxInstallRootCases": [
        for (final root in protectedRoots)
          {"root": root, "expectedValid": false},
        {"root": "/opt/example-app", "expectedValid": true},
      ],
    },
  );
}

Future<void> _generateDiagnosticsCases(Directory outputDirectory) async {
  final timestamp = DateTime.utc(2026, 7, 10, 12);
  final inputs = <({
    String name,
    UpdateDiagnosticStage stage,
    UpdateDiagnosticLevel level,
    String message,
    String? error,
  })>[
    (
      name: "query secrets",
      stage: UpdateDiagnosticStage.download,
      level: UpdateDiagnosticLevel.info,
      message: "GET https://updates.example.test/release.json?token=abc&safe=1",
      error: null,
    ),
    (
      name: "authorization and password",
      stage: UpdateDiagnosticStage.descriptor,
      level: UpdateDiagnosticLevel.error,
      message: "Authorization: Bearer abc password=hunter2",
      error: "signature=deadbeef",
    ),
    (
      name: "credential aliases",
      stage: UpdateDiagnosticStage.verify,
      level: UpdateDiagnosticLevel.warning,
      message: "credential=my-value publicKey=abc secret=hidden",
      error: null,
    ),
  ];
  final cases = [
    for (final input in inputs)
      {
        "name": input.name,
        "timestamp": timestamp.toIso8601String(),
        "stage": input.stage.name,
        "level": input.level.name,
        "message": input.message,
        "error": input.error,
        "expectedLogLine": UpdateDiagnosticEntry(
          timestamp: timestamp,
          stage: input.stage,
          level: input.level,
          message: input.message,
          error: input.error == null ? null : FormatException(input.error!),
        ).toRedactedLogLine(),
      },
  ];
  await _writeJson(
    File(path.join(outputDirectory.path, "diagnostics-redaction-cases.json")),
    {"schemaVersion": 1, "cases": cases},
  );
}

Map<String, dynamic> _mutate(
  Map<String, dynamic> source,
  String key,
  Object? value,
) {
  return _cloneMap(source)..[key] = value;
}

Map<String, dynamic> _cloneMap(Map<String, dynamic> source) {
  return Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);
}

Map<String, dynamic> _mapAt(Map<String, dynamic> source, String key) {
  return source[key]! as Map<String, dynamic>;
}

String _errorMessage(Object error) {
  return error is FormatException ? error.message : error.toString();
}

Future<void> _writeJson(File file, Object? value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString("${_jsonEncoder.convert(value)}\n");
}

Future<Map<String, List<int>>> _readTree(Directory root) async {
  final files = <String, List<int>>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final relative =
          path.relative(entity.path, from: root.path).replaceAll(r"\", "/");
      files[relative] = await entity.readAsBytes();
    }
  }
  return Map.fromEntries(
    files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

bool _bytesEqual(List<int> left, List<int>? right) {
  if (right == null || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

const _readme = """
# Native Contract Fixtures

These files are generated from the Dart 2.7 contract implementation. Swift and
C++ native SDK tests consume them as cross-language compatibility inputs.

Regenerate after an intentional contract change:

```sh
dart run tool/generate_native_contract_fixtures.dart
```

Check committed bytes without rewriting them:

```sh
dart run tool/generate_native_contract_fixtures.dart --check
```

All timestamps, Ed25519 seeds, URLs, artifact payloads, hashes, and selection
identities are deterministic test data. URLs use `updates.example.test` and do
not identify a production service.
""";
