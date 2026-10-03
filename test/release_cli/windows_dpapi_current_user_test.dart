@TestOn("windows")

import "dart:io";

import "package:desktop_updater/src/release_cli/keys/release_key_manager.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("Windows CurrentUser DPAPI round-trips a release seed", () async {
    final root = await Directory.systemTemp.createTemp("dpapi_current_user_");
    addTearDown(() => root.delete(recursive: true));
    final store = WindowsDpapiReleaseKeyStore(rootDirectory: root);
    const profileId = "0123456789abcdef0123456789abcdef";
    const keyId = "release-current-user";
    final seed = List<int>.generate(32, (index) => 255 - index);

    await store.write(profileId: profileId, keyId: keyId, seed: seed);
    await store.write(profileId: profileId, keyId: keyId, seed: seed);
    expect(await store.read(profileId: profileId, keyId: keyId), seed);
    await store.delete(profileId: profileId, keyId: keyId);
    expect(await store.read(profileId: profileId, keyId: keyId), isNull);
  });

  test("Windows CurrentUser DPAPI supports importing the same backup twice",
      () async {
    final sourceProject =
        await Directory.systemTemp.createTemp("dpapi_backup_source_");
    final sourceStoreRoot =
        await Directory.systemTemp.createTemp("dpapi_backup_source_store_");
    final destinationProject =
        await Directory.systemTemp.createTemp("dpapi_backup_destination_");
    final destinationStoreRoot = await Directory.systemTemp.createTemp(
      "dpapi_backup_destination_store_",
    );
    addTearDown(() => sourceProject.delete(recursive: true));
    addTearDown(() => sourceStoreRoot.delete(recursive: true));
    addTearDown(() => destinationProject.delete(recursive: true));
    addTearDown(() => destinationStoreRoot.delete(recursive: true));

    final feedUrl = Uri.parse("https://updates.example.com/app-archive.json");
    final sourceManager = ReleaseKeyManager(
      projectRoot: sourceProject,
      feedUrl: feedUrl,
      store: WindowsDpapiReleaseKeyStore(rootDirectory: sourceStoreRoot),
    );
    final sourceProfile = await sourceManager.keygen(StringBuffer());
    final bundleFile = File("${sourceProject.path}/release-key.dukey");
    const passphrase = "F07 CurrentUser test backup";
    await sourceManager.export(
      outputFile: bundleFile,
      passphrase: passphrase,
      publicOnly: false,
      force: false,
    );

    final destinationManager = ReleaseKeyManager(
      projectRoot: destinationProject,
      feedUrl: feedUrl,
      store: WindowsDpapiReleaseKeyStore(rootDirectory: destinationStoreRoot),
    );
    final firstImport = await destinationManager.importBundle(
      inputFile: bundleFile,
      passphrase: passphrase,
      output: StringBuffer(),
    );
    final secondImport = await destinationManager.importBundle(
      inputFile: bundleFile,
      passphrase: passphrase,
      output: StringBuffer(),
    );

    expect(firstImport.profileId, sourceProfile.profileId);
    expect(secondImport.profileId, firstImport.profileId);
    expect(secondImport.activeKeyId, firstImport.activeKeyId);
  });
}
