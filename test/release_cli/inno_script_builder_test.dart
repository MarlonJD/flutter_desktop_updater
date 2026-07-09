import "dart:io";

import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/inno/inno_script_builder.dart";
import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("generates Inno setup script for a Flutter Windows release", () {
    final metadata = ProjectMetadata(
      version: "2.5.0",
      buildNumber: 250,
      appName: "Example",
      packageId: "com.example.app",
      platform: "windows",
      profile: PlatformReleaseProfile.forPlatform("windows"),
      input: Directory(r"C:\repo\build\windows\x64\runner\Release"),
    );
    const config = InnoPublishConfig(
      kind: "inno",
      mode: "generated",
      appId: "com.example.app",
      publisher: "Example Inc.",
      publisherUrl: "https://example.com",
      supportUrl: "https://example.com/support",
      updatesUrl: "https://example.com/download",
      privilegesRequired: "admin",
      architecturesAllowed: "x64",
      architecturesInstallIn64BitMode: "x64",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath:
          r"C:\repo\dist\desktop_updater\releases\2.5.0\windows",
      outputBaseName: "Example-2.5.0-windows-setup",
    );

    expect(script, contains('#define MyAppName "Example"'));
    expect(script, contains("AppId={{com.example.app}}"));
    expect(script, contains("AppVersion=2.5.0"));
    expect(script, contains("AppPublisher=Example Inc."));
    expect(script, contains(r"DefaultDirName={autopf}\Example"));
    expect(script, contains("OutputBaseFilename=Example-2.5.0-windows-setup"));
    expect(script, contains("PrivilegesRequired=admin"));
    expect(script, contains("ArchitecturesAllowed=x64"));
    expect(script, contains("ArchitecturesInstallIn64BitMode=x64"));
    expect(
      script,
      contains(
        r'Source: "C:\repo\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs',
      ),
    );
    expect(
      script,
      contains(
          r'Name: "{autoprograms}\Example"; Filename: "{app}\Example.exe"'),
    );
  });
}
