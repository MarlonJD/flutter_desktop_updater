import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:path/path.dart" as path;

class InnoScriptBuilder {
  const InnoScriptBuilder();

  String build({
    required ProjectMetadata metadata,
    required InnoPublishConfig config,
    required String outputDirectoryPath,
    required String outputBaseName,
    required String installedIdentitySourcePath,
    String? protectedHelperSha256,
    String? protectedPolicySha256,
  }) {
    final appName = metadata.appName;
    final executableName = appName.endsWith(".exe") ? appName : "$appName.exe";
    final appId = config.appId ?? metadata.packageId;
    final publisher = config.publisher ?? appName;
    final escapedInput = _escapeInnoString(metadata.input.path);
    final escapedOutput = _escapeInnoString(outputDirectoryPath);
    final escapedIcon = config.setupIcon == null
        ? null
        : _escapeInnoString(path.normalize(config.setupIcon!));
    final escapedLicense = config.licenseFile == null
        ? null
        : _escapeInnoString(path.normalize(config.licenseFile!));
    final protectedHelperInstallDir =
        resolveGeneratedProtectedHelperInstallDir(config);
    final escapedProtectedHelperInstallDir = protectedHelperInstallDir == null
        ? null
        : _escapeInnoString(
            path.windows.normalize(protectedHelperInstallDir),
          );
    final escapedTrustedProgramFilesDir = protectedHelperInstallDir == null
        ? null
        : _escapeInnoString(
            path.windows
                .dirname(path.windows.normalize(protectedHelperInstallDir)),
          );
    final escapedInstalledIdentitySourcePath = _escapeInnoString(
      path.normalize(installedIdentitySourcePath),
    );
    if (protectedHelperInstallDir != null) {
      validateGeneratedProtectedHelperInstallDirBinding(
        installDir: protectedHelperInstallDir,
        packageId: metadata.packageId,
        version: metadata.version,
      );
      _requireSha256(protectedHelperSha256, "protected helper");
      _requireSha256(protectedPolicySha256, "protected helper policy");
    }

    final buffer = StringBuffer()
      ..writeln('#define MyAppName "${_escapeDefine(appName)}"')
      ..writeln('#define MyAppVersion "${_escapeDefine(metadata.version)}"');
    if (escapedProtectedHelperInstallDir != null) {
      buffer.writeln(
        '#define DesktopUpdaterProtectedHelperDir '
        '"$escapedProtectedHelperInstallDir"',
      );
      buffer
        ..writeln(
          '#define DesktopUpdaterTrustedProgramFilesDir '
          '"$escapedTrustedProgramFilesDir"',
        )
        ..writeln(
          '#define DesktopUpdaterExpectedHelperSha256 '
          '"$protectedHelperSha256"',
        )
        ..writeln(
          '#define DesktopUpdaterExpectedPolicySha256 '
          '"$protectedPolicySha256"',
        );
    }
    buffer
      ..writeln("[Setup]")
      ..writeln("AppId={{${_escapeInnoValue(appId)}}}")
      ..writeln("AppName=$appName")
      ..writeln("AppVersion=${metadata.version}")
      ..writeln("AppPublisher=$publisher")
      ..writeln("DefaultDirName={autopf}\\$appName")
      ..writeln("DefaultGroupName=$appName")
      ..writeln("DisableProgramGroupPage=yes")
      ..writeln("OutputDir=$escapedOutput")
      ..writeln("OutputBaseFilename=$outputBaseName")
      ..writeln("Compression=lzma2")
      ..writeln("SolidCompression=yes")
      ..writeln("WizardStyle=modern")
      ..writeln("PrivilegesRequired=${config.privilegesRequired}")
      ..writeln("ArchitecturesAllowed=${config.architecturesAllowed}")
      ..writeln(
        "ArchitecturesInstallIn64BitMode="
        "${config.architecturesInstallIn64BitMode}",
      );

    if (config.publisherUrl != null) {
      buffer.writeln("AppPublisherURL=${config.publisherUrl}");
    }
    if (config.supportUrl != null) {
      buffer.writeln("AppSupportURL=${config.supportUrl}");
    }
    if (config.updatesUrl != null) {
      buffer.writeln("AppUpdatesURL=${config.updatesUrl}");
    }
    if (escapedIcon != null) {
      buffer.writeln("SetupIconFile=$escapedIcon");
    }
    if (escapedLicense != null) {
      buffer.writeln("LicenseFile=$escapedLicense");
    }

    if (escapedProtectedHelperInstallDir != null) {
      buffer
        ..writeln()
        ..writeln("[Dirs]")
        ..writeln(
          'Name: "{code:DesktopUpdaterProvisioningDir}"; '
          'Flags: uninsneveruninstall; '
          'AfterInstall: HardenDesktopUpdaterProvisioningDir',
        );
    }

    buffer
      ..writeln()
      ..writeln("[Files]")
      ..writeln(
        'Source: "$escapedInput\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs',
      )
      ..writeln(
        'Source: "$escapedInstalledIdentitySourcePath"; DestDir: "{app}"; '
        'DestName: ".desktop_updater_install_identity.json"; '
        'Flags: ignoreversion',
      );
    if (escapedProtectedHelperInstallDir != null) {
      buffer
        ..writeln(
          'Source: "$escapedInput\\desktop_updater_install_helper.exe"; '
          'DestDir: "{code:DesktopUpdaterProvisioningDir}"; '
          'Flags: ignoreversion uninsneveruninstall; '
          'AfterInstall: HardenDesktopUpdaterHelperFile',
        )
        ..writeln(
          'Source: "$escapedInput\\desktop_updater_helper_policy.json"; '
          'DestDir: "{code:DesktopUpdaterProvisioningDir}"; '
          'Flags: ignoreversion uninsneveruninstall; '
          'AfterInstall: HardenDesktopUpdaterPolicyFile',
        );
    }
    buffer
      ..writeln()
      ..writeln("[Registry]")
      ..writeln(
        'Root: HKA; Subkey: "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{#SetupSetting(\'AppId\')}_is1"; ValueType: string; ValueName: "DesktopUpdaterPackageId"; ValueData: "${_escapeInnoString(metadata.packageId)}"; Flags: uninsdeletevalue',
      )
      ..writeln(
        'Root: HKA; Subkey: "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{#SetupSetting(\'AppId\')}_is1"; ValueType: string; ValueName: "InstallLocation"; ValueData: "{app}"; Flags: uninsdeletevalue',
      )
      ..writeln()
      ..writeln("[Icons]")
      ..writeln(
        'Name: "{autoprograms}\\$appName"; Filename: "{app}\\$executableName"',
      )
      ..writeln()
      ..writeln("[Run]");

    buffer.writeln(
      'Filename: "{app}\\$executableName"; Description: "{cm:LaunchProgram,$appName}"; Flags: nowait postinstall skipifsilent',
    );

    if (escapedProtectedHelperInstallDir != null) {
      buffer
        ..writeln()
        ..writeln("[Code]")
        ..writeln("procedure FailDesktopUpdaterProvisioning(")
        ..writeln("  const Step: String; const ResultCode: Integer);")
        ..writeln("begin")
        ..writeln(
          "  RaiseException('Desktop updater protected helper ' + Step + "
          "    ' failed with exit code ' + IntToStr(ResultCode) + '.');",
        )
        ..writeln("end;")
        ..writeln()
        ..writeln("const")
        ..writeln("  DESKTOP_UPDATER_FILE_ATTRIBUTE_REPARSE_POINT = \$400;")
        ..writeln()
        ..writeln("var")
        ..writeln("  DesktopUpdaterProvisioningPath: String;")
        ..writeln("  DesktopUpdaterQuarantinePath: String;")
        ..writeln("  DesktopUpdaterFailedPromotionPath: String;")
        ..writeln("  DesktopUpdaterHadLegacyLeaf: Boolean;")
        ..writeln()
        ..writeln("function DesktopUpdaterPathContainsReparsePoint(")
        ..writeln("  const Candidate: String): Boolean;")
        ..writeln("var")
        ..writeln("  Attributes: Integer;")
        ..writeln("  Current: String;")
        ..writeln("  Parent: String;")
        ..writeln("begin")
        ..writeln("  Result := False;")
        ..writeln("  Current := ExpandFileName(Candidate);")
        ..writeln("  while Current <> '' do")
        ..writeln("  begin")
        ..writeln("    Attributes := GetFileAttributes(Current);")
        ..writeln(
          "    if (Attributes <> -1) and "
          "((Attributes and DESKTOP_UPDATER_FILE_ATTRIBUTE_REPARSE_POINT) "
          "<> 0) then",
        )
        ..writeln("    begin")
        ..writeln("      Result := True;")
        ..writeln("      Exit;")
        ..writeln("    end;")
        ..writeln("    Parent := ExtractFileDir(Current);")
        ..writeln(
          "    if (Parent = '') or (CompareText(Parent, Current) = 0) then",
        )
        ..writeln("      Exit;")
        ..writeln("    Current := Parent;")
        ..writeln("  end;")
        ..writeln("end;")
        ..writeln()
        ..writeln("function PreflightDesktopUpdaterProtectedInstall: String;")
        ..writeln("var")
        ..writeln("  AppDir: String;")
        ..writeln("  TrustedProgramFilesDir: String;")
        ..writeln("  ConfiguredTrustedDir: String;")
        ..writeln("  FinalDir: String;")
        ..writeln("begin")
        ..writeln("  Result := '';")
        ..writeln(
          "  AppDir := AddBackslash(ExpandFileName(ExpandConstant('{app}')));",
        )
        ..writeln(
          "  TrustedProgramFilesDir := ExpandFileName("
          "ExpandConstant('{autopf}'));",
        )
        ..writeln(
          "  ConfiguredTrustedDir := ExpandFileName("
          "ExpandConstant('{#DesktopUpdaterTrustedProgramFilesDir}'));",
        )
        ..writeln(
          "  FinalDir := ExpandFileName("
          "ExpandConstant('{#DesktopUpdaterProtectedHelperDir}'));",
        )
        ..writeln(
          "  if CompareText(ConfiguredTrustedDir, "
          "TrustedProgramFilesDir) <> 0 then",
        )
        ..writeln("  begin")
        ..writeln(
          "    Result := 'Desktop updater trusted Program Files binding "
          "changed.';",
        )
        ..writeln("    Exit;")
        ..writeln("  end;")
        ..writeln(
          "  if CompareText(ExtractFileDir(FinalDir), "
          "TrustedProgramFilesDir) <> 0 then",
        )
        ..writeln(
          "  begin",
        )
        ..writeln(
          "    Result := 'Desktop updater protected helper directory is "
          "not a direct child of trusted Program Files.';",
        )
        ..writeln("    Exit;")
        ..writeln("  end;")
        ..writeln(
          "  if PathStartsWith(AddBackslash(FinalDir), AppDir, True) or "
          "PathStartsWith(AppDir, AddBackslash(FinalDir), True) then",
        )
        ..writeln("  begin")
        ..writeln(
          "    Result := 'Desktop updater protected helper directory "
          "must be outside the app tree and cannot contain the app tree.';",
        )
        ..writeln("    Exit;")
        ..writeln("  end;")
        ..writeln(
          "  if DesktopUpdaterPathContainsReparsePoint("
          "TrustedProgramFilesDir) then",
        )
        ..writeln("  begin")
        ..writeln(
          "    Result := 'Desktop updater protected helper parent path "
          "contains a reparse point.';",
        )
        ..writeln("    Exit;")
        ..writeln("  end;")
        ..writeln("end;")
        ..writeln()
        ..writeln(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;")
        ..writeln("var")
        ..writeln("  TrustedProgramFilesDir: String;")
        ..writeln("begin")
        ..writeln("  Result := PreflightDesktopUpdaterProtectedInstall;")
        ..writeln("  if Result <> '' then")
        ..writeln("    Exit;")
        ..writeln(
          "  TrustedProgramFilesDir := ExpandFileName("
          "ExpandConstant('{#DesktopUpdaterTrustedProgramFilesDir}'));",
        )
        ..writeln(
          "  DesktopUpdaterProvisioningPath := "
          "GenerateUniqueName(TrustedProgramFilesDir, '.provisioning');",
        )
        ..writeln(
          "  DesktopUpdaterQuarantinePath := "
          "GenerateUniqueName(TrustedProgramFilesDir, '.quarantine');",
        )
        ..writeln(
          "  DesktopUpdaterFailedPromotionPath := "
          "GenerateUniqueName(TrustedProgramFilesDir, '.failed');",
        )
        ..writeln("  DesktopUpdaterHadLegacyLeaf := False;")
        ..writeln("end;")
        ..writeln()
        ..writeln(
          "function DesktopUpdaterProvisioningDir(Param: String): String;",
        )
        ..writeln("begin")
        ..writeln("  if DesktopUpdaterProvisioningPath = '' then")
        ..writeln(
          "    RaiseException('Desktop updater fresh provisioning path "
          "was not prepared.');",
        )
        ..writeln("  Result := DesktopUpdaterProvisioningPath;")
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure RunDesktopUpdaterIcacls(")
        ..writeln(
          "  const TargetPath: String; const Arguments: String; "
          "const Step: String);",
        )
        ..writeln("var")
        ..writeln("  ResultCode: Integer;")
        ..writeln("begin")
        ..writeln(
          "  if (not Exec(ExpandConstant('{sys}\\icacls.exe'), "
          "    '\"' + TargetPath + '\" ' + Arguments, '', SW_HIDE, "
          "    ewWaitUntilTerminated, ResultCode)) or "
          "(ResultCode <> 0) then",
        )
        ..writeln("    FailDesktopUpdaterProvisioning(Step, ResultCode);")
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure HardenDesktopUpdaterObject(")
        ..writeln(
            "  const TargetPath: String; const DirectoryObject: Boolean);")
        ..writeln("var")
        ..writeln("  Grants: String;")
        ..writeln("begin")
        ..writeln(
          "  if DesktopUpdaterPathContainsReparsePoint(TargetPath) then",
        )
        ..writeln(
          "    RaiseException('Desktop updater ACL target contains a "
          "reparse point.');",
        )
        ..writeln(
          "  RunDesktopUpdaterIcacls(TargetPath, '/L /reset /Q', "
          "'ACL reset');",
        )
        ..writeln("  if DirectoryObject then")
        ..writeln(
          "    Grants := '*S-1-5-18:(OI)(CI)F "
          "*S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX'",
        )
        ..writeln("  else")
        ..writeln(
          "    Grants := '*S-1-5-18:F *S-1-5-32-544:F "
          "*S-1-5-32-545:RX';",
        )
        ..writeln(
          "  RunDesktopUpdaterIcacls(TargetPath, "
          "    '/L /inheritancelevel:r /grant:r ' + Grants + ' /Q', "
          "    'protected DACL');",
        )
        ..writeln(
          "  RunDesktopUpdaterIcacls(TargetPath, "
          "    '/L /setowner *S-1-5-32-544 /Q', 'trusted owner');",
        )
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure HardenDesktopUpdaterProvisioningDir;")
        ..writeln("begin")
        ..writeln("  if DesktopUpdaterProvisioningPath = '' then")
        ..writeln(
          "    RaiseException('Desktop updater fresh provisioning path "
          "was not prepared.');",
        )
        ..writeln(
          "  HardenDesktopUpdaterObject(DesktopUpdaterProvisioningPath, "
          "True);",
        )
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure HardenDesktopUpdaterHelperFile;")
        ..writeln("begin")
        ..writeln(
          "  HardenDesktopUpdaterObject(AddBackslash("
          "DesktopUpdaterProvisioningPath) + "
          "'desktop_updater_install_helper.exe', False);",
        )
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure HardenDesktopUpdaterPolicyFile;")
        ..writeln("begin")
        ..writeln(
          "  HardenDesktopUpdaterObject(AddBackslash("
          "DesktopUpdaterProvisioningPath) + "
          "'desktop_updater_helper_policy.json', False);",
        )
        ..writeln("end;")
        ..writeln()
        ..writeln("function DesktopUpdaterFreshLeafError(")
        ..writeln("  const LeafDir: String): String;")
        ..writeln("var")
        ..writeln("  HelperPath: String;")
        ..writeln("  PolicyPath: String;")
        ..writeln("begin")
        ..writeln("  Result := '';")
        ..writeln(
          "  HelperPath := AddBackslash(LeafDir) + "
          "'desktop_updater_install_helper.exe';",
        )
        ..writeln(
          "  PolicyPath := AddBackslash(LeafDir) + "
          "'desktop_updater_helper_policy.json';",
        )
        ..writeln(
          "  if DesktopUpdaterPathContainsReparsePoint(LeafDir) or "
          "DesktopUpdaterPathContainsReparsePoint(HelperPath) or "
          "DesktopUpdaterPathContainsReparsePoint(PolicyPath) then",
        )
        ..writeln("  begin")
        ..writeln(
          "    Result := 'Desktop updater fresh protected helper leaf "
          "contains a reparse point.';",
        )
        ..writeln("    Exit;")
        ..writeln("  end;")
        ..writeln(
          "  if (not FileExists(HelperPath)) or "
          "(not FileExists(PolicyPath)) then",
        )
        ..writeln("  begin")
        ..writeln(
          "    Result := 'Desktop updater fresh protected helper pair "
          "is incomplete.';",
        )
        ..writeln("    Exit;")
        ..writeln("  end;")
        ..writeln(
          "  if CompareText(GetSHA256OfFile(HelperPath), "
          "'{#DesktopUpdaterExpectedHelperSha256}') <> 0 then",
        )
        ..writeln("  begin")
        ..writeln(
          "    Result := 'Desktop updater fresh protected helper digest "
          "does not match.';",
        )
        ..writeln("    Exit;")
        ..writeln("  end;")
        ..writeln(
          "  if CompareText(GetSHA256OfFile(PolicyPath), "
          "'{#DesktopUpdaterExpectedPolicySha256}') <> 0 then",
        )
        ..writeln(
          "    Result := 'Desktop updater fresh protected helper policy "
          "digest does not match.';",
        )
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure PromoteDesktopUpdaterFreshLeaf;")
        ..writeln("var")
        ..writeln("  FinalDir: String;")
        ..writeln("begin")
        ..writeln(
          "  FinalDir := ExpandFileName("
          "ExpandConstant('{#DesktopUpdaterProtectedHelperDir}'));",
        )
        ..writeln(
          "  DesktopUpdaterHadLegacyLeaf := FileOrDirExists(FinalDir);",
        )
        ..writeln("  if FileOrDirExists(FinalDir) then")
        ..writeln("  begin")
        ..writeln(
          "    if FileOrDirExists(DesktopUpdaterQuarantinePath) then",
        )
        ..writeln(
          "      RaiseException('Desktop updater quarantine path was "
          "claimed before promotion.');",
        )
        ..writeln(
          "    if not RenameFile(FinalDir, "
          "DesktopUpdaterQuarantinePath) then",
        )
        ..writeln(
          "      RaiseException('Desktop updater legacy helper leaf "
          "could not be quarantined.');",
        )
        ..writeln("  end;")
        ..writeln(
          "  if not RenameFile(DesktopUpdaterProvisioningPath, FinalDir) "
          "then",
        )
        ..writeln("  begin")
        ..writeln("    if DesktopUpdaterHadLegacyLeaf then")
        ..writeln(
          "      if not RenameFile(DesktopUpdaterQuarantinePath, "
          "FinalDir) then",
        )
        ..writeln(
          "        RaiseException('Desktop updater fresh promotion and "
          "legacy rollback both failed.');",
        )
        ..writeln(
          "    RaiseException('Desktop updater fresh protected helper "
          "promotion failed.');",
        )
        ..writeln("  end;")
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure QuarantineDesktopUpdaterFailedPromotion;")
        ..writeln("var")
        ..writeln("  FinalDir: String;")
        ..writeln("begin")
        ..writeln(
          "  FinalDir := ExpandFileName("
          "ExpandConstant('{#DesktopUpdaterProtectedHelperDir}'));",
        )
        ..writeln("  if FileOrDirExists(FinalDir) then")
        ..writeln(
          "    if not RenameFile(FinalDir, "
          "DesktopUpdaterFailedPromotionPath) then",
        )
        ..writeln(
          "      RaiseException('Desktop updater failed fresh leaf "
          "could not be quarantined.');",
        )
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure RegisterDesktopUpdaterProtectedEndpoint;")
        ..writeln("var")
        ..writeln("  FinalDir: String;")
        ..writeln("  FreshHelperPath: String;")
        ..writeln("  FreshLeafError: String;")
        ..writeln("  ResultCode: Integer;")
        ..writeln("begin")
        ..writeln(
          "  FinalDir := ExpandFileName("
          "ExpandConstant('{#DesktopUpdaterProtectedHelperDir}'));",
        )
        ..writeln(
          "  FreshHelperPath := AddBackslash(FinalDir) + "
          "'desktop_updater_install_helper.exe';",
        )
        ..writeln(
          "  FreshLeafError := DesktopUpdaterFreshLeafError(FinalDir);",
        )
        ..writeln("  if FreshLeafError <> '' then")
        ..writeln("  begin")
        ..writeln("    QuarantineDesktopUpdaterFailedPromotion;")
        ..writeln("    RaiseException(FreshLeafError);")
        ..writeln("  end;")
        ..writeln("  ResultCode := -1;")
        ..writeln(
          "  if (not Exec(FreshHelperPath, '--validate-endpoint', FinalDir, "
          "SW_HIDE, ewWaitUntilTerminated, ResultCode)) or "
          "(ResultCode <> 0) then",
        )
        ..writeln("  begin")
        ..writeln("    QuarantineDesktopUpdaterFailedPromotion;")
        ..writeln(
          "    FailDesktopUpdaterProvisioning('fresh endpoint validation', "
          "ResultCode);",
        )
        ..writeln("  end;")
        ..writeln("  ResultCode := -1;")
        ..writeln(
          "  if (not Exec(FreshHelperPath, '--register-endpoint', FinalDir, "
          "SW_HIDE, ewWaitUntilTerminated, ResultCode)) or "
          "(ResultCode <> 0) then",
        )
        ..writeln("  begin")
        ..writeln(
          "    Log('Desktop updater registration retry remains bound to "
          "the fresh protected leaf.');",
        )
        ..writeln(
          "    FailDesktopUpdaterProvisioning('endpoint registration', "
          "ResultCode);",
        )
        ..writeln("  end;")
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure InstallDesktopUpdaterProtectedEndpoint;")
        ..writeln("var")
        ..writeln("  FreshLeafError: String;")
        ..writeln("begin")
        ..writeln(
          "  FreshLeafError := DesktopUpdaterFreshLeafError("
          "DesktopUpdaterProvisioningPath);",
        )
        ..writeln("  if FreshLeafError <> '' then")
        ..writeln("    RaiseException(FreshLeafError);")
        ..writeln("  PromoteDesktopUpdaterFreshLeaf;")
        ..writeln("  RegisterDesktopUpdaterProtectedEndpoint;")
        ..writeln("end;")
        ..writeln()
        ..writeln("procedure CurStepChanged(CurStep: TSetupStep);")
        ..writeln("begin")
        ..writeln("  if CurStep = ssPostInstall then")
        ..writeln("    InstallDesktopUpdaterProtectedEndpoint;")
        ..writeln("end;");
    }

    return buffer.toString();
  }
}

String _escapeDefine(String value) {
  return value.replaceAll("\\", "\\\\").replaceAll('"', r'\"');
}

String _escapeInnoString(String value) {
  return value.replaceAll('"', '""');
}

String _escapeInnoValue(String value) {
  return value.replaceAll("}", "");
}

void _requireSha256(String? value, String label) {
  if (value == null || !RegExp(r"^[0-9a-f]{64}$").hasMatch(value)) {
    throw FormatException("$label SHA-256 must be 64 lowercase hex digits.");
  }
}
