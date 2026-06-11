import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelDesktopUpdater();
  const channel = MethodChannel("desktop_updater");

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return "42";
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test("getPlatformVersion", () async {
    expect(await platform.getPlatformVersion(), "42");
  });

  test("getCurrentVersion keeps returning the legacy build string", () async {
    expect(await platform.getCurrentVersion(), "42");
  });

  test("getCurrentVersionInfo returns structured version data separately",
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == "getCurrentVersionInfo") {
        return <String, String?>{
          "version": "1.2.3",
          "buildNumber": null,
        };
      }
      return "42";
    });

    expect(await platform.getCurrentVersionInfo(), {
      "version": "1.2.3",
      "buildNumber": null,
    });
  });
}
