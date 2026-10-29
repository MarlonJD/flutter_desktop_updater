import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/release_cli/macos/macos_release_trust.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("preflight inventories bundle topology without signing", () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = await _createTopologyFixture(root);
    final commands = <List<String>>[];

    final inventory = await MacOSReleaseTrust(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments]);
        return ProcessResult(0, 0, "", "");
      },
    ).preflight(
      app: app,
      expectedApplicationIdentifier: "com.example.topology",
    );

    expect(
      inventory.targets.map((target) => target.kind),
      containsAll([
        MacOSCodeTargetKind.application,
        MacOSCodeTargetKind.framework,
        MacOSCodeTargetKind.bundle,
        MacOSCodeTargetKind.appExtension,
        MacOSCodeTargetKind.xpc,
        MacOSCodeTargetKind.systemExtension,
        MacOSCodeTargetKind.executable,
      ]),
    );
    expect(
      inventory.targets.any(
        (target) => target.path
            .replaceAll("\\", "/")
            .endsWith("Contents/Helpers/extensionless-helper"),
      ),
      isTrue,
    );
    expect(
      commands.where((command) => command.first == "/usr/bin/codesign"),
      isEmpty,
    );
  });

  test(
    "unsigned privacy resources do not become code signing targets",
    () async {
      final root = await Directory.systemTemp.createTemp("macos_trust_");
      addTearDown(() => root.delete(recursive: true));
      final app = await _createSimpleApp(root, name: "Privacy.app");
      final framework = await _createVersionedFramework(app);
      final bundle = Directory(
        path.join(
          framework.path,
          "Versions",
          "A",
          "Resources",
          "OrderedSet_privacy.bundle",
        ),
      );
      await bundle.create(recursive: true);
      await File(path.join(bundle.path, "Info.plist")).writeAsString(
        _plist({"CFBundleIdentifier": "org.cocoapods.OrderedSet-privacy"}),
      );
      final privacy = File(path.join(bundle.path, "PrivacyInfo.xcprivacy"));
      final privacyBytes = utf8.encode(_plist({"NSPrivacyTracking": "false"}));
      await privacy.writeAsBytes(privacyBytes);
      final privacyMode = (await privacy.stat()).mode;
      final bundlePath = await bundle.resolveSymbolicLinks();
      final appPath = await app.resolveSymbolicLinks();
      final frameworkPath = await framework.resolveSymbolicLinks();
      final commands = <List<String>>[];
      String? entitlementFile;
      const appEntitlements = """<?xml version="1.0"?>
<plist version="1.0"><dict>
<key>com.apple.security.files.user-selected.read-write</key><true/>
</dict></plist>""";
      final trust = MacOSReleaseTrust(
        readFileIdentity: (_) async => null,
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments]);
          if (executable == "/usr/bin/codesign") {
            if (arguments.last == bundlePath) {
              return ProcessResult(
                0,
                1,
                "",
                "code object is not signed at all",
              );
            }
            if (arguments.first == "-d" &&
                arguments.contains("--entitlements")) {
              return ProcessResult(
                0,
                0,
                arguments.last == appPath ? appEntitlements : "",
                "",
              );
            }
            if (arguments.first == "-dvvv") {
              final identifier = arguments.last == frameworkPath
                  ? "com.example.framework"
                  : "com.example.audited";
              return ProcessResult(
                0,
                0,
                _codeDetails.replaceAll("com.example.audited", identifier),
                "",
              );
            }
            if (arguments.first == "--force") {
              if (arguments.last == appPath) {
                entitlementFile =
                    arguments[arguments.indexOf("--entitlements") + 1];
                expect(
                  await File(entitlementFile!).readAsString(),
                  appEntitlements,
                );
              } else {
                expect(arguments, isNot(contains("--entitlements")));
              }
            }
          }
          return ProcessResult(0, 0, "", "");
        },
      );
      final inventory = await trust.preflight(app: app);

      await trust.signAndVerify(
        inventory: inventory,
        identity: "test identity",
      );
      await trust.verifyApp(inventory: inventory);

      expect(inventory.targets.map((target) => target.path), [
        frameworkPath,
        appPath,
      ]);
      expect(commands.where((command) => command.last == bundlePath), isEmpty);
      expect(
        commands
            .where((command) => command.contains("--force"))
            .map((command) => command.last),
        [frameworkPath, appPath],
      );
      expect(
        commands.where((command) => command.contains("--deep")),
        hasLength(2),
      );
      expect(await privacy.readAsBytes(), privacyBytes);
      expect((await privacy.stat()).mode, privacyMode);
      expect(entitlementFile, isNotNull);
      expect(await File(entitlementFile!).exists(), isFalse);
    },
    skip: Platform.isWindows ? "Requires framework symlinks" : false,
  );

  for (final infoPath in [
    "Info.plist",
    "Resources/Info.plist",
    "Contents/Info.plist",
  ]) {
    test(
      "resource bundle with $infoPath is excluded from code inventory",
      () async {
        final root = await Directory.systemTemp.createTemp("macos_trust_");
        addTearDown(() => root.delete(recursive: true));
        final app = await _createSimpleApp(root, name: "Resources.app");
        final bundle = Directory(
          path.join(app.path, "Contents", "Resources", "Data.bundle"),
        );
        final info = File(path.join(bundle.path, infoPath));
        await info.parent.create(recursive: true);
        await info.writeAsString(
          _plist({"CFBundleIdentifier": "com.example.data"}),
        );
        final inventory = await MacOSReleaseTrust(
          readFileIdentity: (_) async => null,
        ).preflight(app: app);
        expect(inventory.targets.map((target) => target.kind), [
          MacOSCodeTargetKind.application,
        ]);
      },
    );
  }

  for (final flat in [false, true]) {
    test("executable bundle remains checked (flat: $flat)", () async {
      final root = await Directory.systemTemp.createTemp("macos_trust_");
      addTearDown(() => root.delete(recursive: true));
      final app = await _createSimpleApp(root, name: "Code.app");
      final bundle =
          Directory(path.join(app.path, "Contents", "PlugIns", "Code.bundle"));
      final info = File(
        path.join(bundle.path, flat ? "Info.plist" : "Contents/Info.plist"),
      );
      final code =
          File(path.join(bundle.path, flat ? "Code" : "Contents/MacOS/Code"));
      await code.parent.create(recursive: true);
      await info.writeAsString(
        _plist({
          "CFBundleIdentifier": "com.example.code",
          "CFBundleExecutable": "Code",
        }),
      );
      await code.writeAsBytes(_machO);
      final bundlePath = await bundle.resolveSymbolicLinks();
      final commands = <List<String>>[];
      final trust = MacOSReleaseTrust(
        readFileIdentity: (_) async => null,
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments]);
          return ProcessResult(
            0,
            0,
            "",
            arguments.last == bundlePath ? _forbiddenEntitlements : "",
          );
        },
      );
      final inventory = await trust.preflight(app: app);
      expect(
        inventory.targets.map((target) => target.kind),
        [MacOSCodeTargetKind.bundle, MacOSCodeTargetKind.application],
      );
      expect(inventory.targets.first.path, bundlePath);
      await expectLater(
        trust.signAndVerify(inventory: inventory, identity: "test identity"),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            "message",
            contains("get-task-allow"),
          ),
        ),
      );
      expect(commands.where((command) => command.contains("--force")), isEmpty);
    });
  }

  for (final declaration in [
    "<string>Missing</string>",
    "<string></string>",
    "<integer>42</integer>",
  ]) {
    test(
      "bundle with invalid executable declaration $declaration fails preflight",
      () async {
        final root = await Directory.systemTemp.createTemp("macos_trust_");
        addTearDown(() => root.delete(recursive: true));
        final app = await _createSimpleApp(root, name: "Invalid.app");
        final info = File(
          path.join(
            app.path,
            "Contents",
            "PlugIns",
            "Invalid.bundle",
            "Contents",
            "Info.plist",
          ),
        );
        await info.parent.create(recursive: true);
        await info.writeAsString(
          _plistWithEntries([
            "<key>CFBundleIdentifier</key><string>com.example.invalid</string>",
            "<key>CFBundleExecutable</key>$declaration",
          ]),
        );
        await expectLater(
          MacOSReleaseTrust(readFileIdentity: (_) async => null)
              .preflight(app: app),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              "message",
              "macOS code bundle has no valid CFBundleExecutable.",
            ),
          ),
        );
      },
    );
  }

  test(
    "native code in a resource bundle remains an entitlement-checked target",
    () async {
      final root = await Directory.systemTemp.createTemp("macos_trust_");
      addTearDown(() => root.delete(recursive: true));
      final app = await _createSimpleApp(root, name: "Native.app");
      const relative = "Contents/Frameworks/Assets.bundle";
      await _createBundle(
        app,
        relative,
        kind: MacOSCodeTargetKind.bundle,
        identifier: "com.example.assets",
      );
      final native = File(
        path.join(app.path, relative, "Resources", "native.css"),
      );
      await native.writeAsBytes(_machO);
      final nativePath = await native.resolveSymbolicLinks();
      final commands = <List<String>>[];
      final trust = MacOSReleaseTrust(
        readFileIdentity: (_) async => null,
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments]);
          if (executable == "/usr/bin/codesign" &&
              arguments.contains("--entitlements") &&
              arguments.last == nativePath) {
            return ProcessResult(0, 1, "", "code object is not signed at all");
          }
          return ProcessResult(0, 0, "", "");
        },
      );
      final inventory = await trust.preflight(app: app);
      expect(inventory.targets.map((target) => target.kind), [
        MacOSCodeTargetKind.executable,
        MacOSCodeTargetKind.application,
      ]);
      await expectLater(
        trust.signAndVerify(inventory: inventory, identity: "test identity"),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            "message",
            "Unable to extract macOS entitlements: $nativePath",
          ),
        ),
      );
      await expectLater(
        trust.verifyApp(inventory: inventory),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            "message",
            "Unable to extract macOS entitlements: $nativePath",
          ),
        ),
      );
      expect(commands.where((command) => command.contains("--force")), isEmpty);
    },
  );

  test(
    "preflight preserves executable data in versioned framework resources",
    () async {
      final root = await Directory.systemTemp.createTemp("macos_trust_");
      addTearDown(() => root.delete(recursive: true));
      final app = await _createSimpleApp(root, name: "Resources.app");
      final framework = await _createVersionedFramework(app);
      final assets = Directory(
        path.joinAll([
          framework.path,
          "Versions",
          "A",
          "Resources",
          "flutter_assets",
          "packages",
          "flutter_inappwebview",
          "assets",
          "t_rex_runner",
        ]),
      );
      final files = <File>[];
      final modes = <int>[];
      const contents = {
        "t-rex.css": "#main-frame-error { display: block; }\n",
        "t-rex.html": "<div class=\"runner-container\"></div>\n",
      };
      for (final entry in contents.entries) {
        final file = await _writeExecutable(assets, entry.key, entry.value);
        files.add(file);
        modes.add((await file.stat()).mode);
      }
      final commands = <String>[];
      final inventory = await MacOSReleaseTrust(
        runProcess: (executable, arguments) async {
          commands.add(executable);
          return ProcessResult(0, 0, "", "");
        },
      ).preflight(app: app);

      expect(
        inventory.targets.map((target) => target.kind),
        unorderedEquals([
          MacOSCodeTargetKind.application,
          MacOSCodeTargetKind.framework,
        ]),
      );
      for (var index = 0; index < files.length; index++) {
        expect(
          await files[index].readAsString(),
          contents.values.elementAt(index),
        );
        expect((await files[index].stat()).mode, modes[index]);
      }
      expect(commands, isNot(contains("/usr/bin/codesign")));
    },
    skip: Platform.isWindows ? "Requires POSIX modes and symlinks" : false,
  );

  for (final fixture in [
    (
      "Contents/Frameworks/Flat.framework",
      MacOSCodeTargetKind.framework,
      "Resources"
    ),
    ("Contents/PlugIns/Assets.bundle", MacOSCodeTargetKind.bundle, "Resources"),
    (
      "Contents/PlugIns/Content.bundle",
      MacOSCodeTargetKind.bundle,
      "Contents/Resources"
    ),
    (
      "Contents/PlugIns/Test.appex",
      MacOSCodeTargetKind.appExtension,
      "Contents/Resources"
    ),
    (
      "Contents/XPCServices/Test.xpc",
      MacOSCodeTargetKind.xpc,
      "Contents/Resources"
    ),
    (
      "Contents/Library/SystemExtensions/Test.systemextension",
      MacOSCodeTargetKind.systemExtension,
      "Contents/Resources"
    ),
    (
      "Contents/Library/LoginItems/Login.app",
      MacOSCodeTargetKind.application,
      "Contents/Resources"
    ),
  ]) {
    test(
      "preflight accepts executable data in ${fixture.$1}/${fixture.$3}",
      () async {
        final root = await Directory.systemTemp.createTemp("macos_trust_");
        addTearDown(() => root.delete(recursive: true));
        final app = await _createSimpleApp(root, name: "Resources.app");
        await _createBundle(
          app,
          fixture.$1,
          kind: fixture.$2,
          identifier: "com.example.nested",
          executable: "Nested",
        );
        await _writeExecutable(
          app,
          "${fixture.$1}/${fixture.$3}/asset",
          "data",
        );

        final inventory = await MacOSReleaseTrust(
          readFileIdentity: (_) async => null,
        ).preflight(app: app);

        expect(inventory.targets, hasLength(2));
        expect(
          inventory.targets.map((target) => target.kind),
          unorderedEquals([MacOSCodeTargetKind.application, fixture.$2]),
        );
      },
      skip: Platform.isWindows ? "Requires POSIX execute bits" : false,
    );
  }

  test(
    "preflight inventories Mach-O resources regardless of extension or mode",
    () async {
      final root = await Directory.systemTemp.createTemp("macos_trust_");
      addTearDown(() => root.delete(recursive: true));
      final app = await _createSimpleApp(root, name: "Native.app");
      final framework = await _createVersionedFramework(app);
      final native = File(
        path.join(framework.path, "Versions", "A", "Resources", "native.css"),
      );
      await native.writeAsBytes(_machO);
      expect((await Process.run("chmod", ["644", native.path])).exitCode, 0);

      final inventory = await MacOSReleaseTrust(
        readFileIdentity: (_) async => null,
      ).preflight(app: app);

      expect(inventory.targets, hasLength(3));
      final nativePath = await native.resolveSymbolicLinks();
      final target = inventory.targets.singleWhere(
        (target) => target.path == nativePath,
      );
      expect(target.kind, MacOSCodeTargetKind.executable);
    },
    skip: Platform.isWindows ? "Requires POSIX modes and symlinks" : false,
  );

  test("preflight still rejects Mach-O in outer application resources",
      () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = await _createSimpleApp(root, name: "Native.app");
    final native =
        File(path.join(app.path, "Contents", "Resources", "native.css"));
    await native.parent.create(recursive: true);
    await native.writeAsBytes(_machO);

    await expectLater(
      MacOSReleaseTrust(readFileIdentity: (_) async => null)
          .preflight(app: app),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          "message",
          "Unexpected executable code outside a standard macOS code location.",
        ),
      ),
    );
  });

  for (final relative in [
    "Contents/MacOS/t-rex.css",
    "Contents/Helpers/Resources/t-rex.css",
    "Contents/Frameworks/Resources/t-rex.css",
    "Contents/Frameworks/App.framework/t-rex.css",
    "Contents/Frameworks/App.framework/Versions/A/t-rex.css",
    "Contents/Frameworks/App.framework/Versions/A/Resources/Nested.app/Contents/MacOS/t-rex.css",
    "Contents/Frameworks/App.framework/Versions/A/Resources/Data.bundle/Contents/MacOS/t-rex.css",
  ]) {
    test(
      "preflight rejects executable non-Mach-O code at $relative",
      () async {
        final root = await Directory.systemTemp.createTemp("macos_trust_");
        addTearDown(() => root.delete(recursive: true));
        final app = await _createSimpleApp(root, name: "Code.app");
        final framework = await _createVersionedFramework(app);
        await _createBundle(
          framework,
          "Versions/A/Resources/Nested.app",
          kind: MacOSCodeTargetKind.application,
          identifier: "com.example.nested",
          executable: "Nested",
        );
        await _createBundle(
          framework,
          "Versions/A/Resources/Data.bundle",
          kind: MacOSCodeTargetKind.bundle,
          identifier: "com.example.data",
        );
        final file = await _writeExecutable(app, relative, "not native code");

        await expectLater(
          MacOSReleaseTrust(readFileIdentity: (_) async => null)
              .preflight(app: app),
          throwsA(
            isA<FileSystemException>()
                .having(
                  (error) => error.message,
                  "message",
                  "macOS application contains executable bytes that are not Mach-O.",
                )
                .having(
                  (error) => error.path,
                  "path",
                  await file.resolveSymbolicLinks(),
                ),
          ),
        );
      },
      skip: Platform.isWindows ? "Requires POSIX modes and symlinks" : false,
    );
  }

  test("preflight rejects malformed applications before mutation", () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = Directory(path.join(root.path, "Broken.app"));
    await File(path.join(app.path, "Contents", "Info.plist"))
        .create(recursive: true);
    await File(path.join(app.path, "Contents", "Info.plist"))
        .writeAsString(_plist({"CFBundleIdentifier": "com.example.broken"}));
    final commands = <List<String>>[];

    await expectLater(
      MacOSReleaseTrust(
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments]);
          return ProcessResult(0, 0, "", "");
        },
      ).preflight(app: app),
      throwsA(isA<Object>()),
    );
    expect(
      commands.where((command) => command.first == "/usr/bin/codesign"),
      isEmpty,
    );
  });

  test("preflight rejects symlink escapes", () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = await _createSimpleApp(root, name: "Escape.app");
    final outside = Directory(path.join(root.path, "outside"));
    await outside.create();
    final link = Link(path.join(app.path, "Contents", "Frameworks", "Escape"));
    await link.parent.create(recursive: true);
    await link.create(outside.path);

    await expectLater(
      MacOSReleaseTrust().preflight(app: app),
      throwsA(isA<Object>()),
    );
  });

  test("preflight deduplicates targets by stable file identity", () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = await _createSimpleApp(root, name: "Identity.app");
    final first = File(
      path.join(app.path, "Contents", "Helpers", "first-helper"),
    );
    final second = File(
      path.join(app.path, "Contents", "Helpers", "second-helper"),
    );
    await first.parent.create(recursive: true);
    await first.writeAsBytes(_machO);
    await second.writeAsBytes(_machO);

    final inventory = await MacOSReleaseTrust(
      readFileIdentity: (value) async =>
          value.endsWith("first-helper") || value.endsWith("second-helper")
              ? "1:42"
              : null,
      runProcess: (executable, arguments) async => ProcessResult(0, 0, "", ""),
    ).preflight(app: app);

    expect(
      inventory.targets.where((target) => target.path.endsWith("helper")),
      hasLength(1),
    );
  });

  test("get-task-allow is rejected by key presence before codesign", () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = await _createSimpleApp(root, name: "Entitlements.app");
    final commands = <List<String>>[];
    final trust = MacOSReleaseTrust(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments]);
        if (executable == "/usr/bin/codesign" &&
            arguments.contains("--entitlements")) {
          return ProcessResult(0, 0, "", _forbiddenEntitlements);
        }
        return ProcessResult(0, 0, "", _codeDetails);
      },
    );
    final inventory = await trust.preflight(app: app);

    await expectLater(
      trust.signAndVerify(inventory: inventory, identity: "-"),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains("get-task-allow"),
        ),
      ),
    );
    expect(
      commands.where(
        (command) =>
            command.first == "/usr/bin/codesign" && command.contains("--force"),
      ),
      isEmpty,
    );
  });

  test("sealed helper policy binds helper and application requirements",
      () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = await _createSimpleApp(
      root,
      name: "Policy.app",
      identifier: "com.example.desktopUpdaterSmoke",
    );
    final policy = <String, Object?>{
      "allowedApplicationSigner": {
        "kind": "appleDesignatedRequirement",
        "value":
            "identifier com.example.desktopUpdaterSmoke and anchor apple generic",
      },
      "allowedHelperSigner": {
        "kind": "appleDesignatedRequirement",
        "value":
            "identifier com.example.desktopUpdaterSmoke.helper and anchor apple generic",
      },
      "allowedInstallRoots": [
        Platform.isWindows ? r"C:\Applications" : "/Applications",
      ],
      "allowedStrategies": [
        {"provider": "platformDirectory", "strategy": "directoryReplace"},
        {"provider": "macosInstaller", "strategy": "verifiedInstallerHandoff"},
      ],
      "allowedTargetClasses": ["applicationBundle", "protectedApplication"],
      "applicationPackageId": "com.example.desktopUpdaterSmoke",
      "helperServiceId": "com.example.desktopUpdaterSmoke.helper",
      "minimumHelperProtocolVersion": 1,
      "policyId": "com.example.desktopUpdaterSmoke.privileged",
      "policyVersion": 3,
      "releaseRootPublicKeys": [
        {
          "algorithm": "ed25519",
          "keyId": "stable-2026",
          "publicKeyBase64": base64Encode(List<int>.filled(32, 1)),
        },
      ],
    };
    final policyBytes = utf8.encode(jsonEncode(_sortedValue(policy)));
    final policyDigest = crypto.sha256.convert(policyBytes).toString();
    await File(path.join(app.path, "Contents", "Info.plist")).writeAsString(
      _plistWithEntries([
        "<key>CFBundleIdentifier</key><string>com.example.desktopUpdaterSmoke</string>",
        "<key>CFBundleExecutable</key><string>Policy</string>",
        "<key>CFBundleShortVersionString</key><string>1.0.0</string>",
        "<key>CFBundleVersion</key><string>1</string>",
        "<key>DesktopUpdaterInstallPolicyID</key><string>com.example.desktopUpdaterSmoke.privileged</string>",
        "<key>DesktopUpdaterInstallHelperServiceID</key><string>com.example.desktopUpdaterSmoke.helper</string>",
        "<key>DesktopUpdaterInstallHelperRequirement</key><string>identifier com.example.desktopUpdaterSmoke.helper and anchor apple generic</string>",
        "<key>DesktopUpdaterInstallHelperLaunchDaemonPlistName</key><string>com.example.desktopUpdaterSmoke.helper.plist</string>",
      ]),
    );
    final helper = File(
      path.join(app.path, "Contents", "Helpers", "DesktopUpdaterInstallHelper"),
    );
    await helper.parent.create(recursive: true);
    await helper.writeAsBytes(_machO);
    if (!Platform.isWindows) {
      expect((await Process.run("chmod", ["755", helper.path])).exitCode, 0);
    }
    final helperInfo = _plistWithEntries([
      "<key>CFBundleIdentifier</key><string>com.example.desktopUpdaterSmoke.helper</string>",
      "<key>DesktopUpdaterSealedPolicy</key><data>${base64Encode(policyBytes)}</data>",
      "<key>DesktopUpdaterSealedPolicySHA256</key><string>$policyDigest</string>",
    ]);
    final daemon = File(
      path.join(
        app.path,
        "Contents",
        "Library",
        "LaunchDaemons",
        "com.example.desktopUpdaterSmoke.helper.plist",
      ),
    );
    await daemon.parent.create(recursive: true);
    await daemon.writeAsString(
      _plistWithEntries([
        "<key>Label</key><string>com.example.desktopUpdaterSmoke.helper</string>",
        "<key>MachServices</key><dict><key>com.example.desktopUpdaterSmoke.helper</key><true/></dict>",
        "<key>BundleProgram</key><string>Contents/Helpers/DesktopUpdaterInstallHelper</string>",
      ]),
    );

    final trust = MacOSReleaseTrust(
      runProcess: (executable, arguments) async {
        if (executable == "/usr/bin/lipo") {
          return ProcessResult(0, 0, "arm64 x86_64", "");
        }
        if (executable == "/usr/bin/otool") {
          return ProcessResult(0, 0, helperInfo, "");
        }
        return ProcessResult(0, 0, "", "");
      },
    );
    final inventory = await trust.preflight(
      app: app,
      expectedApplicationIdentifier: "com.example.desktopUpdaterSmoke",
    );

    expect(
      inventory.sealedPolicy?.policyId,
      "com.example.desktopUpdaterSmoke.privileged",
    );
    expect(
      inventory.sealedPolicy?.helperRequirement,
      "identifier com.example.desktopUpdaterSmoke.helper and anchor apple generic",
    );
    expect(inventory.targets, contains(isA<MacOSCodeTarget>()));
    final hostInfo = File(path.join(app.path, "Contents", "Info.plist"));
    final originalHost = await hostInfo.readAsString();
    for (final field in [
      "DesktopUpdaterInstallPolicyID",
      "DesktopUpdaterInstallHelperServiceID",
      "DesktopUpdaterInstallHelperRequirement",
      "DesktopUpdaterInstallHelperLaunchDaemonPlistName",
    ]) {
      final entry = RegExp("<key>$field</key><string>[^<]*</string>");
      for (final missing in [true, false]) {
        await hostInfo.writeAsString(originalHost.replaceFirst(
            entry,
            missing
                ? ""
                : "<key>$field</key><string>com.example.wrong</string>"));
        await expectLater(
          trust.preflight(app: app),
          throwsA(isA<StateError>()
              .having(
                  (error) => error.message,
                  "message",
                  contains(
                      "Packaged helper policy does not match bundle metadata"))
              .having((error) => error.message, "field",
                  contains("app Info.plist.$field"))
              .having((error) => error.message, "actual",
                  contains(missing ? "<missing>" : '"com.example.wrong"'))),
        );
      }
    }
    await hostInfo.writeAsString(originalHost.replaceFirst(
      "<key>CFBundleVersion</key><string>1</string>",
      "<key>CFBundleVersion</key><string>2</string>",
    ));
    final nextBuild = await trust.preflight(app: app);
    expect(nextBuild.sealedPolicy?.policyId, inventory.sealedPolicy?.policyId);
    await hostInfo.writeAsString(originalHost);
    if (!Platform.isWindows) {
      final trust = MacOSReleaseTrust();
      await trust.verifyInstallReadiness(inventory: inventory);
      final info = File(path.join(app.path, "Contents", "Info.plist"));
      final original = await info.readAsString();
      for (final invalidBuild in ["1.0.0", "-1", "", "9223372036854775808"]) {
        await info.writeAsString(original.replaceFirst(
          "<key>CFBundleVersion</key><string>1</string>",
          "<key>CFBundleVersion</key><string>$invalidBuild</string>",
        ));
        await expectLater(
          trust.verifyInstallReadiness(inventory: inventory),
          throwsA(isA<StateError>().having((error) => error.message, "message",
              contains("integer CFBundleVersion"))),
        );
      }
      await info.writeAsString(original);
      expect((await Process.run("chmod", ["644", helper.path])).exitCode, 0);
      await expectLater(
        trust.verifyInstallReadiness(inventory: inventory),
        throwsA(isA<StateError>().having(
            (error) => error.message, "message", contains("not executable"))),
      );
    }
  });

  test("typed notarization parsing requires accepted status and an id", () {
    expect(
      MacOSReleaseTrust.parseNotarySubmission(
        '{"id":"submission-1","status":"Accepted"}',
      ).status,
      "Accepted",
    );
    for (final response in [
      '{"id":"","status":"Accepted"}',
      '{"id":"submission-1","status":"In Progress"}',
      '{"status":"Accepted"}',
      "not-json",
    ]) {
      expect(
        () => MacOSReleaseTrust.parseNotarySubmission(response),
        throwsA(isA<Object>()),
      );
    }
  });

  test(
    "omits explicit keychain for default notary profile resolution",
    () async {
      final commands = <List<String>>[];
      final trust = MacOSReleaseTrust(
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments]);
          return ProcessResult(
            0,
            0,
            '{"id":"submission-1","status":"Accepted"}',
            "",
          );
        },
      );

      final submission = await trust.submit(
        archive: File("/tmp/Example-notary.zip"),
        profile: "general-notary",
      );

      expect(submission.status, "Accepted");
      expect(commands.single, [
        "/usr/bin/xcrun",
        "notarytool",
        "submit",
        "/tmp/Example-notary.zip",
        "--keychain-profile",
        "general-notary",
        "--wait",
        "--output-format",
        "json",
      ]);
    },
  );

  test(
    "final ZIP audit verifies the downloaded app after safe extraction",
    () async {
      final root = await Directory.systemTemp.createTemp("macos_trust_");
      addTearDown(() => root.delete(recursive: true));
      final app = await _createSimpleApp(root, name: "Audited.app");
      await _createBundle(
        app,
        "Contents/Resources/Assets.bundle",
        kind: MacOSCodeTargetKind.bundle,
        identifier: "com.example.assets",
      );
      final archive = Archive();
      await for (final entity in app.list(recursive: true)) {
        if (entity is File) {
          archive.addFile(
            ArchiveFile.bytes(
              path.relative(entity.path, from: app.parent.path),
              await entity.readAsBytes(),
            ),
          );
        }
      }
      final zip = File(path.join(root.path, "Audited.zip"));
      await zip.writeAsBytes(ZipEncoder().encode(archive));
      final commands = <List<String>>[];
      final trust = MacOSReleaseTrust(
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments]);
          if (executable == "/usr/bin/ditto" && arguments.first == "-x") {
            final destination = Directory(arguments.last);
            await _copyDirectory(
              app,
              Directory(
                path.join(
                  destination.path,
                  app.path.split(path.separator).last,
                ),
              ),
            );
          }
          if (executable == "/usr/bin/codesign" &&
              arguments.last.endsWith("Assets.bundle")) {
            return ProcessResult(0, 1, "", "code object is not signed at all");
          }
          if (executable == "/usr/bin/codesign" && arguments.first == "-dvvv") {
            return ProcessResult(0, 0, "", _codeDetails);
          }
          return ProcessResult(0, 0, "", "");
        },
      );

      await trust.auditFinalArtifact(
        artifact: zip,
        kind: "zip",
        appBundleName: "Audited.app",
        expectedApplicationIdentifier: "com.example.audited",
      );

      expect(
        commands.where(
          (command) =>
              command.first == "/usr/bin/codesign" &&
              command.last.endsWith("Assets.bundle"),
        ),
        isEmpty,
      );

      expect(
        commands.indexWhere(
          (command) =>
              command.first == "/usr/bin/codesign" &&
              command.contains("--entitlements"),
        ),
        greaterThan(
          commands.indexWhere((command) => command.first == "/usr/bin/ditto"),
        ),
      );
      expect(
        commands.any(
          (command) =>
              command.first == "/usr/bin/codesign" &&
              command.contains("--deep"),
        ),
        isTrue,
      );
    },
  );
}

const _machO = <int>[0xfe, 0xed, 0xfa, 0xce, 0, 0, 0, 0];
const _codeDetails = "Identifier=com.example.audited\n"
    "TeamIdentifier=TEAMID1234\n"
    "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1\n";
const _forbiddenEntitlements = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.get-task-allow</key><false/>
</dict></plist>
''';

Future<Directory> _createTopologyFixture(Directory root) async {
  final app = await _createSimpleApp(
    root,
    name: "Topology.app",
    identifier: "com.example.topology",
  );
  await _createBundle(
    app,
    "Contents/Frameworks/Versioned.framework",
    kind: MacOSCodeTargetKind.framework,
    identifier: "com.example.versioned",
    executable: "Versioned",
  );
  await _createBundle(
    app,
    "Contents/PlugIns/Code.bundle",
    kind: MacOSCodeTargetKind.bundle,
    identifier: "com.example.code",
    executable: "Code",
  );
  for (final relative in [
    "Contents/PlugIns/Test.appex",
    "Contents/XPCServices/Test.xpc",
    "Contents/Library/SystemExtensions/Test.systemextension",
    "Contents/Library/LoginItems/LoginItem.app",
  ]) {
    await _createBundle(
      app,
      relative,
      kind: relative.endsWith(".appex")
          ? MacOSCodeTargetKind.appExtension
          : relative.endsWith(".xpc")
              ? MacOSCodeTargetKind.xpc
              : relative.endsWith(".systemextension")
                  ? MacOSCodeTargetKind.systemExtension
                  : MacOSCodeTargetKind.application,
      identifier: "com.example.${path.basename(relative).split(".").first}",
      executable: "Nested",
    );
  }
  final helper = File(
    path.join(app.path, "Contents", "Helpers", "extensionless-helper"),
  );
  await helper.parent.create(recursive: true);
  await helper.writeAsBytes(_machO);
  return app;
}

Future<Directory> _createSimpleApp(
  Directory root, {
  required String name,
  String? identifier,
}) async {
  final app = Directory(path.join(root.path, name));
  final executable = name.substring(0, name.length - ".app".length);
  final main = File(path.join(app.path, "Contents", "MacOS", executable));
  await main.parent.create(recursive: true);
  await File(path.join(app.path, "Contents", "Info.plist")).writeAsString(
    _plist({
      "CFBundleIdentifier": identifier ?? "com.example.audited",
      "CFBundleExecutable": executable,
    }),
  );
  await main.writeAsBytes(_machO);
  return app;
}

Future<File> _writeExecutable(
  Directory root,
  String relative,
  String contents,
) async {
  final file = File(path.join(root.path, relative));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
  expect((await Process.run("chmod", ["755", file.path])).exitCode, 0);
  return file;
}

Future<Directory> _createVersionedFramework(Directory app) async {
  final framework =
      Directory(path.join(app.path, "Contents", "Frameworks", "App.framework"));
  final version = Directory(path.join(framework.path, "Versions", "A"));
  final resources = Directory(path.join(version.path, "Resources"));
  await resources.create(recursive: true);
  await File(path.join(resources.path, "Info.plist")).writeAsString(
    _plist({
      "CFBundleIdentifier": "com.example.framework",
      "CFBundleExecutable": "App",
    }),
  );
  await File(path.join(version.path, "App")).writeAsBytes(_machO);
  await Link(path.join(framework.path, "Versions", "Current")).create("A");
  await Link(path.join(framework.path, "Resources"))
      .create("Versions/Current/Resources");
  await Link(path.join(framework.path, "App")).create("Versions/Current/App");
  return framework;
}

Future<void> _createBundle(
  Directory app,
  String relative, {
  required MacOSCodeTargetKind kind,
  required String identifier,
  String? executable,
}) async {
  final bundle = Directory(path.join(app.path, relative));
  final name = executable ?? "Resource";
  final info = kind == MacOSCodeTargetKind.framework ||
          kind == MacOSCodeTargetKind.bundle
      ? File(path.join(bundle.path, "Resources", "Info.plist"))
      : File(path.join(bundle.path, "Contents", "Info.plist"));
  final main = kind == MacOSCodeTargetKind.framework
      ? File(path.join(bundle.path, name))
      : File(path.join(bundle.path, "Contents", "MacOS", name));
  await info.parent.create(recursive: true);
  await main.parent.create(recursive: true);
  await info.writeAsString(
    _plist({
      "CFBundleIdentifier": identifier,
      if (executable != null) "CFBundleExecutable": name,
    }),
  );
  if (executable != null) await main.writeAsBytes(_machO);
}

String _plist(Map<String, String> values) {
  final entries = values.entries
      .map((entry) => "<key>${entry.key}</key><string>${entry.value}</string>")
      .join();
  return '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>$entries</dict></plist>';
}

String _plistWithEntries(List<String> entries) {
  return '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>${entries.join()}</dict></plist>';
}

Object? _sortedValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _sortedValue(value[key]),
    };
  }
  if (value is List) return value.map(_sortedValue).toList(growable: false);
  return value;
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true)) {
    final relative = path.relative(entity.path, from: source.path);
    final target = path.join(destination.path, relative);
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await File(target).parent.create(recursive: true);
      await File(target).writeAsBytes(await entity.readAsBytes());
    }
  }
}
