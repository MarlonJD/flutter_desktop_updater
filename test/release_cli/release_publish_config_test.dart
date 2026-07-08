import "dart:io";

import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("loads minimum updates baseUrl config", () async {
    final tempDir = await Directory.systemTemp.createTemp("release_config_");
    try {
      final configFile = File(path.join(tempDir.path, "desktop_updater.yaml"));
      await configFile.writeAsString("""
updates:
  baseUrl: https://updates.example.com
""");

      final config = await ReleasePublishConfig.load(
        projectRoot: tempDir,
        cliOverrides: const ReleasePublishOverrides(),
      );

      expect(config.baseUrl.toString(), "https://updates.example.com/");
      expect(config.uploadProvider, isA<ManualUploadConfig>());
      expect(
        config.outputDirectory.path,
        path.join(tempDir.path, "dist", "desktop_updater"),
      );
      expect(config.channel, "stable");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("rejects missing baseUrl", () async {
    final tempDir = await Directory.systemTemp.createTemp("release_config_");
    try {
      await expectLater(
        ReleasePublishConfig.load(
          projectRoot: tempDir,
          cliOverrides: const ReleasePublishOverrides(),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("updates.baseUrl is required"),
          ),
        ),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("loads explicit macOS notarization config", () async {
    final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
  staple: false
  gatekeeperAssess: false
""");

    expect(config.macos.notarize, isTrue);
    expect(
      config.macos.developerIdApplication,
      "Developer ID Application: Example Corp (TEAMID1234)",
    );
    expect(config.macos.notaryProfile, "desktop-updater-notary");
    expect(
      config.macos.keychain,
      "/Users/me/Library/Keychains/login.keychain-db",
    );
    expect(config.macos.staple, isFalse);
    expect(config.macos.gatekeeperAssess, isFalse);
  });

  test("loads macOS DMG artifact publish config", () async {
    final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  artifact:
    kind: dmg
  dmg:
    volumeName: Example
    appBundleName: Example.app
    applicationsAlias: true
""");

    expect(config.macos.artifactKind.name, "dmg");
    expect(config.macos.dmg.volumeName, "Example");
    expect(config.macos.dmg.appBundleName, "Example.app");
    expect(config.macos.dmg.applicationsAlias, isTrue);
  });

  test("macOS artifact config defaults to zip", () async {
    final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com
""");

    expect(config.macos.artifactKind.name, "zip");
  });

  test("macOS DMG defaults use the configured app name", () async {
    final config = await ReleasePublishConfig.fromYaml(
      """
updates:
  baseUrl: https://updates.example.com

macos:
  artifact:
    kind: dmg
""",
      cliOverrides: const ReleasePublishOverrides(
        appName: "Example Studio",
      ),
    );

    expect(config.macos.dmg.volumeName, "Example Studio");
    expect(config.macos.dmg.appBundleName, "Example Studio.app");
    expect(config.macos.dmg.applicationsAlias, isTrue);
  });

  test("rejects invalid macOS artifact kinds", () async {
    await expectLater(
      ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  artifact:
    kind: tarball
"""),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("macos.artifact.kind must be zip, dmg, or pkg"),
        ),
      ),
    );
  });

  test("loads macOS PKG artifact publish config", () async {
    final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
  artifact:
    kind: pkg
  pkg:
    packageIdentifier: com.example.app.pkg
    installLocation: /Applications
    signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)"
""");

    expect(config.macos.artifactKind.name, "pkg");
    expect(config.macos.pkg.packageIdentifier, "com.example.app.pkg");
    expect(config.macos.pkg.installLocation, "/Applications");
    expect(
      config.macos.pkg.signingIdentifier,
      "Developer ID Installer: Example Corp (TEAMID1234)",
    );
  });

  test("rejects macOS PKG config without a package identifier", () async {
    await expectLater(
      ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
  artifact:
    kind: pkg
"""),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("macos.pkg.packageIdentifier is required"),
        ),
      ),
    );
  });

  test("rejects macOS PKG config without notarization", () async {
    await expectLater(
      ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  artifact:
    kind: pkg
  pkg:
    packageIdentifier: com.example.app.pkg
    installLocation: /Applications
    signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)"
"""),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("macos.notarize: true is required"),
        ),
      ),
    );
  });

  test("rejects macOS PKG config without stapling", () async {
    await expectLater(
      ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
  staple: false
  artifact:
    kind: pkg
  pkg:
    packageIdentifier: com.example.app.pkg
    installLocation: /Applications
    signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)"
"""),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("macos.staple must be true"),
        ),
      ),
    );
  });

  test("loads Windows Inno installer publish config", () async {
    final root = await Directory.systemTemp.createTemp("inno_config_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final config = await ReleasePublishConfig.fromYaml(
      r"""
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: generated
    isccPath: C:\Program Files (x86)\Inno Setup 6\ISCC.exe
    outputBaseName: ExampleSetup
    appId: com.example.app
    publisher: Example Inc.
    publisherUrl: https://example.com
    supportUrl: https://example.com/support
    updatesUrl: https://example.com/download
    privilegesRequired: admin
    architecturesAllowed: x64
    architecturesInstallIn64BitMode: x64
    setupIcon: windows/runner/resources/app_icon.ico
    licenseFile: LICENSE
    silentArgs:
      - /VERYSILENT
      - /SUPPRESSMSGBOXES
      - /NORESTART
    requiresElevation: auto
    authenticodeThumbprints:
      - 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
""",
      projectRoot: root,
    );

    final inno = config.windows.installer;
    expect(inno.kind, "inno");
    expect(inno.mode, "generated");
    expect(inno.appId, "com.example.app");
    expect(inno.publisher, "Example Inc.");
    expect(inno.privilegesRequired, "admin");
    expect(inno.silentArgs, ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"]);
    expect(inno.authenticodeThumbprints.single, hasLength(64));
  });

  test("cli notarize flag enables configured macOS notarization", () async {
    final config = await ReleasePublishConfig.fromYaml(
      """
updates:
  baseUrl: https://updates.example.com

macos:
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
""",
      cliOverrides: const ReleasePublishOverrides(notarize: true),
    );

    expect(config.macos.notarize, isTrue);
    expect(config.macos.staple, isTrue);
    expect(config.macos.gatekeeperAssess, isTrue);
  });

  test("notarization requires non-secret Apple credential references",
      () async {
    await expectLater(
      ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
"""),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("macos.developerIdApplication is required"),
        ),
      ),
    );
  });

  test("loads pre-package and post-package hooks", () async {
    final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

hooks:
  prePackage:
    - command: ./tool/sign_windows_release.ps1
      platforms: [windows]
  postPackage:
    - command: ./tool/sign_release_json.sh
      platforms: [linux, windows, macos]
""");

    expect(config.hooks.prePackage, hasLength(1));
    expect(
      config.hooks.prePackage.single.command,
      "./tool/sign_windows_release.ps1",
    );
    expect(config.hooks.prePackage.single.platforms, ["windows"]);
    expect(config.hooks.postPackage, hasLength(1));
    expect(
      config.hooks.postPackage.single.command,
      "./tool/sign_release_json.sh",
    );
    expect(config.hooks.postPackage.single.platforms, [
      "linux",
      "windows",
      "macos",
    ]);
  });

  test("loads additional release files", () async {
    final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

additionalFiles:
  - source: release-assets/manuals/*
    destination: docs/manuals
    platforms: [linux, windows]
  - source: release-assets/macos-help
    destination: Contents/Resources/Help
    platforms: [macos]
""");

    expect(config.additionalFiles, hasLength(2));
    expect(config.additionalFiles.first.source, "release-assets/manuals/*");
    expect(config.additionalFiles.first.destination, "docs/manuals");
    expect(config.additionalFiles.first.platforms, ["linux", "windows"]);
    expect(config.additionalFiles.last.source, "release-assets/macos-help");
    expect(
      config.additionalFiles.last.destination,
      "Contents/Resources/Help",
    );
    expect(config.additionalFiles.last.platforms, ["macos"]);
  });

  test("rejects secrets in hook config", () async {
    await expectLater(
      ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

hooks:
  postPackage:
    - command: ./tool/sign_release_json.sh
      platforms: [linux]
      environment:
        DESKTOP_UPDATER_RELEASE_PRIVATE_KEY: inline-secret
"""),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("hooks.postPackage[0].environment must not be set"),
        ),
      ),
    );
  });
}
