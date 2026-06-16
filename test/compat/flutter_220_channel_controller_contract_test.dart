import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

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

  test("skipInitialVersionCheck remains a passive initialization mode", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );

    expect(controller.skipInitialVersionCheck, isTrue);
    expect(controller.state, isA<UpdateIdle>());
  });
}
