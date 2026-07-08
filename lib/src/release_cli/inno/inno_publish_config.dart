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
  final String architecturesAllowed;
  final String architecturesInstallIn64BitMode;
  final String? setupIcon;
  final String? licenseFile;
  final List<String> silentArgs;
  final String requiresElevation;
  final List<String> authenticodeThumbprints;

  bool get enabled => kind == "inno";
}
