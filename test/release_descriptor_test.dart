import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("parses a valid release descriptor", () {
    final descriptor = ReleaseDescriptor.fromJson(_descriptorJson());

    expect(descriptor.schemaVersion, 3);
    expect(descriptor.artifact.kind, "zip");
    expect(descriptor.install.strategy, "wholeBundleReplace");
  });

  test("rejects missing artifact fields", () {
    final json = _descriptorJson()..remove("artifact");

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsFormatException,
    );
  });

  test("canonical signature json empties signature value", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": "stable-2026-06",
        "value": "abc",
      },
    });

    final signature = descriptor.toCanonicalSignatureJson()["signature"]
        as Map<String, dynamic>;
    expect(signature["value"], "");
  });
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
      "url": "https://cdn.example.com/Example.zip",
      "sha256": "a" * 64,
      "length": 12,
    },
    "install": {"strategy": "wholeBundleReplace"},
    "minimumUpdaterVersion": "2.0.0",
    "generatedAt": "2026-06-11T00:00:00Z",
  };
}
