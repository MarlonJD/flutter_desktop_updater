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
        (target) =>
            target.path.endsWith("Contents/Helpers/extensionless-helper"),
      ),
      isTrue,
    );
    expect(commands.where((command) => command.first == "/usr/bin/codesign"),
        isEmpty);
  });

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
    expect(commands.where((command) => command.first == "/usr/bin/codesign"),
        isEmpty);
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
      inventory.targets.where(
        (target) => target.path.endsWith("helper"),
      ),
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
      trust.signAndVerify(
        inventory: inventory,
        identity: "-",
      ),
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
      identifier: "com.example.app",
    );
    final policy = <String, Object?>{
      "allowedApplicationSigner": {
        "kind": "appleDesignatedRequirement",
        "value": "identifier com.example.app and anchor apple generic",
      },
      "allowedHelperSigner": {
        "kind": "appleDesignatedRequirement",
        "value":
            "identifier com.example.desktop-updater.helper and anchor apple generic",
      },
      "allowedInstallRoots": ["/Applications"],
      "allowedStrategies": [
        {"provider": "platformDirectory", "strategy": "directoryReplace"},
        {"provider": "macosInstaller", "strategy": "verifiedInstallerHandoff"},
      ],
      "allowedTargetClasses": ["applicationBundle", "protectedApplication"],
      "applicationPackageId": "com.example.app",
      "helperServiceId": "com.example.desktop-updater.helper",
      "minimumHelperProtocolVersion": 1,
      "policyId": "com.example.desktop-updater.privileged",
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
        "<key>CFBundleIdentifier</key><string>com.example.app</string>",
        "<key>CFBundleExecutable</key><string>Policy</string>",
        "<key>DesktopUpdaterInstallPolicyID</key><string>com.example.desktop-updater.privileged</string>",
        "<key>DesktopUpdaterInstallHelperServiceID</key><string>com.example.desktop-updater.helper</string>",
        "<key>DesktopUpdaterInstallHelperRequirement</key><string>identifier com.example.desktop-updater.helper and anchor apple generic</string>",
        "<key>DesktopUpdaterInstallHelperLaunchDaemonPlistName</key><string>com.example.desktop-updater.helper.plist</string>",
      ]),
    );
    final helper = File(
      path.join(app.path, "Contents", "Helpers", "DesktopUpdaterInstallHelper"),
    );
    await helper.parent.create(recursive: true);
    await helper.writeAsBytes(_machO);
    final helperInfo = _plistWithEntries([
      "<key>CFBundleIdentifier</key><string>com.example.desktop-updater.helper</string>",
      "<key>DesktopUpdaterSealedPolicy</key><data>${base64Encode(policyBytes)}</data>",
      "<key>DesktopUpdaterSealedPolicySHA256</key><string>$policyDigest</string>",
    ]);
    final daemon = File(
      path.join(
        app.path,
        "Contents",
        "Library",
        "LaunchDaemons",
        "com.example.desktop-updater.helper.plist",
      ),
    );
    await daemon.parent.create(recursive: true);
    await daemon.writeAsString(_plistWithEntries([
      "<key>Label</key><string>com.example.desktop-updater.helper</string>",
      "<key>MachServices</key><dict><key>com.example.desktop-updater.helper</key><true/></dict>",
      "<key>BundleProgram</key><string>Contents/Helpers/DesktopUpdaterInstallHelper</string>",
    ]));

    final inventory = await MacOSReleaseTrust(
      runProcess: (executable, arguments) async {
        if (executable == "/usr/bin/lipo") {
          return ProcessResult(0, 0, "arm64 x86_64", "");
        }
        if (executable == "/usr/bin/otool") {
          return ProcessResult(0, 0, helperInfo, "");
        }
        return ProcessResult(0, 0, "", "");
      },
    ).preflight(app: app, expectedApplicationIdentifier: "com.example.app");

    expect(inventory.sealedPolicy?.policyId,
        "com.example.desktop-updater.privileged");
    expect(inventory.sealedPolicy?.helperRequirement,
        "identifier com.example.desktop-updater.helper and anchor apple generic");
    expect(inventory.targets, contains(isA<MacOSCodeTarget>()));
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

  test("final ZIP audit verifies the downloaded app after safe extraction",
      () async {
    final root = await Directory.systemTemp.createTemp("macos_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = await _createSimpleApp(root, name: "Audited.app");
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
              Directory(path.join(
                  destination.path, app.path.split(path.separator).last)));
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
      commands.indexWhere(
        (command) =>
            command.first == "/usr/bin/codesign" &&
            command.contains("--entitlements"),
      ),
      greaterThan(
          commands.indexWhere((command) => command.first == "/usr/bin/ditto")),
    );
    expect(
      commands.any(
        (command) =>
            command.first == "/usr/bin/codesign" && command.contains("--deep"),
      ),
      isTrue,
    );
  });
}

const _machO = <int>[0xfe, 0xed, 0xfa, 0xce, 0, 0, 0, 0];
const _codeDetails = "Identifier=com.example.audited\n"
    "TeamIdentifier=TEAMID1234\n"
    "flags=0x10000(runtime)\n";
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
    "Contents/Resources/Assets.bundle",
    kind: MacOSCodeTargetKind.bundle,
    identifier: "com.example.assets",
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
