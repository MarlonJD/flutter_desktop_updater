/// macOS app install-location category.
enum MacOSInstallLocationKind {
  /// App is already installed in `/Applications` or `~/Applications`.
  installed,

  /// App is running from a mounted disk image volume.
  diskImage,

  /// App is running from the user's Downloads directory.
  downloads,

  /// App is running from another movable location.
  other,

  /// Install-location checks are unavailable on this platform.
  unsupported,
}

/// Native macOS install-location status.
class MacOSInstallLocationStatus {
  /// Creates install-location status.
  const MacOSInstallLocationStatus({
    required this.kind,
    required this.bundlePath,
    required this.targetPath,
  });

  /// Parses status returned by the native helper.
  factory MacOSInstallLocationStatus.fromJson(Map<String, Object?> json) {
    return MacOSInstallLocationStatus(
      kind: MacOSInstallLocationKind.values.byName(json["kind"] as String),
      bundlePath: json["bundlePath"] as String?,
      targetPath: json["targetPath"] as String?,
    );
  }

  /// Install-location category.
  final MacOSInstallLocationKind kind;

  /// Current app bundle path, when known.
  final String? bundlePath;

  /// Preferred `/Applications/<App>.app` target path, when known.
  final String? targetPath;

  /// Whether an app may reasonably offer the Move to Applications prompt.
  bool get shouldOfferMovePrompt {
    return kind == MacOSInstallLocationKind.diskImage ||
        kind == MacOSInstallLocationKind.downloads ||
        kind == MacOSInstallLocationKind.other;
  }
}

/// Classifies a macOS `.app` bundle path for move-prompt policy.
MacOSInstallLocationKind classifyMacOSInstallLocation(String? bundlePath) {
  final path = bundlePath?.trim();
  if (path == null || path.isEmpty) {
    return MacOSInstallLocationKind.unsupported;
  }
  if (path.startsWith("/Applications/") ||
      RegExp(r"^/Users/[^/]+/Applications/").hasMatch(path)) {
    return MacOSInstallLocationKind.installed;
  }
  if (path.startsWith("/Volumes/")) {
    return MacOSInstallLocationKind.diskImage;
  }
  if (RegExp(r"^/Users/[^/]+/Downloads/").hasMatch(path)) {
    return MacOSInstallLocationKind.downloads;
  }
  return MacOSInstallLocationKind.other;
}
