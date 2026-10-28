import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  group(
    "macOS helper policy pin preflight",
    () {
      late Directory root;
      late File appInfo;

      setUp(() async {
        root = await Directory.systemTemp.createTemp("helper_packaging_");
        appInfo =
            File(path.join(root.path, "Host.app", "Contents", "Info.plist"));
        await appInfo.parent.create(recursive: true);
        await appInfo.writeAsString("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.desktopUpdaterSmoke</string>
</dict></plist>
""");
      });

      tearDown(() => root.delete(recursive: true));

      Future<ProcessResult> embed(
        String? digest, {
        Map<String, String> overrides = const {},
      }) =>
          Process.run(
            "/bin/sh",
            [
              File("macos/install_helper/embed_install_helper.sh").absolute.path
            ],
            environment: {
              "TARGET_BUILD_DIR": root.path,
              "CONTENTS_FOLDER_PATH": "Host.app/Contents",
              "DERIVED_FILE_DIR": path.join(root.path, "derived"),
              "DESKTOP_UPDATER_HELPER_INFO_TEMPLATE": File(
                "macos/install_helper/Configuration/Helper-Info.plist",
              ).absolute.path,
              "DESKTOP_UPDATER_SEALED_POLICY_PATH": File(
                "example/macos/Runner/DesktopUpdaterHelperPolicy.json",
              ).absolute.path,
              if (digest != null)
                "DESKTOP_UPDATER_SEALED_POLICY_SHA256": digest,
              "CODE_SIGN_IDENTITY": "-",
              "EXPANDED_CODE_SIGN_IDENTITY": "-",
              ...overrides,
            },
            includeParentEnvironment: false,
          );

      for (final digest in [
        null,
        "",
        "REPLACE_WITH_GENERATED_SHA256",
        "a" * 63,
        "a" * 65,
        "A" * 64,
        "g" * 64,
      ]) {
        test("rejects malformed pin '$digest' before packaging", () async {
          final before = await appInfo.readAsBytes();
          final result = await embed(digest);
          expect(result.exitCode, 1);
          expect(
              result.stderr, contains("64 lowercase hexadecimal characters"));
          expect(
            result.stderr,
            contains("dart run desktop_updater:release helper-policy"),
          );
          expect(await appInfo.readAsBytes(), before);
          expect(
            Directory(path.join(root.path, "derived")).existsSync(),
            isFalse,
          );
        });
      }

      test("requires the ad hoc policy path and digest together", () async {
        final before = await appInfo.readAsBytes();
        for (final overrides in [
          {"DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_PATH": "unused.json"},
          {"DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_SHA256": "0" * 64},
        ]) {
          final result = await embed("0" * 64, overrides: overrides);
          expect(result.exitCode, 1);
          expect(
            result.stderr,
            contains("path and digest must be provided together"),
          );
          expect(await appInfo.readAsBytes(), before);
          expect(
            Directory(path.join(root.path, "derived")).existsSync(),
            isFalse,
          );
        }
      });

      test("validates the selected ad hoc pin before reading metadata",
          () async {
        final result = await embed(
          "0" * 64,
          overrides: {
            "DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_PATH": "unused.json",
            "DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_SHA256": "placeholder",
          },
        );
        expect(result.exitCode, 1);
        expect(result.stderr, contains("64 lowercase hexadecimal characters"));
        expect(
            Directory(path.join(root.path, "derived")).existsSync(), isFalse);
      });

      test(
        "uses the ad hoc pin even if the production pin is malformed",
        () async {
          final before = await appInfo.readAsBytes();
          final result = await embed(
            "placeholder",
            overrides: {
              "DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_PATH": File(
                "example/macos/Runner/DesktopUpdaterHelperPolicy.json",
              ).absolute.path,
              "DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_SHA256": "0" * 64,
            },
          );
          expect(result.exitCode, 1);
          expect(
              result.stderr, contains("sealed policy digest does not match"));
          expect(await appInfo.readAsBytes(), before);
        },
        skip: !Platform.isMacOS,
      );

      test(
        "rejects a stale pin without changing the host metadata",
        () async {
          final before = await appInfo.readAsBytes();
          final result = await embed("0" * 64);
          expect(result.exitCode, 1);
          expect(
              result.stderr, contains("sealed policy digest does not match"));
          expect(
            result.stderr,
            contains("regenerate the canonical JSON and .sha256"),
          );
          expect(await appInfo.readAsBytes(), before);
          expect(
            Directory(path.join(root.path, "Host.app", "Contents", "Helpers"))
                .existsSync(),
            isFalse,
          );
        },
        skip: !Platform.isMacOS,
      );
    },
    skip: Platform.isWindows,
  );
}
