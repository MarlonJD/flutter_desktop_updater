import "package:flutter_test/flutter_test.dart";

import "../example/lib/smoke_update_flow.dart";

void main() {
  test("smoke trust configuration preserves the configured key id", () {
    expect(
      configuredTrustedReleasePublicKeys(
        const <String, String>{
          trustedPublicKeyIdEnvironment: "smoke-key",
          trustedPublicKeyEnvironment: "public-key",
        },
        fallbackKeyId: "fallback",
        fallbackPublicKey: "fallback-key",
      ),
      const <String, String>{"smoke-key": "public-key"},
    );
  });

  test("configured public key without its id fails closed", () {
    expect(
      () => configuredTrustedReleasePublicKeys(
        const <String, String>{
          trustedPublicKeyEnvironment: "public-key",
        },
        fallbackKeyId: "fallback",
        fallbackPublicKey: "fallback-key",
      ),
      throwsStateError,
    );
  });

  test("controller smoke checks, stages, then installs in order", () async {
    final events = <String>[];
    final configuration = SmokeUpdateConfiguration.fromEnvironment(
      _enabledSmokeEnvironment,
    );

    await runControllerOwnedSmokeUpdate(
      configuration: configuration,
      checkForUpdate: () async => events.add("check"),
      updateIsAvailable: () => true,
      downloadAndStage: () async => events.add("download"),
      install: () async => events.add("install"),
      writeMarker: (value) async => events.add("marker:$value"),
      writeDiagnostics: (event) async => events.add("diagnostics:$event"),
    );

    expect(events, <String>[
      "marker:checking",
      "diagnostics:checking",
      "check",
      "marker:downloading",
      "diagnostics:downloading",
      "download",
      "marker:installing",
      "diagnostics:installing",
      "install",
    ]);
  });

  test("controller smoke records a failed signed selection", () async {
    final markers = <String>[];
    final configuration = SmokeUpdateConfiguration.fromEnvironment(
      _enabledSmokeEnvironment,
    );

    await expectLater(
      runControllerOwnedSmokeUpdate(
        configuration: configuration,
        checkForUpdate: () async {},
        updateIsAvailable: () => false,
        downloadAndStage: () async {},
        install: () async {},
        writeMarker: (value) async => markers.add(value),
        writeDiagnostics: (_) async {},
      ),
      throwsStateError,
    );
    expect(markers, hasLength(2));
    expect(markers.last, startsWith("failed:"));
  });

  test("controller smoke requires its signed feed and durable store", () {
    expect(
      () => SmokeUpdateConfiguration.fromEnvironment(
        const <String, String>{controllerSmokeEnvironment: "1"},
      ),
      throwsStateError,
    );
  });
}

const _enabledSmokeEnvironment = <String, String>{
  controllerSmokeEnvironment: "1",
  appArchiveEnvironment: "http://127.0.0.1:1234/app-archive.json",
  expectedPackageIdEnvironment: "com.example.app",
  trustedPublicKeyIdEnvironment: "smoke-key",
  trustedPublicKeyEnvironment: "public-key",
  recoveryStoreEnvironment: "/tmp/recovery.json",
  smokeMarkerEnvironment: "/tmp/marker",
  smokeDiagnosticsEnvironment: "/tmp/diagnostics",
};
