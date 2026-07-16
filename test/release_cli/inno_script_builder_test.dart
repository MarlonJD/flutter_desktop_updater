import "dart:io";

import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/inno/inno_script_builder.dart";
import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  const helperSha256 =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const policySha256 =
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const identitySource = r"C:\repo\dist\.desktop_updater_install_identity.json";

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
      protectedHelperInstallDir:
          r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath:
          r"C:\repo\dist\desktop_updater\releases\2.5.0\windows",
      outputBaseName: "Example-2.5.0-windows-setup",
      protectedHelperSha256: helperSha256,
      protectedPolicySha256: policySha256,
      installedIdentitySourcePath: identitySource,
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
        r'#define DesktopUpdaterProtectedHelperDir "C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0"',
      ),
    );
    expect(script, contains('ValueName: "DesktopUpdaterPackageId"'));
    expect(script, contains('ValueData: "com.example.app"'));
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

  test(
      "provisions and registers the compiled protected helper endpoint from a fresh leaf",
      () {
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
      privilegesRequired: "admin",
      protectedHelperInstallDir:
          r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath: r"C:\repo\dist",
      outputBaseName: "ExampleSetup",
      protectedHelperSha256: helperSha256,
      protectedPolicySha256: policySha256,
      installedIdentitySourcePath: identitySource,
    );

    const protectedDir =
        r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0";
    final helperEntry =
        'Source: "C:\\repo\\build\\windows\\x64\\runner\\Release\\desktop_updater_install_helper.exe"; '
        'DestDir: "{code:DesktopUpdaterProvisioningDir}"; '
        'Flags: ignoreversion uninsneveruninstall; '
        'AfterInstall: HardenDesktopUpdaterHelperFile';
    final policyEntry =
        'Source: "C:\\repo\\build\\windows\\x64\\runner\\Release\\desktop_updater_helper_policy.json"; '
        'DestDir: "{code:DesktopUpdaterProvisioningDir}"; '
        'Flags: ignoreversion uninsneveruninstall; '
        'AfterInstall: HardenDesktopUpdaterPolicyFile';

    expect(
      script,
      contains('#define DesktopUpdaterProtectedHelperDir "$protectedDir"'),
    );
    expect(
      script,
      isNot(contains('Name: "{#DesktopUpdaterProtectedHelperDir}"')),
    );
    expect(
      script,
      contains(
        'Name: "{code:DesktopUpdaterProvisioningDir}"; '
        'Flags: uninsneveruninstall; '
        'AfterInstall: HardenDesktopUpdaterProvisioningDir',
      ),
    );
    expect(script, contains(helperEntry));
    expect(script, contains(policyEntry));
    expect(script.indexOf(helperEntry), lessThan(script.indexOf(policyEntry)));
    expect(script, contains("{sys}\\icacls.exe"));
    expect(script, contains("/reset /Q"));
    expect(script, contains("/inheritancelevel:r"));
    expect(script, contains("*S-1-5-18:(OI)(CI)F"));
    expect(script, contains("*S-1-5-32-544:(OI)(CI)F"));
    expect(script, contains("*S-1-5-32-545:(OI)(CI)RX"));
    expect(script, contains("/setowner *S-1-5-32-544 /Q"));
    expect(script, contains("PreflightDesktopUpdaterProtectedInstall"));
    expect(
      script,
      contains("protected helper directory must be outside the app tree"),
    );
    expect(script, contains("--register-endpoint"));
    expect(script, contains("ewWaitUntilTerminated"));
    expect(script, contains("ResultCode <> 0"));
    expect(script, contains("RaiseException"));
    expect(script, contains("function PrepareToInstall"));
    expect(script, contains("PreflightDesktopUpdaterProtectedInstall"));
    expect(script, contains("DesktopUpdaterExpectedHelperSha256"));
    expect(script, contains(helperSha256));
    expect(script, contains("DesktopUpdaterExpectedPolicySha256"));
    expect(script, contains(policySha256));
    expect(script, contains("GetSHA256OfFile"));
    expect(script, contains("FILE_ATTRIBUTE_REPARSE_POINT"));
    expect(script, contains("--validate-endpoint"));
    expect(script, isNot(contains("onlyifdoesntexist")));
    expect(
      script,
      contains(
        r'Source: "C:\repo\dist\.desktop_updater_install_identity.json"; DestDir: "{app}"; DestName: ".desktop_updater_install_identity.json"',
      ),
    );
    expect(
      script,
      contains("procedure CurStepChanged(CurStep: TSetupStep)"),
    );
    expect(script, contains("RegisterDesktopUpdaterProtectedEndpoint"));
  });

  test("keeps protected recovery authority out of normal uninstall cleanup",
      () {
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
      privilegesRequired: "admin",
      protectedHelperInstallDir:
          r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath: r"C:\repo\dist",
      outputBaseName: "ExampleSetup",
      protectedHelperSha256: helperSha256,
      protectedPolicySha256: policySha256,
      installedIdentitySourcePath: identitySource,
    );

    expect(RegExp("uninsneveruninstall").allMatches(script), hasLength(3));
    expect(script, isNot(contains(r"Software\DesktopUpdater\Transactions")));
    expect(
      script,
      isNot(contains(r"Software\DesktopUpdater\TransactionEndpoints")),
    );
    expect(script, isNot(contains("[UninstallDelete]")));
  });

  test(
      "never executes a pre-existing helper leaf before fresh protected promotion",
      () {
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
      privilegesRequired: "admin",
      protectedHelperInstallDir:
          r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath: r"C:\repo\dist",
      outputBaseName: "ExampleSetup",
      protectedHelperSha256: helperSha256,
      protectedPolicySha256: policySha256,
      installedIdentitySourcePath: identitySource,
    );

    final preflight = _between(
      script,
      "function PreflightDesktopUpdaterProtectedInstall: String;",
      "function PrepareToInstall(var NeedsRestart: Boolean): String;",
    );
    expect(preflight, isNot(contains("GetSHA256OfFile")));
    expect(preflight, isNot(contains("Exec(")));
    expect(preflight, isNot(contains("desktop_updater_install_helper.exe")));
    expect(
      script,
      contains(
        "GenerateUniqueName(TrustedProgramFilesDir, '.provisioning')",
      ),
    );
    expect(
      script,
      contains('DestDir: "{code:DesktopUpdaterProvisioningDir}"'),
    );
    expect(
      script,
      contains("HardenDesktopUpdaterProvisioningDir"),
    );

    final quarantine = script.indexOf(
      "RenameFile(FinalDir, DesktopUpdaterQuarantinePath)",
    );
    final promotion = script.indexOf(
      "RenameFile(DesktopUpdaterProvisioningPath, FinalDir)",
    );
    final validation = script.indexOf("--validate-endpoint", promotion);
    final registration = script.indexOf("--register-endpoint", validation);
    expect(quarantine, greaterThanOrEqualTo(0));
    expect(promotion, greaterThan(quarantine));
    expect(validation, greaterThan(promotion));
    expect(registration, greaterThan(validation));
  });

  test(
      "same-release retry repairs unsafe leaves and restores only before promotion",
      () {
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
      privilegesRequired: "admin",
      protectedHelperInstallDir:
          r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath: r"C:\repo\dist",
      outputBaseName: "ExampleSetup",
      protectedHelperSha256: helperSha256,
      protectedPolicySha256: policySha256,
      installedIdentitySourcePath: identitySource,
    );

    expect(script, isNot(contains("HelperExists <> PolicyExists")));
    expect(
      script,
      isNot(contains("already exists without the expected immutable files")),
    );
    expect(
      script,
      isNot(contains("protected helper installation is incomplete")),
    );
    expect(script, contains("if FileOrDirExists(FinalDir) then"));
    expect(
      script,
      contains(
        "DesktopUpdaterHadLegacyLeaf := FileOrDirExists(FinalDir)",
      ),
    );
    expect(script, contains("QuarantineDesktopUpdaterFailedPromotion"));
    final promotion = _between(
      script,
      "procedure PromoteDesktopUpdaterFreshLeaf;",
      "procedure QuarantineDesktopUpdaterFailedPromotion;",
    );
    expect(
      promotion,
      contains(
        "RenameFile(DesktopUpdaterQuarantinePath, FinalDir)",
      ),
    );
  });

  test("never restores a historical leaf after endpoint registration starts",
      () {
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
      privilegesRequired: "admin",
      protectedHelperInstallDir:
          r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath: r"C:\repo\dist",
      outputBaseName: "ExampleSetup",
      protectedHelperSha256: helperSha256,
      protectedPolicySha256: policySha256,
      installedIdentitySourcePath: identitySource,
    );
    final registration = _between(
      script,
      "procedure RegisterDesktopUpdaterProtectedEndpoint;",
      "procedure InstallDesktopUpdaterProtectedEndpoint;",
    );
    final registerAttempt = registration.substring(
      registration.indexOf("--register-endpoint"),
    );

    expect(registerAttempt, isNot(contains("RollbackDesktopUpdater")));
    expect(
      registerAttempt,
      isNot(contains("RenameFile(DesktopUpdaterQuarantinePath, FinalDir)")),
    );
    expect(
      registerAttempt,
      contains("registration retry remains bound to the fresh protected leaf"),
    );
  });

  test(
      "requires a version generation leaf inherited directly from trusted Program Files",
      () {
    final metadata = ProjectMetadata(
      version: "2.5.0",
      buildNumber: 250,
      appName: "Example",
      packageId: "com.example.app",
      platform: "windows",
      profile: PlatformReleaseProfile.forPlatform("windows"),
      input: Directory(r"C:\repo\build\windows\x64\runner\Release"),
    );

    String buildAt(String installDir) => const InnoScriptBuilder().build(
          metadata: metadata,
          config: InnoPublishConfig(
            kind: "inno",
            mode: "generated",
            privilegesRequired: "admin",
            protectedHelperInstallDir: installDir,
          ),
          outputDirectoryPath: r"C:\repo\dist",
          outputBaseName: "ExampleSetup",
          protectedHelperSha256: helperSha256,
          protectedPolicySha256: policySha256,
          installedIdentitySourcePath: identitySource,
        );

    const generationLeaf =
        r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0";
    final script = buildAt(generationLeaf);
    expect(
      script,
      contains(
        '#define DesktopUpdaterProtectedHelperDir "$generationLeaf"',
      ),
    );
    expect(
      script,
      contains(
        r'#define DesktopUpdaterTrustedProgramFilesDir "C:\Program Files"',
      ),
    );
    expect(script, isNot(contains(r"DesktopUpdater\Helpers")));
    expect(script, isNot(contains("DesktopUpdaterProtectedPackageDir")));
    expect(
      script,
      isNot(
        contains("HardenDesktopUpdaterObject(TrustedProgramFilesDir"),
      ),
    );
    final provisioningHardening = _between(
      script,
      "procedure HardenDesktopUpdaterProvisioningDir;",
      "procedure HardenDesktopUpdaterHelperFile;",
    );
    expect(
      provisioningHardening,
      contains(
        "HardenDesktopUpdaterObject(DesktopUpdaterProvisioningPath, True)",
      ),
    );
    expect(
      () => buildAt(
        r"C:\Program Files\DesktopUpdater\Helpers\com.example.app\2.5.0",
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test("rejects unsafe programmatic protected helper destinations", () {
    final metadata = ProjectMetadata(
      version: "2.5.0",
      buildNumber: 250,
      appName: "Example",
      packageId: "com.example.app",
      platform: "windows",
      profile: PlatformReleaseProfile.forPlatform("windows"),
      input: Directory(r"C:\repo\build\windows\x64\runner\Release"),
    );

    for (final installDir in <String>[
      "helper",
      'C:\\safe"; AfterInstall: Untrusted',
      r"C:\safe\..\outside",
      r"C:\Program Files",
      r"C:\Windows",
      r"C:\Windows\System32",
      r"C:\Program Files\Example",
      r"C:\Program Files\DesktopUpdater\Helpers\com.example.app",
      r"C:\Program Files\DesktopUpdater\Helpers\other.package\2.5.0",
      r"C:\Program Files\DesktopUpdater\Helpers\com.example.app\2.4.0",
      r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app",
      r"C:\Program Files\DesktopUpdaterHelperGenerationV1--other.package--2.5.0",
      r"C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.4.0",
      r"C:\Program Files\Nested\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0",
    ]) {
      expect(
        () => const InnoScriptBuilder().build(
          metadata: metadata,
          config: InnoPublishConfig(
            kind: "inno",
            mode: "generated",
            privilegesRequired: "admin",
            protectedHelperInstallDir: installDir,
          ),
          outputDirectoryPath: r"C:\repo\dist",
          outputBaseName: "ExampleSetup",
          protectedHelperSha256: helperSha256,
          protectedPolicySha256: policySha256,
          installedIdentitySourcePath: identitySource,
        ),
        throwsA(isA<FormatException>()),
        reason: installDir,
      );
    }
  });
}

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, greaterThanOrEqualTo(0), reason: start);
  expect(endIndex, greaterThan(startIndex), reason: end);
  return source.substring(startIndex, endIndex);
}
