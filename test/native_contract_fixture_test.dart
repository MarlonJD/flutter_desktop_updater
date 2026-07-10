import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/io/archive_path.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../tool/generate_native_contract_fixtures.dart";

void main() {
  const fixturePath = "fixtures/compat/native-contract";

  test("native contract generation is byte-for-byte deterministic", () async {
    final root = await Directory.systemTemp.createTemp("native_contract_");
    final first = Directory(path.join(root.path, "first"));
    final second = Directory(path.join(root.path, "second"));
    try {
      await generateNativeContractFixtures(outputDirectory: first);
      await generateNativeContractFixtures(outputDirectory: second);

      expect(await _readTree(first), await _readTree(second));
      expect(await _readTree(first), await _readTree(Directory(fixturePath)));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("release contract matrix uses valid descriptors and real hashes",
      () async {
    final root = Directory(path.join(fixturePath, "release-contract"));
    final matrix = await _readJson(File(path.join(root.path, "matrix.json")));
    final cases = _mapList(matrix, "cases");

    expect(
      cases.map((entry) => entry["id"]),
      containsAll(<String>[
        "macos-zip",
        "macos-dmg",
        "macos-pkg-installer",
        "windows-zip",
        "windows-inno-installer",
        "linux-zip",
      ]),
    );
    expect(cases, hasLength(6));

    for (final entry in cases) {
      final artifact =
          File(path.join(root.path, entry["artifactPath"] as String));
      final descriptorFile =
          File(path.join(root.path, entry["descriptorPath"] as String));
      final descriptor = ReleaseDescriptor.fromJson(
        await _readJson(descriptorFile),
      );
      final artifactBytes = await artifact.readAsBytes();

      expect(descriptor.buildNumber, isA<int>(), reason: entry["id"] as String);
      expect(descriptor.artifact.url.isAbsolute, isTrue);
      expect(descriptor.artifact.url.scheme, "https");
      expect(descriptor.artifact.url.host, "updates.example.test");
      expect(descriptor.artifact.length, artifactBytes.length);
      expect(
        descriptor.artifact.sha256,
        crypto.sha256.convert(artifactBytes).toString(),
      );
      expect(descriptor.platform, entry["platform"]);
      expect(descriptor.artifact.kind, entry["artifactKind"]);
    }
  });

  test("canonical signature cases verify with the current Dart contract",
      () async {
    final fixture = await _readJson(
      File(path.join(fixturePath, "canonical-signature-cases.json")),
    );
    final ordering = _map(fixture, "canonicalOrdering");
    expect(sortJsonValue(ordering["input"]), ordering["expected"]);

    final blanking = _map(fixture, "signatureBlanking");
    final descriptor = ReleaseDescriptor.fromJson(
      _dynamicMap(blanking["signedDescriptor"]),
    );
    final canonicalJson = descriptor.toCanonicalSignatureJson();
    expect(canonicalJson, blanking["canonicalJson"]);
    expect(
      base64Encode(descriptor.canonicalSignatureBytes()),
      blanking["canonicalUtf8Base64"],
    );
    expect(
      _map(canonicalJson, "signature")["value"],
      isEmpty,
    );

    for (final entry in _mapList(fixture, "cases")) {
      final keys = <String, String>{
        entry["publicKeyId"] as String: entry["publicKeyBase64"] as String,
      };
      final candidate = ReleaseDescriptor.fromJson(
        _dynamicMap(entry["descriptor"]),
      );
      expect(
        base64Encode(candidate.canonicalSignatureBytes()),
        entry["canonicalUtf8Base64"],
      );
      expect(candidate.signature?.value, entry["signatureBase64"]);
      final actual =
          await Ed25519ReleaseSignatureVerifier(keys).verify(candidate);
      expect(actual, entry["expectedValid"], reason: entry["name"] as String);
    }
  });

  test("descriptor validation cases match the current parser", () async {
    final fixture = await _readJson(
      File(path.join(fixturePath, "descriptor-validation-cases.json")),
    );
    for (final entry in _mapList(fixture, "cases")) {
      Object? error;
      try {
        ReleaseDescriptor.fromJson(_dynamicMap(entry["descriptor"]));
      } on Object catch (caught) {
        error = caught;
      }

      final expectedValid = entry["expectedValid"] as bool;
      expect(error == null, expectedValid, reason: entry["name"] as String);
      final expectedError = entry["expectedErrorContains"] as String?;
      if (expectedError != null) {
        expect(error.toString(), contains(expectedError));
      }
    }
  });

  test("selection and policy cases match current Dart algorithms", () async {
    final fixture = await _readJson(
      File(path.join(fixturePath, "selection-cases.json")),
    );

    for (final entry in _mapList(fixture, "indexValidationCases")) {
      ReleaseIndex? index;
      Object? error;
      try {
        index = ReleaseIndex.fromJson(_dynamicMap(entry["index"]));
      } on Object catch (caught) {
        error = caught;
      }
      expect(
        error == null,
        entry["expectedValid"],
        reason: entry["name"] as String,
      );
      expect(index?.items.single.channel, entry["expectedChannel"]);
    }

    for (final entry in _mapList(fixture, "versionComparisons")) {
      expect(
        compareDesktopVersions(
          DesktopVersionInfo.parse(entry["candidate"] as String),
          DesktopVersionInfo.parse(entry["current"] as String),
        ).sign,
        entry["expectedSign"],
        reason: entry["name"] as String,
      );
    }

    for (final entry in _mapList(fixture, "rolloutCases")) {
      final identity = entry["identity"] as String?;
      if (identity != null) {
        expect(
          _rolloutBucket(
            entry["salt"] as String,
            entry["channel"] as String,
            identity,
          ),
          entry["bucket"],
        );
      }
      final rollout = ReleaseRollout(
        percentage: entry["percentage"] as int,
        salt: entry["salt"] as String,
      );
      expect(
        rollout.includes(
          channel: entry["channel"] as String,
          installationIdentity: identity,
        ),
        entry["expectedIncluded"],
        reason: entry["name"] as String,
      );
    }

    for (final entry in _mapList(fixture, "selectionCases")) {
      final selected = selectReleaseIndexItem(
        index: ReleaseIndex.fromJson(_dynamicMap(entry["index"])),
        platform: entry["platform"] as String,
        channel: entry["channel"] as String,
        currentVersion:
            DesktopVersionInfo.parse(entry["currentVersion"] as String),
        installationIdentity: entry["identity"] as String?,
      );
      expect(selected?.version, entry["selectedVersion"]);
      expect(selected?.buildNumber, entry["selectedBuildNumber"]);
    }

    for (final entry in _mapList(fixture, "minimumUpdaterCases")) {
      final supported = compareDesktopVersions(
            DesktopVersionInfo.parse(entry["current"] as String),
            DesktopVersionInfo.parse(entry["required"] as String),
          ) >=
          0;
      expect(supported, entry["expectedSupported"]);
    }

    for (final entry in _mapList(fixture, "minimumOSCases")) {
      final descriptor = ReleaseDescriptor.fromJson(
        _dynamicMap(entry["descriptor"]),
      );
      final minimumOS =
          descriptor.minimumOSForPlatform(entry["platform"] as String);
      final allowed = minimumOS == null || entry["callbackResult"] as bool;
      expect(allowed, entry["expectedAllowed"]);
    }

    for (final entry in _mapList(fixture, "supportPolicyCases")) {
      final policy = ReleaseSupportPolicy.fromJson(
        _dynamicMap(entry["policy"]),
      );
      final current =
          DesktopVersionInfo.parse(entry["currentVersion"] as String);
      expect(policy.appliesTo(current), entry["expectedApplies"]);
      expect(
        policy.isEnforced(
          currentVersion: current,
          now: DateTime.parse(entry["now"] as String),
        ),
        entry["expectedEnforced"],
      );
    }

    for (final entry in _mapList(fixture, "freshInstallCases")) {
      final policy = ReleaseFreshInstall.fromJson(_dynamicMap(entry["input"]));
      expect(policy.toJson(), entry["expected"]);
    }
  });

  test("safe-path cases match the archive path contract", () async {
    final fixture = await _readJson(
      File(path.join(fixturePath, "safe-path-cases.json")),
    );
    for (final entry in _mapList(fixture, "archivePathCases")) {
      String? normalized;
      Object? error;
      try {
        normalized = normalizeArchivePath(entry["input"] as String);
      } on Object catch (caught) {
        error = caught;
      }
      expect(
        error == null,
        entry["expectedValid"],
        reason: entry["name"] as String,
      );
      expect(normalized, entry["expectedNormalized"]);
    }

    for (final entry in _mapList(fixture, "rootBoundaryCases")) {
      final root = entry["root"] as String;
      final candidate = entry["candidate"] as String;
      final isWithin =
          candidate == root || path.posix.isWithin(root, candidate);
      expect(isWithin, entry["expectedWithin"]);
    }

    for (final entry in _mapList(fixture, "symlinkTargetCases")) {
      expect(
        _isSafeSymlinkTarget(entry["target"] as String),
        entry["expectedValid"],
      );
    }

    for (final entry in _mapList(fixture, "entityTypeCases")) {
      expect(
        entry["entityType"] == "directory",
        entry["expectedValid"],
      );
    }

    const protectedRoots = {
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
    };
    for (final entry in _mapList(fixture, "linuxInstallRootCases")) {
      expect(
        !protectedRoots.contains(entry["root"]),
        entry["expectedValid"],
      );
    }
  });
}

int _rolloutBucket(String salt, String channel, String identity) {
  final digest = crypto.sha256.convert(
    utf8.encode("$salt\n$channel\n$identity"),
  );
  final value = digest.bytes.take(4).fold<int>(
        0,
        (previous, byte) => (previous << 8) + byte,
      );
  return value % 100;
}

bool _isSafeSymlinkTarget(String target) {
  final normalized = target.replaceAll(r"\", "/");
  final segments = normalized
      .split("/")
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  return target.trim().isNotEmpty &&
      !normalized.startsWith("/") &&
      !RegExp(r"^[a-zA-Z]:").hasMatch(normalized) &&
      !segments.contains("..");
}

Future<Map<String, List<int>>> _readTree(Directory root) async {
  final entries = <String, List<int>>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final relative =
          path.relative(entity.path, from: root.path).replaceAll(r"\", "/");
      entries[relative] = await entity.readAsBytes();
    }
  }
  return entries;
}

Future<Map<String, dynamic>> _readJson(File file) async {
  return _dynamicMap(jsonDecode(await file.readAsString()));
}

Map<String, dynamic> _dynamicMap(Object? value) {
  return Map<String, dynamic>.from(value! as Map);
}

Map<String, dynamic> _map(Map<String, dynamic> source, String key) {
  return _dynamicMap(source[key]);
}

List<Map<String, dynamic>> _mapList(
  Map<String, dynamic> source,
  String key,
) {
  return (source[key]! as List).map(_dynamicMap).toList(growable: false);
}
