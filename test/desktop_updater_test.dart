import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/package/zip_release_packager.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;
import "package:plugin_platform_interface/plugin_platform_interface.dart";

const _trustedReleasePublicKeys = <String, String>{
  "stable-2026": "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=",
};

class MockDesktopUpdaterPlatform
    with MockPlatformInterfaceMixin
    implements DesktopUpdaterPlatform {
  String? lastDiagnosticsLogPath;
  bool? lastReplaceExisting;
  MacOSInstallLocationStatus macOSInstallLocationStatus =
      const MacOSInstallLocationStatus(
    kind: MacOSInstallLocationKind.unsupported,
    bundlePath: null,
    targetPath: null,
  );

  @override
  Future<String?> getPlatformVersion() => Future.value("42");

  @override
  Future<void> restartApp() {
    return Future.value();
  }

  @override
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
    bool allowUnsignedMacOSUpdates = false,
    String? diagnosticsLogPath,
  }) {
    lastDiagnosticsLogPath = diagnosticsLogPath;
    return Future.value();
  }

  @override
  Future<String?> getExecutablePath() {
    return Future.value();
  }

  @override
  Future<String?> getCurrentVersion() {
    return Future.value();
  }

  @override
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() {
    return Future.value(macOSInstallLocationStatus);
  }

  @override
  Future<void> moveMacOSAppToApplications({
    bool replaceExisting = false,
  }) {
    lastReplaceExisting = replaceExisting;
    return Future.value();
  }
}

class RecordingMethodChannelDesktopUpdater extends MethodChannelDesktopUpdater {
  bool legacyInstallInvoked = false;

  @override
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
    bool allowUnsignedMacOSUpdates = false,
    String? diagnosticsLogPath,
  }) async {
    legacyInstallInvoked = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final initialPlatform = DesktopUpdaterPlatform.instance;

  test("$MethodChannelDesktopUpdater is the default instance", () {
    expect(initialPlatform, isInstanceOf<MethodChannelDesktopUpdater>());
  });

  test("getPlatformVersion", () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform();
    DesktopUpdaterPlatform.instance = fakePlatform;

    expect(await desktopUpdaterPlugin.getPlatformVersion(), "42");
  });

  test("installUpdate forwards explicit diagnostics log path to platform",
      () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform();
    DesktopUpdaterPlatform.instance = fakePlatform;

    await desktopUpdaterPlugin.installUpdate(
      stagingPath: "/tmp/staged",
      diagnosticsLogPath: "/tmp/helper.jsonl",
    );

    expect(fakePlatform.lastDiagnosticsLogPath, "/tmp/helper.jsonl");
  });

  test("MethodChannel subclass legacy install override remains compatible",
      () async {
    final platform = RecordingMethodChannelDesktopUpdater();
    DesktopUpdaterPlatform.instance = platform;

    await DesktopUpdater().installUpdate(
      stagingPath: "/tmp/staged",
      packageId: "com.example.desktop_updater",
    );

    expect(platform.legacyInstallInvoked, isTrue);
  });

  test("old safe install call loads package identity from stage provenance",
      () async {
    const nonce = "123e4567-e89b-42d3-a456-426614174000";
    final parent = await Directory.systemTemp.createTemp("updater_compat_");
    final forgedStage = await createOwnedStagingDirectory(
      parent: parent,
      nonce: nonce,
    );
    try {
      await File(path.join(forgedStage.path, "example"))
          .writeAsString("payload");
      await writeStagedUpdateProvenance(
        stageRoot: forgedStage,
        nonce: nonce,
        packageId: "com.example.forged",
        descriptorSha256: "a".padRight(64, "a"),
        artifactSha256: "b".padRight(64, "b"),
      );
      late MethodCall capturedCall;
      var methodCallCount = 0;
      const channel = MethodChannel("desktop_updater");
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        methodCallCount += 1;
        capturedCall = call;
        return null;
      });
      DesktopUpdaterPlatform.instance = MethodChannelDesktopUpdater();

      await expectLater(
        DesktopUpdater().installUpdate(stagingPath: forgedStage.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            "message",
            contains("retained verified stage provenance"),
          ),
        ),
      );
      expect(methodCallCount, 0);
      await forgedStage.delete(recursive: true);

      final input = Directory(path.join(parent.path, "input"));
      await input.create();
      await File(path.join(input.path, "example")).writeAsString("payload");
      final output = Directory(path.join(parent.path, "output"));
      final artifact = File(
        path.join(output.path, "Example-2.0.0-linux.zip"),
      );
      final packaged = await const ZipReleasePackager().package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: output,
          packageId: "com.example.provenance",
          appName: "Example",
          version: "2.0.0",
          platform: "linux",
          channel: "stable",
          artifactUrl: artifact.uri,
          installStrategy: "wholeDirectoryReplace",
        ),
      );
      final client = UpdateClient(
        appArchiveUrl: Uri.parse("https://updates.example/app-archive.json"),
        currentVersion: DesktopVersionInfo.parse("1.0.0"),
        platform: "linux",
        stagingParent: parent,
      );
      final staged = await client.downloadVerifyAndStage(
        descriptor: packaged.descriptor,
      );

      await DesktopUpdater().installUpdate(stagingPath: staged.stagingPath);

      expect(
        capturedCall.arguments,
        containsPair(
          "packageId",
          "com.example.provenance",
        ),
      );
      expect(
        capturedCall.arguments,
        containsPair(
          "stageProvenanceNonce",
          staged.stageProvenance.nonce,
        ),
      );
      expect(capturedCall.arguments, contains("stageProvenanceSha256"));
      expect(capturedCall.arguments, contains("stageProvenanceEntries"));
      expect(methodCallCount, 1);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    } finally {
      DesktopUpdaterPlatform.instance = initialPlatform;
      await parent.delete(recursive: true);
    }
  });

  test("checkMacOSInstallLocation forwards to platform", () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform()
      ..macOSInstallLocationStatus = const MacOSInstallLocationStatus(
        kind: MacOSInstallLocationKind.diskImage,
        bundlePath: "/Volumes/Example/Example.app",
        targetPath: "/Applications/Example.app",
      );
    DesktopUpdaterPlatform.instance = fakePlatform;

    final status = await desktopUpdaterPlugin.checkMacOSInstallLocation();

    expect(status.kind, MacOSInstallLocationKind.diskImage);
    expect(status.targetPath, "/Applications/Example.app");
  });

  test("moveMacOSAppToApplications forwards replace policy to platform",
      () async {
    final desktopUpdaterPlugin = DesktopUpdater();
    final fakePlatform = MockDesktopUpdaterPlatform();
    DesktopUpdaterPlatform.instance = fakePlatform;

    await desktopUpdaterPlugin.moveMacOSAppToApplications(
      replaceExisting: true,
    );

    expect(fakePlatform.lastReplaceExisting, isTrue);
  });

  test("checkZipFirstUpdate accepts app-owned request headers provider",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater_");
    try {
      final archive = File(path.join(tempDir.path, "app-archive.json"));
      await archive.writeAsString(
        '{"schemaVersion":3,"appName":"Example","items":[]}',
      );

      final result = await DesktopUpdater().checkZipFirstUpdate(
        appArchiveUrl: archive.uri,
        currentVersion: DesktopVersionInfo.fromParts(versionName: "1.0.0"),
        requestHeadersProvider: (_) => {"x-update-auth": "runtime-token"},
      );

      expect(result, isNull);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("checkZipFirstUpdate pinned keys reject an unsigned archive", () async {
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater_");
    try {
      final archive = File(path.join(tempDir.path, "app-archive.json"));
      await archive.writeAsString(
        '{"schemaVersion":3,"appName":"Example","items":[]}',
      );

      await expectLater(
        DesktopUpdater().checkZipFirstUpdate(
          appArchiveUrl: archive.uri,
          currentVersion: DesktopVersionInfo.fromParts(versionName: "1.0.0"),
          trustedReleasePublicKeys: _trustedReleasePublicKeys,
        ),
        throwsA(isA<FormatException>()),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("downloadZipFirstUpdate pinned keys reject an unsigned descriptor",
      () async {
    final fixture = jsonDecode(
      File("fixtures/compat/signing-ed25519.json").readAsStringSync(),
    ) as Map<String, dynamic>;
    final descriptorJson = Map<String, dynamic>.from(
      fixture["validDescriptor"] as Map<String, dynamic>,
    )..remove("signature");
    final descriptor = ReleaseDescriptor.fromJson(descriptorJson);

    await expectLater(
      DesktopUpdater().downloadZipFirstUpdate(
        appArchiveUrl: Uri.parse("https://updates.example/app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(versionName: "1.0.0"),
        descriptor: descriptor,
        trustedReleasePublicKeys: _trustedReleasePublicKeys,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("release.json signature is required"),
        ),
      ),
    );
  });
}
