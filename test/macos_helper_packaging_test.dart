import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";
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
              File("macos/install_helper/embed_install_helper.sh")
                  .absolute
                  .path,
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
            result.stderr,
            contains("64 lowercase hexadecimal characters"),
          );
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
          Directory(path.join(root.path, "derived")).existsSync(),
          isFalse,
        );
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
            result.stderr,
            contains("sealed policy digest does not match"),
          );
          expect(
            result.stderr,
            contains(
              "pin source: DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_SHA256",
            ),
          );
          expect(
            result.stderr,
            contains(
              "policy source: DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_PATH",
            ),
          );
          expect(result.stderr, contains("selected policy:"));
          expect(result.stderr, contains("expected SHA-256: ${"0" * 64}"));
          expect(result.stderr, contains("actual SHA-256:"));
          expect(await appInfo.readAsBytes(), before);
        },
        skip: !Platform.isMacOS,
      );

      test(
        "rejects a stale pin without changing the host metadata",
        () async {
          final before = await appInfo.readAsBytes();
          final result = await embed(
            "0" * 64,
            overrides: {
              "DERIVED_FILE_DIR": path.join(root.path, r"derived \ build 中文"),
            },
          );
          expect(result.exitCode, 1);
          expect(
            result.stderr,
            contains("sealed policy digest does not match"),
          );
          expect(
            result.stderr,
            contains("regenerate the canonical JSON and .sha256"),
          );
          expect(
            result.stderr,
            contains("pin source: DESKTOP_UPDATER_SEALED_POLICY_SHA256"),
          );
          expect(
            result.stderr,
            contains("policy source: DESKTOP_UPDATER_SEALED_POLICY_PATH"),
          );
          expect(
            result.stderr,
            contains(
              "selected policy: ${File("example/macos/Runner/DesktopUpdaterHelperPolicy.json").absolute.path}",
            ),
          );
          expect(result.stderr, contains("expected SHA-256: ${"0" * 64}"));
          final policy = await File(
            "example/macos/Runner/DesktopUpdaterHelperPolicy.json",
          ).readAsString();
          final actual = sha256.convert(utf8.encode(policy.trimRight()));
          expect(result.stderr, contains("actual SHA-256: $actual"));
          expect(await appInfo.readAsBytes(), before);
          expect(
            Directory(path.join(root.path, "Host.app", "Contents", "Helpers"))
                .existsSync(),
            isFalse,
          );
        },
        skip: !Platform.isMacOS,
      );

      test(
        "Xcode requires the generated host plist as a build input",
        () async {
          final before = await appInfo.readAsBytes();
          final result = await embed(
            "0" * 64,
            overrides: {
              "XCODE_VERSION_ACTUAL": "2710",
              "SCRIPT_INPUT_FILE_COUNT": "1",
              "SCRIPT_INPUT_FILE_0":
                  path.join(root.path, "Runner", "Info.plist"),
            },
          );
          expect(result.exitCode, 1);
          expect(
            result.stderr,
            contains(r"add $(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"),
          );
          expect(await appInfo.readAsBytes(), before);
          expect(
            Directory(path.join(root.path, "derived")).existsSync(),
            isFalse,
          );
        },
        skip: !Platform.isMacOS,
      );

      test(
        "managed phase embeds a generated pair through spaces and Unicode paths",
        () async {
          final consumer = Directory(path.join(root.path, "consumer app 中文"));
          final runner = Directory(path.join(consumer.path, "macos", "Runner"));
          final config =
              File(path.join(runner.path, "Configs", "AppInfo.xcconfig"));
          await config.parent.create(recursive: true);
          await config.writeAsString(
            "PRODUCT_BUNDLE_IDENTIFIER = com.example.desktopUpdaterSmoke\n",
          );
          final sealed =
              File(path.join(runner.path, "DesktopUpdaterHelperPolicy.json"));
          await File(
            "example/macos/Runner/DesktopUpdaterHelperPolicy-Debug.json",
          ).copy(sealed.path);
          final output = StringBuffer();
          expect(
            await runReleaseCommand(
              ["helper-policy"],
              projectRoot: consumer,
              output: output,
            ),
            0,
            reason: "$output",
          );
          Future<ProcessResult> runManagedPhase() async {
            return Process.run(
              "dart",
              [File("bin/release.dart").absolute.path, "helper-embed"],
              environment: {
                "PATH": Platform.environment["PATH"]!,
                "PROJECT_DIR": path.join(consumer.path, "macos"),
                "TARGET_BUILD_DIR": root.path,
                "CONTENTS_FOLDER_PATH": "Host.app/Contents",
                "DERIVED_FILE_DIR": path.join(root.path, "derived build 中文"),
                "CODE_SIGN_IDENTITY": "-",
                "EXPANDED_CODE_SIGN_IDENTITY": "-",
                "XCODE_VERSION_ACTUAL": "2710",
                "SCRIPT_INPUT_FILE_COUNT": "1",
                "SCRIPT_INPUT_FILE_0": appInfo.path,
              },
              includeParentEnvironment: false,
            );
          }

          final digest =
              File(path.join(runner.path, "DesktopUpdaterHelperPolicy.sha256"));
          final reviewedPin = await digest.readAsString();
          final result = await runManagedPhase();
          expect(
            result.exitCode,
            0,
            reason: "${result.stdout}\n${result.stderr}",
          );
          final helper = File(
            path.join(
              root.path,
              "Host.app",
              "Contents",
              "Helpers",
              "DesktopUpdaterInstallHelper",
            ),
          );
          expect(await helper.exists(), isTrue);
          final helperBefore = await helper.readAsBytes();
          final hostBefore = await appInfo.readAsBytes();
          final policy =
              jsonDecode(await sealed.readAsString()) as Map<String, dynamic>;
          final generated = path.join(
            root.path,
            "derived build 中文",
            "desktop-updater-install-helper",
          );
          final escapedPolicy =
              await File(path.join(generated, "SealedPolicy.json"))
                  .copy(path.join(root.path, r"policy \ canonical.json"));
          final verified = await Process.run("/bin/sh", [
            File("macos/install_helper/verify_install_helper_layout.sh")
                .absolute
                .path,
            path.join(root.path, "Host.app"),
            policy["helperServiceId"] as String,
            (policy["allowedHelperSigner"] as Map)["value"] as String,
            path.join(generated, "Helper-Info.plist"),
            escapedPolicy.path,
          ]);
          expect(
            verified.exitCode,
            0,
            reason: "${verified.stdout}\n${verified.stderr}",
          );
          policy["policyVersion"] = (policy["policyVersion"] as int) + 1;
          await sealed.writeAsString("${jsonEncode(policy)}\n");
          final rejected = await runManagedPhase();
          expect(rejected.exitCode, 1);
          expect(
            "${rejected.stdout}${rejected.stderr}",
            contains("sealed policy digest does not match"),
          );
          expect(await helper.readAsBytes(), helperBefore);
          expect(await appInfo.readAsBytes(), hostBefore);
          expect(await digest.readAsString(), reviewedPin);
        },
        skip: !Platform.isMacOS,
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
    skip: Platform.isWindows,
  );
}
