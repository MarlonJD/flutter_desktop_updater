import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/release_cli/macos/helper_xcode_setup.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  late Directory root;
  late File project;

  Future<Map<String, dynamic>> parse() async {
    final result = await Process.run(
      "/usr/bin/plutil",
      ["-convert", "json", "-o", "-", project.path],
    );
    expect(result.exitCode, 0, reason: "${result.stdout}${result.stderr}");
    return (jsonDecode(result.stdout as String)
        as Map<String, dynamic>)["objects"] as Map<String, dynamic>;
  }

  Future<void> setup() async {
    final edit = (await prepareHelperXcodeSetup(root))!;
    await edit.apply();
  }

  group(
    "automatic Xcode helper setup",
    () {
      setUp(() async {
        root = await Directory.systemTemp.createTemp("helper xcode 中文 ");
        project = File(
          path.join(root.path, "macos", "Runner.xcodeproj", "project.pbxproj"),
        );
        await project.parent.create(recursive: true);
        await project.writeAsString(_fixture());
      });
      tearDown(() => root.delete(recursive: true));

      test("creates a dynamic phase and only changes Runner helper settings",
          () async {
        final before = await parse();
        await setup();
        final after = await parse();
        final target = after["RUNNER"] as Map;
        final phases = target["buildPhases"] as List;
        expect(phases.take(2), ["SOURCES", "FLUTTER"]);
        expect(phases.last, "CUSTOM");
        final helper = after[phases[2]] as Map;
        expect(helper["shellScript"], managedHelperScript);
        expect(
          helper["inputPaths"],
          [r"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"],
        );
        expect(helper["alwaysOutOfDate"], "1");
        expect(helper["runOnlyForDeploymentPostprocessing"], "0");
        expect((after["CONFIG"] as Map)["buildSettings"], {
          "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
          "DEVELOPMENT_TEAM": "0098765432",
          "CUSTOM_SETTING[sdk=macosx*]": "2026-10-29",
        });
        for (final entry in before.entries
            .where((e) => !["RUNNER", "CONFIG"].contains(e.key))) {
          expect(after[entry.key], entry.value, reason: entry.key);
        }
        final text = await project.readAsString();
        expect(
          text,
          contains("/* Keep this unknown attribute and its formatting. */"),
        );
        expect(text, contains('futureAttribute = { value = "0098"; };'));
        expect(text, contains("SOURCES /* Sources */"));
        expect(text, contains("FLUTTER /* Flutter embed */"));
      });

      test("rerun is a byte-for-byte no-op with one helper phase", () async {
        await setup();
        final before = await project.readAsBytes();
        final modified = await project.lastModified();
        final edit = (await prepareHelperXcodeSetup(root))!;
        expect(edit.hasChanges, isFalse);
        await edit.apply();
        expect(await project.readAsBytes(), before);
        expect(await project.lastModified(), modified);
      });

      test(
          "repairs custom helper order and inputs without replacing its exports",
          () async {
        await project.writeAsString(_fixture(helper: true));
        final before = await parse();
        await setup();
        final after = await parse();
        final helper = after["HELPER"] as Map;
        expect(helper["shellScript"], (before["HELPER"] as Map)["shellScript"]);
        expect(helper["outputPaths"], (before["HELPER"] as Map)["outputPaths"]);
        expect(helper["inputPaths"], [
          "policy, with (spaces).json",
          r"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)",
        ]);
        expect(
          (after["RUNNER"] as Map)["buildPhases"],
          ["SOURCES", "FLUTTER", "HELPER", "CUSTOM"],
        );
        final snapshot = await project.readAsString();
        await setup();
        expect(await project.readAsString(), snapshot);
      });

      test("fills a named empty phase instead of adding a second one",
          () async {
        await project.writeAsString(_fixture(helper: true, script: ""));
        await setup();
        final objects = await parse();
        expect((objects["HELPER"] as Map)["shellScript"], managedHelperScript);
        expect((objects["RUNNER"] as Map)["buildPhases"], hasLength(4));
      });

      for (final entry in {
        "unrecognized custom helper":
            _fixture(helper: true, script: "echo custom unrelated action"),
        "multiple helpers": _fixture(helper: true)
            .replaceFirst("CUSTOM,", "CUSTOM, HELPER2,")
            .replaceFirst(
              "objects = {",
              "objects = { HELPER2 = { isa = PBXShellScriptBuildPhase; shellScript = \"embed_install_helper.sh\"; };",
            ),
        "missing Flutter embed":
            _fixture().replaceAll("macos_assemble.sh embed", "custom_build.sh"),
        "multiple Flutter embeds": _fixture()
            .replaceFirst("CUSTOM,", "CUSTOM, FLUTTER2,")
            .replaceFirst(
              "objects = {",
              "objects = { FLUTTER2 = { isa = PBXShellScriptBuildPhase; shellScript = \"macos_assemble.sh embed\"; };",
            ),
        "shared configuration": _fixture().replaceFirst(
          "buildConfigurationList = TEST_CONFIG_LIST",
          "buildConfigurationList = CONFIG_LIST",
        ),
        "malformed project": "{ objects = {",
        "duplicate field": _fixture()
            .replaceFirst("name = Runner;", "name = Runner; name = Runner;"),
      }.entries) {
        test("rejects ${entry.key} without writing", () async {
          await project.writeAsString(entry.value);
          final before = await project.readAsBytes();
          await expectLater(
            prepareHelperXcodeSetup(root),
            throwsA(isA<FormatException>()),
          );
          expect(await project.readAsBytes(), before);
        });
      }

      test("rejects project symlinks and linked parent directories", () async {
        final original =
            await project.rename(path.join(root.path, "original.pbxproj"));
        await Link(project.path).create(original.path);
        await expectLater(
          prepareHelperXcodeSetup(root),
          throwsA(isA<FileSystemException>()),
        );
        await Link(project.path).delete();
        await project.parent.delete();
        await Link(project.parent.path).create(root.path);
        await expectLater(
          prepareHelperXcodeSetup(root),
          throwsA(isA<FileSystemException>()),
        );
        expect(await original.readAsString(), _fixture());
      });

      test("rejects changes made after preparation", () async {
        final edit = (await prepareHelperXcodeSetup(root))!;
        final changed = "${await project.readAsString()}\n// concurrent edit\n";
        await project.writeAsString(changed);
        await expectLater(edit.apply(), throwsA(isA<StateError>()));
        expect(await project.readAsString(), changed);
      });
    },
    skip: !Platform.isMacOS,
  );
}

String _fixture({bool helper = false, String? script}) => '''// !\$*UTF8*\$!
{
  archiveVersion = 1;
  objects = {
    RUNNER = {
      isa = PBXNativeTarget;
      name = Runner;
      productType = "com.apple.product-type.application";
      buildConfigurationList = CONFIG_LIST;
      buildPhases = (
        SOURCES /* Sources */,
        ${helper ? 'HELPER /* Existing helper */,' : ''}
        FLUTTER /* Flutter embed */,
        CUSTOM,
      );
      /* Keep this unknown attribute and its formatting. */
      futureAttribute = { value = "0098"; };
    };
    CONFIG_LIST = { isa = XCConfigurationList; buildConfigurations = (CONFIG,); };
    CONFIG = {
      isa = XCBuildConfiguration;
      buildSettings = {
        ENABLE_USER_SCRIPT_SANDBOXING = YES;
        DEVELOPMENT_TEAM = "0098765432";
        "CUSTOM_SETTING[sdk=macosx*]" = "2026-10-29";
      };
    };
    TEST_TARGET = { isa = PBXNativeTarget; name = RunnerTests; buildConfigurationList = TEST_CONFIG_LIST; buildPhases = (); };
    TEST_CONFIG_LIST = { isa = XCConfigurationList; buildConfigurations = (TEST_CONFIG,); };
    TEST_CONFIG = { isa = XCBuildConfiguration; buildSettings = { ENABLE_USER_SCRIPT_SANDBOXING = YES; }; };
    SOURCES = { isa = PBXSourcesBuildPhase; files = (); };
    FLUTTER = { isa = PBXShellScriptBuildPhase; shellScript = ${jsonEncode(r'"$FLUTTER_ROOT"/packages/flutter_tools/bin/macos_assemble.sh embed')}; };
    CUSTOM = { isa = PBXShellScriptBuildPhase; shellScript = ${jsonEncode('echo "a,b; (c) {d} \\"quoted\\""\n# /* not a comment */\necho \'x,y\'\n')}; };
    ${helper ? '''HELPER = {
      isa = PBXShellScriptBuildPhase;
      name = "Embed Desktop Updater Install Helper";
      shellScript = ${jsonEncode(script ?? 'export CUSTOM_POLICY="a,b\\\\c"\n"\$DESKTOP_UPDATER_PACKAGE_ROOT/macos/install_helper/embed_install_helper.sh"\n')};
      inputPaths = ("policy, with (spaces).json",);
      outputPaths = ("helper binary",);
    };''' : ''}
  };
}
''';
