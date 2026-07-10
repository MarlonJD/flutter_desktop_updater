import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  const fixtureRoot = "fixtures/compat/native-contract";

  test("runtime capability descriptors have stable generated names", () async {
    const expected = <String, (String, String, String)>{
      "release-macos-zip.json": ("macos", "zip", "wholeBundleReplace"),
      "release-macos-dmg.json": ("macos", "dmg", "wholeBundleReplace"),
      "release-macos-pkg.json": ("macos", "pkgInstaller", "pkgInstaller"),
      "release-windows-zip.json": ("windows", "zip", "wholeDirectoryReplace"),
      "release-windows-inno.json": (
        "windows",
        "innoInstaller",
        "innoInstaller"
      ),
      "release-linux-zip.json": ("linux", "zip", "wholeDirectoryReplace"),
    };
    final contractRoot = path.join(fixtureRoot, "release-contract");

    for (final entry in expected.entries) {
      final file = File(path.join(contractRoot, entry.key));
      expect(file.existsSync(), isTrue, reason: entry.key);
      final descriptor = ReleaseDescriptor.fromJson(await _readJson(file));
      expect(descriptor.platform, entry.value.$1, reason: entry.key);
      expect(descriptor.artifact.kind, entry.value.$2, reason: entry.key);
      expect(descriptor.install.strategy, entry.value.$3, reason: entry.key);
      expect(descriptor.buildNumber, isA<int>(), reason: entry.key);
      expect(descriptor.artifact.url.isAbsolute, isTrue, reason: entry.key);
      expect(descriptor.artifact.url.scheme, "https", reason: entry.key);
      expect(descriptor.artifact.sha256, matches(RegExp(r"^[0-9a-f]{64}$")));
      expect(descriptor.artifact.length, greaterThan(0), reason: entry.key);
      expect(descriptor.minimumUpdaterVersion, isNotEmpty, reason: entry.key);

      switch (descriptor.artifact.kind) {
        case "dmg":
          expect(descriptor.install.macosDmg, isNotNull, reason: entry.key);
        case "pkgInstaller":
          expect(descriptor.install.macosPkg, isNotNull, reason: entry.key);
        case "innoInstaller":
          expect(descriptor.install.inno, isNotNull, reason: entry.key);
      }
    }

    final matrix = await _readJson(
      File(path.join(contractRoot, "matrix.json")),
    );
    final descriptorPaths = _mapList(matrix, "cases")
        .map((entry) => entry["descriptorPath"])
        .toSet();
    expect(descriptorPaths, expected.keys.toSet());
  });

  test("signature cases are self-contained native verifier inputs", () async {
    final fixture = await _readJson(
      File(path.join(fixtureRoot, "canonical-signature-cases.json")),
    );
    final cases = _mapList(fixture, "cases");
    expect(
      cases.map((entry) => entry["name"]),
      containsAll(<String>{
        "valid signature",
        "modified package id",
        "modified artifact url",
        "modified artifact length",
        "modified artifact sha256",
        "modified install strategy",
        "modified public key id",
        "modified signature bytes",
        "modified generated time",
      }),
    );

    for (final entry in cases) {
      final descriptor = ReleaseDescriptor.fromJson(
        _dynamicMap(entry["descriptor"]),
      );
      final publicKeyId = entry["publicKeyId"] as String;
      final publicKeyBase64 = entry["publicKeyBase64"] as String;
      final signatureBase64 = entry["signatureBase64"] as String;
      expect(base64Decode(publicKeyBase64), hasLength(32));
      expect(base64Decode(signatureBase64), hasLength(64));
      expect(
        base64Encode(descriptor.canonicalSignatureBytes()),
        entry["canonicalUtf8Base64"],
        reason: entry["name"] as String,
      );
      expect(
        descriptor.signature?.value,
        signatureBase64,
        reason: entry["name"] as String,
      );
      final actual = await Ed25519ReleaseSignatureVerifier({
        publicKeyId: publicKeyBase64,
      }).verify(descriptor);
      expect(actual, entry["expectedValid"], reason: entry["name"] as String);
    }
  });

  test("selection and policy fixtures expose typed expected outcomes",
      () async {
    final fixture = await _readJson(
      File(path.join(fixtureRoot, "selection-cases.json")),
    );

    final selectionCases = _mapList(fixture, "selectionCases");
    expect(
      selectionCases.map((entry) => entry["name"]),
      containsAll(<String>{
        "platform filtering",
        "channel filtering",
        "build-number tiebreaker",
        "stable release follows prerelease",
        "rollout identity inside cohort",
        "rollout identity outside cohort",
      }),
    );
    for (final entry in selectionCases) {
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
      expect(selected?.platform, entry["selectedPlatform"]);
      expect(selected?.channel, entry["selectedChannel"]);
      expect(selected?.release.toString(), entry["selectedRelease"]);
    }

    for (final entry in _mapList(fixture, "minimumUpdaterCases")) {
      expect(
        entry["expectedOutcome"],
        entry["expectedSupported"] == true
            ? "updateAvailable"
            : "unsupportedMinimumUpdater",
      );
    }
    for (final entry in _mapList(fixture, "minimumOSCases")) {
      expect(
        entry["expectedOutcome"],
        entry["expectedAllowed"] == true
            ? "updateAvailable"
            : "unsupportedMinimumOS",
      );
    }
    for (final entry in _mapList(fixture, "supportPolicyCases")) {
      final expected = entry["expectedApplies"] != true
          ? "updateAvailable"
          : entry["expectedEnforced"] == true
              ? "supportPolicyBlocked"
              : "supportPolicyWarning";
      expect(entry["expectedOutcome"], expected);
    }
    for (final entry in _mapList(fixture, "freshInstallCases")) {
      expect(entry["expectedOutcome"], "freshInstallRequired");
      expect(entry["expectedArtifactDownload"], isFalse);
    }

    for (final entry in _mapList(fixture, "descriptorBindingCases")) {
      expect(_bindingOutcome(entry), entry["expectedOutcome"]);
    }
  });
}

String _bindingOutcome(Map<String, dynamic> entry) {
  final item = ReleaseIndexItem.fromJson(_dynamicMap(entry["indexItem"]));
  final descriptor = ReleaseDescriptor.fromJson(
    _dynamicMap(entry["descriptor"]),
  );
  if (descriptor.packageId != entry["expectedPackageId"]) {
    return "packageIdentityMismatch";
  }
  if (descriptor.version != item.version ||
      descriptor.buildNumber != item.buildNumber ||
      descriptor.platform != item.platform ||
      descriptor.channel != item.channel) {
    return "invalidDescriptor";
  }
  return "match";
}

Future<Map<String, dynamic>> _readJson(File file) async {
  return _dynamicMap(jsonDecode(await file.readAsString()));
}

Map<String, dynamic> _dynamicMap(Object? value) {
  return Map<String, dynamic>.from(value! as Map);
}

List<Map<String, dynamic>> _mapList(
  Map<String, dynamic> source,
  String key,
) {
  return (source[key]! as List).map(_dynamicMap).toList(growable: false);
}
