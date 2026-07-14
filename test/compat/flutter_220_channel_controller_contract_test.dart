import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:plugin_platform_interface/plugin_platform_interface.dart";

const _channel = MethodChannel("desktop_updater");

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test("installUpdate keeps 2.2.0 MethodChannel argument shape", () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await MethodChannelDesktopUpdater().installUpdate(
      stagingPath: "/tmp/staged",
      removedFiles: const ["old.dll"],
      allowUnsignedMacOSUpdates: true,
      diagnosticsLogPath: "/tmp/helper.jsonl",
    );

    expect(capturedCall.method, "installUpdate");
    expect(capturedCall.arguments, {
      "stagingPath": "/tmp/staged",
      "removedFiles": <String>["old.dll"],
      "allowUnsignedMacOSUpdates": true,
      "diagnosticsLogPath": "/tmp/helper.jsonl",
    });
  });

  test("restartApp keeps the released channel method and null arguments",
      () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await MethodChannelDesktopUpdater().restartApp();

    expect(capturedCall.method, "restartApp");
    expect(capturedCall.arguments, isNull);
  });

  test("released platform subclasses retain legacy install dispatch", () async {
    final platform = _ReleasedPlatformImplementation();

    await platform.installUpdateWithContext(
      stagingPath: "/tmp/staged",
      packageId: "com.example.app",
      stageProvenanceSha256: "a" * 64,
      stageProvenanceNonce: "123e4567-e89b-42d3-a456-426614174000",
      stageProvenanceEntries: const [
        {"path": "app", "kind": "file", "length": 1},
      ],
      expectedArtifactSha256: "b" * 64,
    );

    expect(platform.installCalls, 1);
  });

  test("skipInitialVersionCheck remains a passive initialization mode", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );

    expect(controller.skipInitialVersionCheck, isTrue);
    expect(controller.state, isA<UpdateIdle>());
  });
}

class _ReleasedPlatformImplementation
    with MockPlatformInterfaceMixin
    implements DesktopUpdaterPlatform {
  int installCalls = 0;

  @override
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
    bool allowUnsignedMacOSUpdates = false,
    String? diagnosticsLogPath,
  }) async {
    installCalls += 1;
  }

  @override
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() =>
      Future.value(
        const MacOSInstallLocationStatus(
          kind: MacOSInstallLocationKind.unsupported,
          bundlePath: null,
          targetPath: null,
        ),
      );

  @override
  Future<String?> getCurrentVersion() => Future.value();

  @override
  Future<String?> getExecutablePath() => Future.value();

  @override
  Future<String?> getPlatformVersion() => Future.value();

  @override
  Future<void> moveMacOSAppToApplications({bool replaceExisting = false}) =>
      Future.value();

  @override
  Future<void> openMacOSBackgroundItemsSettings() => Future.value();

  @override
  Future<void> restartApp() => Future.value();
}
