@TestOn("windows")

import "dart:io";

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
    expect(await store.read(profileId: profileId, keyId: keyId), seed);
    await store.delete(profileId: profileId, keyId: keyId);
    expect(await store.read(profileId: profileId, keyId: keyId), isNull);
  });
}
