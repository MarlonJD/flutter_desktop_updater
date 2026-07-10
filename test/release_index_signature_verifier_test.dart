import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("valid Ed25519 app archive signature passes", () async {
    final signed = await _signedIndex();

    expect(
      await Ed25519ReleaseIndexSignatureVerifier({
        _publicKeyId: signed.publicKey,
      }).verify(signed.index),
      isTrue,
    );
  });

  test("unknown app archive signing key fails", () async {
    final signed = await _signedIndex();

    expect(
      await Ed25519ReleaseIndexSignatureVerifier(const {}).verify(signed.index),
      isFalse,
    );
  });

  test("malformed app archive signature envelopes fail", () async {
    final signed = await _signedIndex();
    final verifier = Ed25519ReleaseIndexSignatureVerifier({
      _publicKeyId: signed.publicKey,
    });

    for (final signature in <Map<String, dynamic>>[
      {
        "algorithm": "rsa",
        "publicKeyId": _publicKeyId,
        "value": signed.index.signature!.value,
      },
      {
        "algorithm": "ed25519",
        "publicKeyId": " ",
        "value": signed.index.signature!.value,
      },
      {
        "algorithm": "ed25519",
        "publicKeyId": _publicKeyId,
        "value": "not-base64!",
      },
      {
        "algorithm": "ed25519",
        "publicKeyId": _publicKeyId,
        "value": base64Encode(List<int>.filled(63, 0)),
      },
    ]) {
      final candidate = ReleaseIndex.fromJson({
        ...signed.index.toJson(),
        "signature": signature,
      });
      expect(await verifier.verify(candidate), isFalse, reason: "$signature");
    }
  });

  test("single-field app archive policy tampering fails", () async {
    final signed = await _signedIndex();
    final verifier = Ed25519ReleaseIndexSignatureVerifier({
      _publicKeyId: signed.publicKey,
    });
    final json = signed.index.toJson();
    final item = json["items"] as List<dynamic>;
    final first = item.single as Map<String, dynamic>;
    final supportPolicy = json["supportPolicy"] as Map<String, dynamic>;

    final tampered = <Map<String, dynamic>>[
      {
        ...json,
        "items": [
          {
            ...first,
            "freshInstall": {
              ...(first["freshInstall"] as Map<String, dynamic>),
              "downloadUrl": "https://evil.example.test/fresh",
            },
          },
        ],
      },
      {
        ...json,
        "items": [
          {...first, "mandatory": false},
        ],
      },
      {
        ...json,
        "items": [
          {
            ...first,
            "rollout": {
              ...(first["rollout"] as Map<String, dynamic>),
              "percentage": 99,
            },
          },
        ],
      },
      {
        ...json,
        "supportPolicy": {
          ...supportPolicy,
          "enforcedAfter": "2027-01-01T00:00:00.000Z",
        },
      },
      {
        ...json,
        "items": [
          {
            ...first,
            "release": "https://evil.example.test/release.json",
          },
        ],
      },
    ];

    for (final candidate in tampered) {
      expect(
        await verifier.verify(ReleaseIndex.fromJson(candidate)),
        isFalse,
      );
    }
  });

  test("strict update client rejects a missing signature before selection",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.test/app-archive.json");
    final descriptorUrl =
        Uri.parse("https://updates.example.test/release.json");
    final transport = _MapTransport({
      archiveUrl: _indexJson(descriptorUrl),
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      platform: "macos",
      transport: transport,
      requireIndexSignature: true,
    );

    await expectLater(
      client.checkForUpdate(),
      throwsA(isA<FormatException>()),
    );
    expect(transport.downloadedSources, [archiveUrl]);
  });

  test("compatibility client verifies a configured signed index", () async {
    final signed = await _signedIndex();
    final archiveUrl =
        Uri.parse("https://updates.example.test/app-archive.json");
    final descriptorUrl = signed.index.items.single.release;
    final tamperedJson = signed.index.toJson();
    final items = tamperedJson["items"] as List<dynamic>;
    tamperedJson["items"] = [
      {
        ...(items.single as Map<String, dynamic>),
        "mandatory": false,
      },
    ];
    final transport = _MapTransport({
      archiveUrl: tamperedJson,
      descriptorUrl: _descriptorJson(),
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      platform: "macos",
      transport: transport,
      indexSignatureVerifier: Ed25519ReleaseIndexSignatureVerifier({
        _publicKeyId: signed.publicKey,
      }),
    );

    await expectLater(
      client.checkForUpdate(),
      throwsA(isA<FormatException>()),
    );
    expect(transport.downloadedSources, [archiveUrl]);
  });
}

const _publicKeyId = "release-key-2026";
const _privateSeed = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
];

Future<_SignedIndex> _signedIndex() async {
  final unsigned = ReleaseIndex.fromJson({
    ..._indexJson(
      Uri.parse("https://updates.example.test/release.json"),
    ),
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": _publicKeyId,
      "value": "",
    },
  });
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(_privateSeed);
  final signature = await algorithm.sign(
    unsigned.canonicalSignatureBytes(),
    keyPair: keyPair,
  );
  final publicKey = await keyPair.extractPublicKey();
  return _SignedIndex(
    index: ReleaseIndex.fromJson({
      ...unsigned.toJson(),
      "signature": ReleaseSignature(
        algorithm: "ed25519",
        publicKeyId: _publicKeyId,
        value: base64Encode(signature.bytes),
      ).toJson(),
    }),
    publicKey: base64Encode(publicKey.bytes),
  );
}

Map<String, dynamic> _indexJson(Uri descriptorUrl) {
  return {
    "schemaVersion": 3,
    "appName": "Example",
    "supportPolicy": {
      "minimumSupportedVersion": "1.5.0",
      "enforcedAfter": "2026-07-10T00:00:00Z",
    },
    "items": [
      {
        "version": "2.0.0",
        "buildNumber": 200,
        "platform": "macos",
        "channel": "stable",
        "mandatory": true,
        "freshInstall": {
          "downloadUrl": "https://updates.example.test/fresh",
          "message": "Download the current installer.",
        },
        "release": descriptorUrl.toString(),
        "rollout": {"percentage": 100, "salt": "stable-2026"},
      },
    ],
  };
}

Map<String, dynamic> _descriptorJson() {
  return {
    "schemaVersion": 3,
    "packageId": "com.example.app",
    "appName": "Example.app",
    "version": "2.0.0",
    "buildNumber": 200,
    "platform": "macos",
    "channel": "stable",
    "artifact": {
      "kind": "zip",
      "url": "https://updates.example.test/Example.zip",
      "sha256": "a" * 64,
      "length": 12,
    },
    "install": {"strategy": "wholeBundleReplace"},
    "minimumUpdaterVersion": "2.0.0",
    "generatedAt": "2026-07-10T00:00:00Z",
  };
}

class _SignedIndex {
  const _SignedIndex({required this.index, required this.publicKey});

  final ReleaseIndex index;
  final String publicKey;
}

class _MapTransport implements UpdateTransport {
  _MapTransport(this.responses);

  final Map<Uri, Map<String, dynamic>> responses;
  final List<Uri> downloadedSources = [];

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    downloadedSources.add(source);
    final response = responses[source];
    if (response == null) {
      throw StateError("No response for $source");
    }
    await destination.writeAsString(jsonEncode(response));
  }
}
