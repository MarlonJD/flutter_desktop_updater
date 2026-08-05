import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/json/strict_json.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_bundle.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_manager.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
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
    expect((await root.stat()).mode & 0x1ff, 0x1c0);
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
      publicKeyId: "stable-2026",
      privateKeyBase64: base64Encode(legacySeed),
      trustedPublicKeys: {"stable-2026": base64Encode(legacyPublic.bytes)},
      output: StringBuffer(),
    );
    expect(adopted.activeKeyId, "stable-2026");
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
      environment: const {},
      expectedFeedUrl: config.baseUrl.resolve("app-archive.json"),
      keyStore: store,
      requirePublicKeys: false,
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
