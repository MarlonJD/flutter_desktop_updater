/// Localization for the update card texts.
/// Fields that can be localized:
///
/// - updateAvailableText
/// - newVersionAvailableText
/// - newVersionLongText
/// - restartText
/// - restartWarningText
/// - warningCancelText
/// - warningConfirmText
/// - upToDateTitleText
/// - upToDateText
/// - updateCheckFailedTitleText
/// - updateCheckFailedText
/// - okText
/// - onUpdateFailedTooltip
/// - releaseNotesTitleText
/// - releaseNotesTypeLabels
/// - releaseNotesErrorText
/// - releaseNotesRetryText
/// - releaseNotesEmptyText
class DesktopUpdateLocalization {
  /// constructor
  const DesktopUpdateLocalization({
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
    this.releaseNotesTitleText,
    this.releaseNotesTypeLabels,
    this.releaseNotesErrorText,
    this.releaseNotesRetryText,
    this.releaseNotesEmptyText,
  });

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
  /// error icon. Return `null` to fall through to [releaseNotesErrorText].
  ///
  /// To return a single static string for all error cases:
  /// ```dart
  /// onUpdateFailedTooltip: (_) => "Update failed. Please contact support.",
  /// ```
  ///
  /// To return specific messages per error type:
  /// ```dart
  /// onUpdateFailedTooltip: (error) {
  ///   if (error is SocketException) return "No internet connection.";
  ///   if (error is TimeoutException) return "Connection timed out.";
  ///   return null; // fall through to releaseNotesErrorText
  /// },
  /// ```
  final String? Function(Object error)? onUpdateFailedTooltip;

  /// Title of the release notes bottom sheet.
  ///
  /// Default: "What's new"
  final String? releaseNotesTitleText;

  /// Section header labels for release note type groups.
  ///
  /// Keys: "feat", "fix", "other".
  /// Merges with the built-in English defaults at render time; only supply
  /// the keys you want to override.
  ///
  /// Built-in defaults:
  /// - "feat"  → "New features"
  /// - "fix"   → "Bug fixes"
  /// - "other" → "Other changes"
  final Map<String, String>? releaseNotesTypeLabels;

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

String? getLocalizedString(String? key, List<dynamic> args) {
  for (var i = 0; i < args.length; i++) {
    key = key?.replaceFirst("{}", args[i].toString());
  }
  return key;
}
