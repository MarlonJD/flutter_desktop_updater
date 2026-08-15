import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/cli/verify_command.dart";
import "package:desktop_updater/src/json/strict_json.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_bundle.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_manager.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:desktop_updater/src/release_cli/release_signing_resolver.dart";
import "package:desktop_updater/src/release_cli/sign_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("strict JSON rejects duplicate keys", () {
    expect(
      () => parseStrictJson('{"a":1,"a":2}'),
      throwsFormatException,
    );
  });

  test("strict JSON accepts valid zero and rejects invalid number forms", () {
    expect(parseStrictJson('{"zero":0,"negative":-0.5,"exp":1e2}'), {
      "zero": 0,
      "negative": -0.5,
      "exp": 100,
    });
    expect(() => parseStrictJson('{"value":01}'), throwsFormatException);
    expect(() => parseStrictJson('{"value":1.}'), throwsFormatException);
    expect(() => parseStrictJson('{"value":+1}'), throwsFormatException);
  });

  test("standalone verify uses a profile and rejects the removed key map flag",
      () {
    final results = buildVerifyParser().parse([
      "--release",
      "release.json",
      "--key-profile",
      "desktop_updater.keys.json",
    ]);
    expect(results["key-profile"], "desktop_updater.keys.json");
    expect(
      () => buildVerifyParser().parse([
        "--release",
        "release.json",
        "--public-keys-env",
        "PUBLIC_KEYS",
      ]),
      throwsA(isA<FormatException>()),
    );
  });

  test("3.1 signing surfaces contain no removed direct key options", () {
    const files = [
      "lib/src/release_cli/publish_command.dart",
      "lib/src/release_cli/sign_command.dart",
      "lib/src/release_cli/validate_command.dart",
      "lib/src/release_cli/release_signing_resolver.dart",
      "lib/src/cli/verify_command.dart",
      "README.md",
      "SECURITY.md",
      "docs/github-actions-ci-cd.md",
      "docs/publishing.md",
      "docs/release-key-management.md",
      "docs/migration/3.0-to-3.1.md",
    ];
    const removedOptions = [
      "--public-key-id",
      "--private-key-env",
      "--private-key-file",
      "--public-keys-env",
    ];
    for (final relativePath in files) {
      final source = File(relativePath).readAsStringSync();
      for (final option in removedOptions) {
        expect(source, isNot(contains(option)),
            reason: "$relativePath: $option");
      }
    }
    final migration = File("docs/migration/3.0-to-3.1.md").readAsStringSync();
    expect(migration, contains("removed in 3.1"));
    expect(migration, contains("keys adopt"));
    expect(migration, contains("encrypted bundle"));
    expect(migration, contains("Delete the plaintext"));
  });

  test("fingerprint-derived key IDs are stable and 24 hex characters",
      () async {
    final keyPair =
        await Ed25519().newKeyPairFromSeed(List<int>.generate(32, (i) => i));
    final publicKey = await keyPair.extractPublicKey();
    final keyId = releaseKeyIdForPublicKey(publicKey.bytes);
    expect(keyId, matches(RegExp(r"^release-[0-9a-f]{24}$")));
    expect(releaseKeyFingerprint(publicKey.bytes), startsWith("sha256:"));
    keyPair.destroy();
  });

  test("local store round trips seeds with restrictive permissions", () async {
    final root =
        await Directory.systemTemp.createTemp("release_key_store_test_");
    addTearDown(() => root.delete(recursive: true));
    final store = LocalFileReleaseKeyStore(rootDirectory: root);
    final seed = List<int>.generate(32, (i) => i);
    await store.write(
      profileId: "0123456789abcdef0123456789abcdef",
      keyId: "release-012345678901234567890123",
      seed: seed,
    );
    expect(
      await store.read(
        profileId: "0123456789abcdef0123456789abcdef",
        keyId: "release-012345678901234567890123",
      ),
      seed,
    );
    if (Platform.isLinux || Platform.isMacOS) {
      expect((await root.stat()).mode & 0x1ff, 0x1c0);
    }
  });

  test("bundle round trips and hides authentication failures", () async {
    const codec = ReleaseKeyBundleCodec();
    final bundle = await codec.encrypt(
      payload: const {
        "schemaVersion": 1,
        "profile": {"profileId": "0123456789abcdef0123456789abcdef"},
        "privateKeys": {"release-key": "c2VjcmV0"},
      },
      passphrase: "correct horse battery staple",
    );
    expect(
      await codec.decrypt(
        envelope: bundle,
        passphrase: "correct horse battery staple",
      ),
      isA<Map<String, Object?>>(),
    );
    await expectLater(
      codec.decrypt(
        envelope: bundle,
        passphrase: "wrong horse battery staple",
      ),
      throwsA(
        predicate<Object>(
          (error) =>
              error.toString() ==
              "FormatException: Unable to authenticate release key bundle.",
        ),
      ),
    );
  });

  test("keygen is idempotent and rotation is two phase", () async {
    final project =
        await Directory.systemTemp.createTemp("release_key_project_");
    final storeRoot =
        await Directory.systemTemp.createTemp("release_key_secret_");
    addTearDown(() => project.delete(recursive: true));
    addTearDown(() => storeRoot.delete(recursive: true));
    final store = LocalFileReleaseKeyStore(rootDirectory: storeRoot);
    final manager = ReleaseKeyManager(
      projectRoot: project,
      feedUrl: Uri.parse("https://updates.example.com/app-archive.json"),
      store: store,
    );
    final output = StringBuffer();
    final first = await manager.keygen(output);
    final second = await manager.keygen(output);
    expect(second.activeKeyId, first.activeKeyId);
    final pending = await manager.rotate(output);
    expect(pending.activeKeyId, first.activeKeyId);
    expect(pending.pendingKeyId, isNotNull);
    final active = await manager.activate(output);
    expect(active.activeKeyId, pending.pendingKeyId);
    expect(active.publicKeys, contains(first.activeKeyId));
  });

  test("encrypted backup restores a profile and adoption preserves legacy IDs",
      () async {
    final sourceProject =
        await Directory.systemTemp.createTemp("release_key_source_");
    final sourceStoreRoot =
        await Directory.systemTemp.createTemp("release_key_source_store_");
    final destinationProject =
        await Directory.systemTemp.createTemp("release_key_destination_");
    final destinationStoreRoot = await Directory.systemTemp.createTemp(
      "release_key_destination_store_",
    );
    final adoptedProject =
        await Directory.systemTemp.createTemp("release_key_adopted_");
    final adoptedStoreRoot =
        await Directory.systemTemp.createTemp("release_key_adopted_store_");
    addTearDown(() => sourceProject.delete(recursive: true));
    addTearDown(() => sourceStoreRoot.delete(recursive: true));
    addTearDown(() => destinationProject.delete(recursive: true));
    addTearDown(() => destinationStoreRoot.delete(recursive: true));
    addTearDown(() => adoptedProject.delete(recursive: true));
    addTearDown(() => adoptedStoreRoot.delete(recursive: true));

    const feed = "https://updates.example.com/app-archive.json";
    final sourceStore =
        LocalFileReleaseKeyStore(rootDirectory: sourceStoreRoot);
    final sourceManager = ReleaseKeyManager(
      projectRoot: sourceProject,
      feedUrl: Uri.parse(feed),
      store: sourceStore,
    );
    final sourceProfile = await sourceManager.keygen(StringBuffer());
    final bundleFile = File(path.join(sourceProject.path, "release-key.dukey"));
    const passphrase = "correct horse battery staple";
    await sourceManager.export(
      outputFile: bundleFile,
      passphrase: passphrase,
      publicOnly: false,
      force: false,
    );
    final bundleText = await bundleFile.readAsString();
    await expectLater(
      const ReleaseKeyBundleCodec().decrypt(
        envelope: bundleText.replaceFirst('"ciphertext"', '"ciphertextX"'),
        passphrase: passphrase,
      ),
      throwsA(
        predicate<Object>(
          (error) =>
              error.toString() ==
              "FormatException: Unable to authenticate release key bundle.",
        ),
      ),
    );

    final destinationStore =
        LocalFileReleaseKeyStore(rootDirectory: destinationStoreRoot);
    final destinationManager = ReleaseKeyManager(
      projectRoot: destinationProject,
      feedUrl: Uri.parse(feed),
      store: destinationStore,
    );
    final restored = await destinationManager.importBundle(
      inputFile: bundleFile,
      passphrase: passphrase,
      output: StringBuffer(),
    );
    expect(restored.activeKeyId, sourceProfile.activeKeyId);
    expect(
      await destinationStore.read(
        profileId: restored.profileId,
        keyId: restored.activeKeyId,
      ),
      await sourceStore.read(
        profileId: sourceProfile.profileId,
        keyId: sourceProfile.activeKeyId,
      ),
    );

    final legacySeed = List<int>.generate(32, (index) => index);
    final legacyPair = await Ed25519().newKeyPairFromSeed(legacySeed);
    final legacyPublic = await legacyPair.extractPublicKey();
    legacyPair.destroy();
    final adopted = await ReleaseKeyManager(
      projectRoot: adoptedProject,
      feedUrl: Uri.parse(feed),
      store: LocalFileReleaseKeyStore(rootDirectory: adoptedStoreRoot),
    ).adopt(
      input: LegacyReleaseKeyAdoptionInput(
        keyId: "stable-2026",
        privateSeed: legacySeed,
        publicKeys: {"stable-2026": base64Encode(legacyPublic.bytes)},
      ),
      output: StringBuffer(),
    );
    expect(adopted.activeKeyId, "stable-2026");
  });

  test("legacy adoption input is strict and preserves the selected key ID",
      () async {
    const baseInput = <String, Object?>{
      "schemaVersion": 1,
      "keyId": "stable-2026",
      "privateSeed": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
      "publicKeys": {
        "stable-2026": "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=",
      },
    };
    final parsed = LegacyReleaseKeyAdoptionInput.fromJson(baseInput);
    expect(parsed.keyId, "stable-2026");
    expect(parsed.privateSeed, hasLength(32));
    expect(parsed.publicKeys, contains("stable-2026"));

    expect(
      () => LegacyReleaseKeyAdoptionInput.fromJson({
        ...baseInput,
        "unexpected": true,
      }),
      throwsFormatException,
    );
    expect(
      () => LegacyReleaseKeyAdoptionInput.fromJson({
        ...baseInput,
        "publicKeys": <String, Object?>{},
      }),
      throwsFormatException,
    );
    expect(
      () => LegacyReleaseKeyAdoptionInput.fromJson({
        ...baseInput,
        "keyId": "missing-key",
      }),
      throwsA(isA<StateError>()),
    );
  });

  test("keys adopt exports an encrypted bundle and warns about plaintext input",
      () async {
    final project =
        await Directory.systemTemp.createTemp("release_key_adopt_cli_");
    addTearDown(() => project.delete(recursive: true));
    await File(path.join(project.path, "desktop_updater.yaml")).writeAsString(
      "updates:\n  baseUrl: https://updates.example.com\n",
    );
    final inputFile = File(path.join(project.path, "legacy-adoption.json"));
    await inputFile.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 1,
            "keyId": "stable-2026",
            "privateSeed": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
            "publicKeys": {
              "stable-2026": "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=",
            },
          })}\n",
    );
    final bundleFile = File(path.join(project.path, "release-key.dukey"));
    final store = LocalFileReleaseKeyStore(
      rootDirectory: Directory(path.join(project.path, ".release-key-store")),
    );
    final output = StringBuffer();

    final exitCode = await runReleaseCommand(
      [
        "keys",
        "adopt",
        "--input",
        inputFile.path,
        "--output",
        bundleFile.path,
        "--passphrase-env",
        "BUNDLE_PASSPHRASE",
      ],
      projectRoot: project,
      output: output,
      environment: const {
        "BUNDLE_PASSPHRASE": "correct horse battery staple",
      },
      keyStore: store,
    );

    expect(exitCode, 0);
    expect(await inputFile.exists(), isTrue);
    expect(await bundleFile.exists(), isTrue);
    expect(output.toString(), contains("does not sign releases directly"));
    expect(output.toString(), contains("Delete the plaintext adoption input"));
    expect(
        output.toString(), contains("CI and other machines must import only"));
    final payload = await const ReleaseKeyBundleCodec().decrypt(
      envelope: await bundleFile.readAsString(),
      passphrase: "correct horse battery staple",
    );
    final profile = ReleaseKeyProfile.fromJson(
      payload["profile"]! as Map<String, Object?>,
    );
    expect(profile.activeKeyId, "stable-2026");
    expect(payload["privateKeys"], contains("stable-2026"));
  });

  test("public-only export never opens the private-key store", () async {
    final project =
        await Directory.systemTemp.createTemp("release_key_public_export_");
    addTearDown(() => project.delete(recursive: true));
    final store = _NoReadReleaseKeyStore();
    final manager = ReleaseKeyManager(
      projectRoot: project,
      feedUrl: Uri.parse("https://updates.example.com/app-archive.json"),
      store: store,
    );
    await manager.keygen(StringBuffer());
    final outputFile = File(path.join(project.path, "public.json"));
    await manager.export(
      outputFile: outputFile,
      passphrase: "unused for public export",
      publicOnly: true,
      force: false,
    );
    expect(await outputFile.exists(), isTrue);
    expect(store.readCalls, 0);
    expect(await outputFile.readAsString(), contains("publicKeys"));
  });

  test("default profile resolves signing material without a profile flag",
      () async {
    final project =
        await Directory.systemTemp.createTemp("release_key_resolver_");
    final storeRoot =
        await Directory.systemTemp.createTemp("release_key_resolver_store_");
    addTearDown(() => project.delete(recursive: true));
    addTearDown(() => storeRoot.delete(recursive: true));
    await File(path.join(project.path, "desktop_updater.yaml")).writeAsString(
      "updates:\n  baseUrl: https://updates.example.com\n",
    );
    final store = LocalFileReleaseKeyStore(rootDirectory: storeRoot);
    final manager = ReleaseKeyManager(
      projectRoot: project,
      feedUrl: Uri.parse("https://updates.example.com/app-archive.json"),
      store: store,
    );
    final profile = await manager.keygen(StringBuffer());
    final results = buildSignParser().parse(["--release", "release.json"]);
    final config = await ReleasePublishConfig.load(
      projectRoot: project,
      cliOverrides: const ReleasePublishOverrides(),
    );
    final signing = await resolveReleaseSigningOptions(
      results: results,
      projectRoot: project,
      expectedFeedUrl: config.baseUrl.resolve("app-archive.json"),
      keyStore: store,
    );
    expect(signing.publicKeyId, profile.activeKeyId);
    expect(signing.trustedReleasePublicKeys, profile.publicKeys);
  });

  test("profile parser rejects unknown fields and private material", () {
    expect(
      () => ReleaseKeyProfile.fromJson({
        "schemaVersion": 1,
        "profileId": "0123456789abcdef0123456789abcdef",
        "feedUrl": "https://updates.example.com/app-archive.json",
        "activeKeyId": "release-key",
        "publicKeys": {"release-key": base64Encode(List<int>.filled(32, 1))},
        "privateKey": base64Encode(List<int>.filled(32, 2)),
      }),
      throwsFormatException,
    );
  });
}

final class _NoReadReleaseKeyStore implements ReleaseKeySecretStore {
  var readCalls = 0;

  @override
  String get description => "test store";

  @override
  Future<List<int>?> read({
    required String profileId,
    required String keyId,
  }) async {
    readCalls += 1;
    throw StateError("private store must not be opened");
  }

  @override
  Future<void> write({
    required String profileId,
    required String keyId,
    required List<int> seed,
  }) async {}

  @override
  Future<void> delete({
    required String profileId,
    required String keyId,
  }) async {}
}
