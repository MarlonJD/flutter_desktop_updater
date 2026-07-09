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

    final buffer = StringBuffer()
      ..writeln('#define MyAppName "${_escapeDefine(appName)}"')
      ..writeln('#define MyAppVersion "${_escapeDefine(metadata.version)}"')
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

    buffer
      ..writeln()
      ..writeln("[Files]")
      ..writeln(
        'Source: "$escapedInput\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs',
      )
      ..writeln()
      ..writeln("[Icons]")
      ..writeln(
        'Name: "{autoprograms}\\$appName"; Filename: "{app}\\$executableName"',
      )
      ..writeln()
      ..writeln("[Run]")
      ..writeln(
        'Filename: "{app}\\$executableName"; Description: "{cm:LaunchProgram,$appName}"; Flags: nowait postinstall skipifsilent',
      );

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
