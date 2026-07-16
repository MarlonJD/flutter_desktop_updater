import "package:path/path.dart" as path;

class WindowsPublishConfig {
  const WindowsPublishConfig({
    this.installer = const InnoPublishConfig.disabled(),
  });

  final InnoPublishConfig installer;
}

class InnoPublishConfig {
  const InnoPublishConfig({
    required this.kind,
    required this.mode,
    this.script,
    this.isccPath,
    this.outputBaseName,
    this.appId,
    this.publisher,
    this.publisherUrl,
    this.supportUrl,
    this.updatesUrl,
    this.privilegesRequired = "lowest",
    this.protectedHelperInstallDir,
    this.architecturesAllowed = "x64",
    this.architecturesInstallIn64BitMode = "x64",
    this.setupIcon,
    this.licenseFile,
    this.silentArgs = const ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
    this.requiresElevation = "auto",
    this.authenticodeThumbprints = const [],
  });

  const InnoPublishConfig.disabled()
      : kind = "",
        mode = "disabled",
        script = null,
        isccPath = null,
        outputBaseName = null,
        appId = null,
        publisher = null,
        publisherUrl = null,
        supportUrl = null,
        updatesUrl = null,
        privilegesRequired = "lowest",
        protectedHelperInstallDir = null,
        architecturesAllowed = "x64",
        architecturesInstallIn64BitMode = "x64",
        setupIcon = null,
        licenseFile = null,
        silentArgs = const ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        requiresElevation = "auto",
        authenticodeThumbprints = const [];

  final String kind;
  final String mode;
  final String? script;
  final String? isccPath;
  final String? outputBaseName;
  final String? appId;
  final String? publisher;
  final String? publisherUrl;
  final String? supportUrl;
  final String? updatesUrl;
  final String privilegesRequired;
  final String? protectedHelperInstallDir;
  final String architecturesAllowed;
  final String architecturesInstallIn64BitMode;
  final String? setupIcon;
  final String? licenseFile;
  final List<String> silentArgs;
  final String requiresElevation;
  final List<String> authenticodeThumbprints;

  bool get enabled => kind == "inno";
}

String? resolveGeneratedProtectedHelperInstallDir(InnoPublishConfig config) {
  final value = config.protectedHelperInstallDir?.trim();
  if (config.mode != "generated" || config.privilegesRequired != "admin") {
    if (value != null && value.isNotEmpty) {
      throw const FormatException(
        "windows.installer.protectedHelperInstallDir is only valid for a "
        "generated administrative installer.",
      );
    }
    return null;
  }
  if (value == null || value.isEmpty) {
    throw const FormatException(
      "windows.installer.protectedHelperInstallDir is required for a "
      "generated administrative installer.",
    );
  }
  if (!_isAbsoluteLocalWindowsDirectory(value)) {
    throw const FormatException(
      "windows.installer.protectedHelperInstallDir must be an absolute "
      "local Windows directory.",
    );
  }
  final normalized = path.windows.normalize(value);
  if (!_isDedicatedGenerationHelperDirectory(normalized)) {
    throw const FormatException(
      "windows.installer.protectedHelperInstallDir must use the dedicated "
      r"<drive>:\Program Files\DesktopUpdaterHelperGenerationV1--"
      r"<package-id>--<release> "
      "layout.",
    );
  }
  return normalized;
}

bool _isAbsoluteLocalWindowsDirectory(String value) {
  if (!RegExp(r"^[A-Za-z]:[\\/]").hasMatch(value) ||
      value.substring(2).contains(":") ||
      value.contains(RegExp(r'''["'<>|?*\r\n]''')) ||
      value.contains("{") ||
      value.contains("}") ||
      value.contains("%")) {
    return false;
  }
  final normalized = path.windows.normalize(value);
  if (normalized.length <= 3) {
    return false;
  }
  return !path.windows.split(value).contains("..");
}

bool _isDedicatedGenerationHelperDirectory(String value) {
  final parts = path.windows.split(value);
  if (parts.length != 3 || parts[1].toLowerCase() != "program files") {
    return false;
  }
  final generationLeaf = RegExp(
    r"^DesktopUpdaterHelperGenerationV1--"
    r"[A-Za-z0-9][A-Za-z0-9._+-]{0,126}--"
    r"[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$",
    caseSensitive: false,
  );
  return parts[2].length <= 255 && generationLeaf.hasMatch(parts[2]);
}

void validateGeneratedProtectedHelperInstallDirBinding({
  required String installDir,
  required String packageId,
  required String version,
}) {
  final parts = path.windows.split(path.windows.normalize(installDir));
  final expectedLeaf = "DesktopUpdaterHelperGenerationV1--$packageId--$version";
  if (parts.length != 3 ||
      parts[2].toLowerCase() != expectedLeaf.toLowerCase()) {
    throw const FormatException(
      "windows.installer.protectedHelperInstallDir must use the exact "
      "security-epoch generation leaf for its package and release.",
    );
  }
}
