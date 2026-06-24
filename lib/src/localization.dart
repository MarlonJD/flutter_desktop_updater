import "dart:convert";
import "dart:ui" show Locale, PlatformDispatcher, TextDirection;

import "package:flutter/services.dart";
import "package:flutter/widgets.dart";

/// Resolves a desktop updater localization key into an app-owned translation.
typedef DesktopUpdateTextResolver = String? Function(
  DesktopUpdateLocalizationKey key,
  String fallback,
);

/// Stable string keys used by resolver-based localization.
enum DesktopUpdateLocalizationKey {
  /// Text displayed when an update is available.
  updateAvailableText,

  /// Text displayed with the available version information.
  newVersionAvailableText,

  /// Long description displayed before downloading an update.
  newVersionLongText,

  /// Text displayed on the restart update button.
  restartText,

  /// Title displayed in the restart confirmation dialog.
  warningTitleText,

  /// Warning message displayed before restarting.
  restartWarningText,

  /// Text displayed for cancelling a restart.
  warningCancelText,

  /// Text displayed for confirming a restart.
  warningConfirmText,

  /// Text displayed for skipping the current version.
  skipThisVersionText,

  /// Text displayed on the download button.
  downloadText,

  /// Title displayed when the application is up to date.
  upToDateTitleText,

  /// Message displayed when no update is available.
  upToDateText,

  /// Title displayed when checking for updates fails.
  updateCheckFailedTitleText,

  /// Message displayed when the update check fails.
  updateCheckFailedText,

  /// Generic confirmation button text.
  okText,

  /// Tooltip text displayed when an update fails.
  updateFailedTooltipText,

  /// Tooltip text for the release notes button.
  releaseNotesButtonTooltipText,

  /// Title displayed for release notes.
  releaseNotesTitleText,

  /// Error message displayed when release notes cannot be loaded.
  releaseNotesErrorText,

  /// Text displayed for retrying release notes loading.
  releaseNotesRetryText,

  /// Message displayed when no release notes exist.
  releaseNotesEmptyText,

  /// Release notes label for feature entries.
  releaseNotesTypeFeatLabel,

  /// Release notes label for fix entries.
  releaseNotesTypeFixLabel,

  /// Release notes label for uncategorized entries.
  releaseNotesTypeOtherLabel,

  /// Release notes section label for feature entries.
  releaseNotesSectionFeaturesLabel,

  /// Release notes section label for fix entries.
  releaseNotesSectionFixesLabel,

  /// Release notes section label for security entries.
  releaseNotesSectionSecurityLabel,

  /// Release notes section label for breaking-change entries.
  releaseNotesSectionBreakingLabel,

  /// Release notes section label for uncategorized entries.
  releaseNotesSectionOtherLabel,
}

/// Localization for the update card texts.
///
/// The class remains a `const`, immutable override object. Apps can continue
/// passing individual string overrides directly, load bundled JSON via
/// [DesktopUpdateLocalizationLoader], or use
/// [DesktopUpdateLocalization.resolvedBy] to connect their own i18n resolver.
class DesktopUpdateLocalization {
  /// Creates a localization override object for ready-made updater UI.
  const DesktopUpdateLocalization({
    this.textDirection,
    this.updateAvailableText,
    this.newVersionAvailableText,
    this.newVersionLongText,
    this.restartText,
    this.warningTitleText,
    this.restartWarningText,
    this.warningCancelText,
    this.warningConfirmText,
    this.skipThisVersionText,
    this.downloadText,
    this.upToDateTitleText,
    this.upToDateText,
    this.updateCheckFailedTitleText,
    this.updateCheckFailedText,
    this.okText,
    this.onUpdateFailedTooltip,
    this.updateFailedTooltipText,
    this.releaseNotesButtonTooltipText,
    this.releaseNotesTitleText,
    this.releaseNotesTypeLabels,
    this.releaseNotesSectionLabels,
    this.releaseNotesErrorText,
    this.releaseNotesRetryText,
    this.releaseNotesEmptyText,
  });

  /// Creates a localization object from an app-owned translation resolver.
  ///
  /// The resolver receives a stable key and the built-in English fallback.
  /// Returning `null` keeps the fallback.
  factory DesktopUpdateLocalization.resolvedBy({
    required DesktopUpdateTextResolver translate,
    TextDirection? textDirection,
    String? Function(Object error)? onUpdateFailedTooltip,
  }) {
    const defaults = defaultDesktopUpdateLocalization;
    final typeLabels = defaults.releaseNotesTypeLabels!;
    final sectionLabels = defaults.releaseNotesSectionLabels!;

    return DesktopUpdateLocalization(
      textDirection: textDirection ?? defaults.textDirection,
      updateAvailableText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.updateAvailableText,
        defaults.updateAvailableText!,
      ),
      newVersionAvailableText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.newVersionAvailableText,
        defaults.newVersionAvailableText!,
      ),
      newVersionLongText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.newVersionLongText,
        defaults.newVersionLongText!,
      ),
      restartText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.restartText,
        defaults.restartText!,
      ),
      warningTitleText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.warningTitleText,
        defaults.warningTitleText!,
      ),
      restartWarningText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.restartWarningText,
        defaults.restartWarningText!,
      ),
      warningCancelText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.warningCancelText,
        defaults.warningCancelText!,
      ),
      warningConfirmText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.warningConfirmText,
        defaults.warningConfirmText!,
      ),
      skipThisVersionText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.skipThisVersionText,
        defaults.skipThisVersionText!,
      ),
      downloadText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.downloadText,
        defaults.downloadText!,
      ),
      upToDateTitleText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.upToDateTitleText,
        defaults.upToDateTitleText!,
      ),
      upToDateText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.upToDateText,
        defaults.upToDateText!,
      ),
      updateCheckFailedTitleText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.updateCheckFailedTitleText,
        defaults.updateCheckFailedTitleText!,
      ),
      updateCheckFailedText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.updateCheckFailedText,
        defaults.updateCheckFailedText!,
      ),
      okText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.okText,
        defaults.okText!,
      ),
      onUpdateFailedTooltip: onUpdateFailedTooltip,
      updateFailedTooltipText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.updateFailedTooltipText,
        defaults.updateFailedTooltipText!,
      ),
      releaseNotesButtonTooltipText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.releaseNotesButtonTooltipText,
        defaults.releaseNotesButtonTooltipText!,
      ),
      releaseNotesTitleText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.releaseNotesTitleText,
        defaults.releaseNotesTitleText!,
      ),
      releaseNotesTypeLabels: {
        "feat": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesTypeFeatLabel,
          typeLabels["feat"]!,
        ),
        "fix": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesTypeFixLabel,
          typeLabels["fix"]!,
        ),
        "other": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesTypeOtherLabel,
          typeLabels["other"]!,
        ),
      },
      releaseNotesSectionLabels: {
        "features": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesSectionFeaturesLabel,
          sectionLabels["features"]!,
        ),
        "fixes": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesSectionFixesLabel,
          sectionLabels["fixes"]!,
        ),
        "security": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesSectionSecurityLabel,
          sectionLabels["security"]!,
        ),
        "breaking": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesSectionBreakingLabel,
          sectionLabels["breaking"]!,
        ),
        "other": _resolveText(
          translate,
          DesktopUpdateLocalizationKey.releaseNotesSectionOtherLabel,
          sectionLabels["other"]!,
        ),
      },
      releaseNotesErrorText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.releaseNotesErrorText,
        defaults.releaseNotesErrorText!,
      ),
      releaseNotesRetryText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.releaseNotesRetryText,
        defaults.releaseNotesRetryText!,
      ),
      releaseNotesEmptyText: _resolveText(
        translate,
        DesktopUpdateLocalizationKey.releaseNotesEmptyText,
        defaults.releaseNotesEmptyText!,
      ),
    );
  }

  /// Optional text direction for ready-made updater UI.
  final TextDirection? textDirection;

  /// Default: "Update available"
  final String? updateAvailableText;

  /// Default: "{} {} is available"
  ///
  /// ie: Appname 1.0.1 is available
  final String? newVersionAvailableText;

  /// Default: "New version is ready to download, click the button below to start downloading. This will download {} MB of data."
  ///
  /// "New version is ready to download, click the button below to start downloading. This will download 35.34 MB of data."
  final String? newVersionLongText;

  /// Default: "Restart to update"
  final String? restartText;

  /// Default: "Are you sure?"
  final String? warningTitleText;

  /// Default: "A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?"
  final String? restartWarningText;

  /// Default: "Not now"
  final String? warningCancelText;

  /// Default: "Restart"
  final String? warningConfirmText;

  /// Default: "Skip this version"
  final String? skipThisVersionText;

  /// Default: "Download"
  final String? downloadText;

  /// Default: "Application is up to date"
  final String? upToDateTitleText;

  /// Default: "{} is the latest available version."
  final String? upToDateText;

  /// Default: "Could not check for updates"
  final String? updateCheckFailedTitleText;

  /// Default: "Please try again later."
  final String? updateCheckFailedText;

  /// Default: "OK"
  final String? okText;

  /// Called with the raw update error to produce a tooltip string for the
  /// error icon. Return `null` to fall through to [updateFailedTooltipText].
  final String? Function(Object error)? onUpdateFailedTooltip;

  /// Fallback tooltip shown for the update error icon.
  ///
  /// Default: "Update failed. Please try again."
  final String? updateFailedTooltipText;

  /// Tooltip for the ready-made release notes icon.
  ///
  /// Default: "Release notes"
  final String? releaseNotesButtonTooltipText;

  /// Title of the release notes bottom sheet.
  ///
  /// Default: "What's new"
  final String? releaseNotesTitleText;

  /// Section header labels for release note type groups.
  ///
  /// Keys: "feat", "fix", "other".
  final Map<String, String>? releaseNotesTypeLabels;

  /// Section header labels for rich release note sections.
  ///
  /// Keys: "features", "fixes", "security", "breaking", "other".
  final Map<String, String>? releaseNotesSectionLabels;

  /// Error message shown in the release notes bottom sheet when the fetch fails.
  ///
  /// Default: "Could not load release notes."
  final String? releaseNotesErrorText;

  /// Label for the retry button in the release notes error state.
  ///
  /// Default: "Try again"
  final String? releaseNotesRetryText;

  /// Message shown when the release notes list is empty.
  ///
  /// Default: "No release notes available."
  final String? releaseNotesEmptyText;
}

/// Built-in English localization values used as the canonical fallback.
const defaultDesktopUpdateLocalization = DesktopUpdateLocalization(
  textDirection: TextDirection.ltr,
  updateAvailableText: "Update available",
  newVersionAvailableText: "{} {} is available",
  newVersionLongText:
      "New version is ready to download, click the button below to start "
      "downloading. This will download {} MB of data.",
  restartText: "Restart to update",
  warningTitleText: "Are you sure?",
  restartWarningText:
      "A restart is required to complete the update installation.\n"
      "Any unsaved changes will be lost. Would you like to restart now?",
  warningCancelText: "Not now",
  warningConfirmText: "Restart",
  skipThisVersionText: "Skip this version",
  downloadText: "Download",
  upToDateTitleText: "Application is up to date",
  upToDateText: "{} is the latest available version.",
  updateCheckFailedTitleText: "Could not check for updates",
  updateCheckFailedText: "Please try again later.",
  okText: "OK",
  updateFailedTooltipText: "Update failed. Please try again.",
  releaseNotesButtonTooltipText: "Release notes",
  releaseNotesTitleText: "What's new",
  releaseNotesTypeLabels: {
    "feat": "New features",
    "fix": "Bug fixes",
    "other": "Other changes",
  },
  releaseNotesSectionLabels: {
    "features": "Features",
    "fixes": "Fixes",
    "security": "Security",
    "breaking": "Breaking changes",
    "other": "Other changes",
  },
  releaseNotesErrorText: "Could not load release notes.",
  releaseNotesRetryText: "Try again",
  releaseNotesEmptyText: "No release notes available.",
);

/// Loads desktop updater localization from bundled or app-owned JSON assets.
class DesktopUpdateLocalizationLoader {
  /// Creates a loader backed by [bundle].
  DesktopUpdateLocalizationLoader({AssetBundle? bundle})
      : bundle = bundle ?? rootBundle;

  /// Asset bundle used to read localization JSON.
  final AssetBundle bundle;

  /// Loads a bundled package locale from `assets/localizations/<locale>.json`.
  static Future<DesktopUpdateLocalization> fromBundledLocale(
    Object locale, {
    DesktopUpdateLocalization overrides = const DesktopUpdateLocalization(),
    AssetBundle? bundle,
  }) {
    return DesktopUpdateLocalizationLoader(bundle: bundle).loadBundledLocale(
      locale,
      overrides: overrides,
    );
  }

  /// Loads a bundled package locale matching [Localizations.localeOf].
  static Future<DesktopUpdateLocalization> fromContext(
    BuildContext context, {
    DesktopUpdateLocalization overrides = const DesktopUpdateLocalization(),
    AssetBundle? bundle,
  }) {
    return fromBundledLocale(
      Localizations.localeOf(context),
      overrides: overrides,
      bundle: bundle,
    );
  }

  /// Loads a bundled package locale matching the platform dispatcher locale.
  static Future<DesktopUpdateLocalization> fromPlatformLocale({
    DesktopUpdateLocalization overrides = const DesktopUpdateLocalization(),
    AssetBundle? bundle,
  }) {
    return fromBundledLocale(
      PlatformDispatcher.instance.locale,
      overrides: overrides,
      bundle: bundle,
    );
  }

  /// Loads an app-owned or package-owned JSON asset.
  static Future<DesktopUpdateLocalization> fromAsset(
    String assetPath, {
    String? package,
    DesktopUpdateLocalization overrides = const DesktopUpdateLocalization(),
    AssetBundle? bundle,
  }) {
    return DesktopUpdateLocalizationLoader(bundle: bundle).loadAsset(
      assetPath,
      package: package,
      overrides: overrides,
    );
  }

  /// Loads a bundled package locale from `assets/localizations/<locale>.json`.
  Future<DesktopUpdateLocalization> loadBundledLocale(
    Object locale, {
    DesktopUpdateLocalization overrides = const DesktopUpdateLocalization(),
  }) async {
    final candidates = _localeCandidates(locale);
    for (final tag in candidates) {
      final loaded = await _loadAsset(
        "assets/localizations/$tag.json",
        package: "desktop_updater",
      );
      if (loaded != null) {
        return mergeDesktopUpdateLocalizations(
          mergeDesktopUpdateLocalizations(
            defaultDesktopUpdateLocalization,
            loaded,
          ),
          overrides,
        );
      }
    }

    return mergeDesktopUpdateLocalizations(
      defaultDesktopUpdateLocalization,
      overrides,
    );
  }

  /// Loads an app-owned or package-owned JSON asset.
  Future<DesktopUpdateLocalization> loadAsset(
    String assetPath, {
    String? package,
    DesktopUpdateLocalization overrides = const DesktopUpdateLocalization(),
  }) async {
    final loaded = await _loadAsset(assetPath, package: package);

    return mergeDesktopUpdateLocalizations(
      mergeDesktopUpdateLocalizations(
        defaultDesktopUpdateLocalization,
        loaded ?? const DesktopUpdateLocalization(),
      ),
      overrides,
    );
  }

  Future<DesktopUpdateLocalization?> _loadAsset(
    String assetPath, {
    String? package,
  }) async {
    final resolvedPath =
        package == null ? assetPath : "packages/$package/$assetPath";
    try {
      final raw = await bundle.loadString(resolvedPath);
      return parseDesktopUpdateLocalizationJson(raw);
    } on FlutterError {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Parses a localization JSON string into a localization override object.
DesktopUpdateLocalization parseDesktopUpdateLocalizationJson(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException("Localization JSON root must be an object.");
  }
  return desktopUpdateLocalizationFromJson(decoded);
}

/// Converts a decoded localization JSON object into localization overrides.
DesktopUpdateLocalization desktopUpdateLocalizationFromJson(
  Map<String, Object?> raw,
) {
  final strings = switch (raw["strings"]) {
    final Map<String, Object?> value => value,
    _ => const <String, Object?>{},
  };
  final locale = _readString(raw, "locale");

  return DesktopUpdateLocalization(
    textDirection: _readTextDirection(raw["textDirection"]) ??
        _inferTextDirectionFromLocaleTag(locale),
    updateAvailableText: _readString(strings, "updateAvailableText"),
    newVersionAvailableText: _readString(strings, "newVersionAvailableText"),
    newVersionLongText: _readString(strings, "newVersionLongText"),
    restartText: _readString(strings, "restartText"),
    warningTitleText: _readString(strings, "warningTitleText"),
    restartWarningText: _readString(strings, "restartWarningText"),
    warningCancelText: _readString(strings, "warningCancelText"),
    warningConfirmText: _readString(strings, "warningConfirmText"),
    skipThisVersionText: _readString(strings, "skipThisVersionText"),
    downloadText: _readString(strings, "downloadText"),
    upToDateTitleText: _readString(strings, "upToDateTitleText"),
    upToDateText: _readString(strings, "upToDateText"),
    updateCheckFailedTitleText:
        _readString(strings, "updateCheckFailedTitleText"),
    updateCheckFailedText: _readString(strings, "updateCheckFailedText"),
    okText: _readString(strings, "okText"),
    updateFailedTooltipText: _readString(strings, "updateFailedTooltipText"),
    releaseNotesButtonTooltipText:
        _readString(strings, "releaseNotesButtonTooltipText"),
    releaseNotesTitleText: _readString(strings, "releaseNotesTitleText"),
    releaseNotesTypeLabels: _readStringMap(
      strings,
      "releaseNotesTypeLabels",
    ),
    releaseNotesSectionLabels: _readStringMap(
      strings,
      "releaseNotesSectionLabels",
    ),
    releaseNotesErrorText: _readString(strings, "releaseNotesErrorText"),
    releaseNotesRetryText: _readString(strings, "releaseNotesRetryText"),
    releaseNotesEmptyText: _readString(strings, "releaseNotesEmptyText"),
  );
}

/// Returns a merged localization where [overrides] wins over [base].
DesktopUpdateLocalization mergeDesktopUpdateLocalizations(
  DesktopUpdateLocalization base,
  DesktopUpdateLocalization overrides,
) {
  return DesktopUpdateLocalization(
    textDirection: overrides.textDirection ?? base.textDirection,
    updateAvailableText:
        overrides.updateAvailableText ?? base.updateAvailableText,
    newVersionAvailableText:
        overrides.newVersionAvailableText ?? base.newVersionAvailableText,
    newVersionLongText: overrides.newVersionLongText ?? base.newVersionLongText,
    restartText: overrides.restartText ?? base.restartText,
    warningTitleText: overrides.warningTitleText ?? base.warningTitleText,
    restartWarningText: overrides.restartWarningText ?? base.restartWarningText,
    warningCancelText: overrides.warningCancelText ?? base.warningCancelText,
    warningConfirmText: overrides.warningConfirmText ?? base.warningConfirmText,
    skipThisVersionText:
        overrides.skipThisVersionText ?? base.skipThisVersionText,
    downloadText: overrides.downloadText ?? base.downloadText,
    upToDateTitleText: overrides.upToDateTitleText ?? base.upToDateTitleText,
    upToDateText: overrides.upToDateText ?? base.upToDateText,
    updateCheckFailedTitleText:
        overrides.updateCheckFailedTitleText ?? base.updateCheckFailedTitleText,
    updateCheckFailedText:
        overrides.updateCheckFailedText ?? base.updateCheckFailedText,
    okText: overrides.okText ?? base.okText,
    onUpdateFailedTooltip:
        overrides.onUpdateFailedTooltip ?? base.onUpdateFailedTooltip,
    updateFailedTooltipText:
        overrides.updateFailedTooltipText ?? base.updateFailedTooltipText,
    releaseNotesButtonTooltipText: overrides.releaseNotesButtonTooltipText ??
        base.releaseNotesButtonTooltipText,
    releaseNotesTitleText:
        overrides.releaseNotesTitleText ?? base.releaseNotesTitleText,
    releaseNotesTypeLabels: _mergeMaps(
      base.releaseNotesTypeLabels,
      overrides.releaseNotesTypeLabels,
    ),
    releaseNotesSectionLabels: _mergeMaps(
      base.releaseNotesSectionLabels,
      overrides.releaseNotesSectionLabels,
    ),
    releaseNotesErrorText:
        overrides.releaseNotesErrorText ?? base.releaseNotesErrorText,
    releaseNotesRetryText:
        overrides.releaseNotesRetryText ?? base.releaseNotesRetryText,
    releaseNotesEmptyText:
        overrides.releaseNotesEmptyText ?? base.releaseNotesEmptyText,
  );
}

/// Replaces `{}` placeholders in [key] with the provided [args].
String? getLocalizedString(String? key, List<dynamic> args) {
  for (var i = 0; i < args.length; i++) {
    key = key?.replaceFirst("{}", args[i].toString());
  }
  return key;
}

String _resolveText(
  DesktopUpdateTextResolver resolver,
  DesktopUpdateLocalizationKey key,
  String fallback,
) {
  return resolver(key, fallback) ?? fallback;
}

List<String> _localeCandidates(Object locale) {
  final tag = _localeTag(locale);
  final normalized = tag.replaceAll("_", "-");
  final language = normalized.split("-").first;
  final candidates = <String>[
    if (normalized.isNotEmpty) normalized,
    if (language.isNotEmpty && language != normalized) language,
    "en",
  ];

  return candidates.toSet().toList();
}

String _localeTag(Object locale) {
  return switch (locale) {
    Locale(:final languageCode, :final scriptCode, :final countryCode) => [
        languageCode,
        if (scriptCode != null && scriptCode.isNotEmpty) scriptCode,
        if (countryCode != null && countryCode.isNotEmpty) countryCode,
      ].join("-"),
    _ => locale.toString(),
  };
}

TextDirection? _inferTextDirectionFromLocaleTag(String? tag) {
  if (tag == null || tag.isEmpty) {
    return null;
  }
  final parts = tag.replaceAll("_", "-").split("-");
  final language = parts.first.toLowerCase();
  final script = parts.length > 1 ? parts[1].toLowerCase() : null;

  if (script == "arab" || script == "hebr") {
    return TextDirection.rtl;
  }
  if (script == "latn" || script == "cyrl" || script == "hans") {
    return TextDirection.ltr;
  }
  if (script == "hant") {
    return TextDirection.ltr;
  }

  const rtlLanguageCodes = {
    "ar",
    "arc",
    "ckb",
    "dv",
    "fa",
    "he",
    "iw",
    "ks",
    "ku",
    "ps",
    "sd",
    "ug",
    "ur",
    "yi",
  };

  return rtlLanguageCodes.contains(language)
      ? TextDirection.rtl
      : TextDirection.ltr;
}

TextDirection? _readTextDirection(Object? value) {
  return switch (value) {
    "ltr" => TextDirection.ltr,
    "rtl" => TextDirection.rtl,
    _ => null,
  };
}

String? _readString(Map<String, Object?> raw, String key) {
  return switch (raw[key]) {
    final String value => value,
    _ => null,
  };
}

Map<String, String>? _readStringMap(Map<String, Object?> raw, String key) {
  final value = raw[key];
  if (value is! Map<String, Object?>) {
    return null;
  }
  return {
    for (final entry in value.entries)
      if (entry.value is String) entry.key: entry.value! as String,
  };
}

Map<String, String>? _mergeMaps(
  Map<String, String>? base,
  Map<String, String>? overrides,
) {
  if (base == null) {
    return overrides;
  }
  if (overrides == null) {
    return base;
  }
  return {...base, ...overrides};
}
