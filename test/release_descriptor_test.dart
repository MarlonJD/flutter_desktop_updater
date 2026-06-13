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

  test("keeps buildNumber optional in release descriptors", () {
    final descriptor = ReleaseDescriptor.fromJson(
      _descriptorJson()..remove("buildNumber"),
    );

    expect(descriptor.buildNumber, isNull);
    expect(descriptor.toJson(), isNot(contains("buildNumber")));
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

  test("parses optional minimum OS metadata", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "minimumOS": {
        "macos": "13.0",
        "windows": "10.0.19045",
        "linux": "glibc-2.35",
      },
    });

    expect(descriptor.minimumOS["macos"], "13.0");
    expect(descriptor.minimumOSForPlatform("linux"), "glibc-2.35");
    expect(descriptor.minimumOSForPlatform("freebsd"), isNull);
    expect(descriptor.toJson()["minimumOS"], {
      "macos": "13.0",
      "windows": "10.0.19045",
      "linux": "glibc-2.35",
    });
  });

  test("omits minimum OS when descriptor metadata does not provide it", () {
    final descriptor = ReleaseDescriptor.fromJson(_descriptorJson());

    expect(descriptor.minimumOS, isEmpty);
    expect(descriptor.toJson(), isNot(contains("minimumOS")));
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
