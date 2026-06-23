import "dart:convert";

import 'package:flutter/services.dart';

/// Provides localized strings for the desktop update card.
///
/// The localization can be loaded from a JSON file located at
/// `langs/<language>.json`.
///
/// Supported localized fields include update messages, restart prompts,
/// release notes labels, and error messages.
class DesktopUpdateLocalization {
  /// Creates a desktop update localization instance.
  ///
  /// If a value is not provided, the default English text is used.
  DesktopUpdateLocalization({
    String? lang,
    String? updateAvailableText,
    String? newVersionAvailableText,
    String? newVersionLongText,
    String? restartText,
    String? warningTitleText,
    String? restartWarningText,
    String? warningCancelText,
    String? warningConfirmText,
    String? skipThisVersionText,
    String? downloadText,
    String? upToDateTitleText,
    String? upToDateText,
    String? updateCheckFailedTitleText,
    String? updateCheckFailedText,
    String? okText,
    this.onUpdateFailedTooltip,
    String? updateFailedTooltipText,
    String? releaseNotesButtonTooltipText,
    String? releaseNotesTitleText,
    Map<String, String>? releaseNotesTypeLabels,
    Map<String, String>? releaseNotesSectionLabels,
    String? releaseNotesErrorText,
    String? releaseNotesRetryText,
    String? releaseNotesEmptyText,
  }) {
    this.lang = lang ?? defaultLang;
    this.updateAvailableText = updateAvailableText ?? "Update available";
    this.newVersionAvailableText =
        newVersionAvailableText ?? "{} {} is available";
    this.newVersionLongText = newVersionLongText ??
        "New version is ready to download, click the button below to start downloading. This will download {} MB of data.";
    this.restartText = restartText ?? "Restart to update";
    this.warningTitleText = warningTitleText ?? "Are you sure?";
    this.restartWarningText = restartWarningText ??
        "A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?";
    this.warningCancelText = warningCancelText ?? "Not now";
    this.warningConfirmText = warningConfirmText ?? "Restart";
    this.skipThisVersionText = skipThisVersionText ?? "Skip this version";
    this.downloadText = downloadText ?? "Download";
    this.upToDateTitleText = upToDateTitleText ?? "Application is up to date";
    this.upToDateText = upToDateText ?? "{} is the latest available version.";
    this.updateCheckFailedTitleText =
        updateCheckFailedTitleText ?? "Could not check for updates";
    this.updateCheckFailedText =
        updateCheckFailedText ?? "Please try again later.";
    this.okText = okText ?? "OK";
    this.updateFailedTooltipText =
        updateFailedTooltipText ?? "Update failed. Please try again.";
    this.releaseNotesButtonTooltipText =
        releaseNotesButtonTooltipText ?? "Release notes";
    this.releaseNotesTitleText = releaseNotesTitleText ?? "What's new";
    this.releaseNotesTypeLabels = releaseNotesTypeLabels ??
        const {
          "feat": "New features",
          "fix": "Bug fixes",
          "other": "Other changes",
        };
    this.releaseNotesSectionLabels = releaseNotesSectionLabels ??
        const {
          "features": "Features",
          "fixes": "Fixes",
          "security": "Security",
          "breaking": "Breaking changes",
          "other": "Other changes",
        };
    this.releaseNotesErrorText =
        releaseNotesErrorText ?? "Could not load release notes.";
    this.releaseNotesRetryText = releaseNotesRetryText ?? "Try again";
    this.releaseNotesEmptyText =
        releaseNotesEmptyText ?? "No release notes available.";
    setLang(this.lang!);
  }

  /// Default language used when no language is specified.
  static String defaultLang = "en";

  /// Loads localized strings from the specified language file.
  ///
  /// The file must exist at `langs/<newLang>.json`.
  ///
  /// Invalid JSON files are ignored and existing values are preserved.
  Future<void> setLang(String newLang) async {
    if (newLang == defaultLang) {
      return;
    }
    try {
      final jsonString =
          await rootBundle.loadString("packages/desktop_updater/lib/src/langs/$lang.json");
      final raw = jsonDecode(jsonString) as Map<String, dynamic>;
      lang = raw["lang"] ?? newLang;
      updateAvailableText = raw["updateAvailableText"] ?? updateAvailableText;
      newVersionAvailableText =
          raw["newVersionAvailableText"] ?? newVersionAvailableText;
      newVersionLongText = raw["newVersionLongText"] ?? newVersionLongText;
      restartText = raw["restartText"] ?? restartText;
      warningTitleText = raw["warningTitleText"] ?? warningTitleText;
      restartWarningText = raw["restartWarningText"] ?? restartWarningText;
      warningCancelText = raw["warningCancelText"] ?? warningCancelText;
      warningConfirmText = raw["warningConfirmText"] ?? warningConfirmText;
      skipThisVersionText = raw["skipThisVersionText"] ?? skipThisVersionText;
      downloadText = raw["downloadText"] ?? downloadText;
      upToDateTitleText = raw["upToDateTitleText"] ?? upToDateTitleText;
      upToDateText = raw["upToDateText"] ?? upToDateText;
      updateCheckFailedTitleText =
          raw["updateCheckFailedTitleText"] ?? updateCheckFailedTitleText;
      updateCheckFailedText =
          raw["updateCheckFailedText"] ?? updateCheckFailedText;
      okText = raw["okText"] ?? okText;
      updateFailedTooltipText =
          raw["updateFailedTooltipText"] ?? updateFailedTooltipText;
      releaseNotesButtonTooltipText =
          raw["releaseNotesButtonTooltipText"] ?? releaseNotesButtonTooltipText;
      releaseNotesTitleText =
          raw["releaseNotesTitleText"] ?? releaseNotesTitleText;
      if (raw["releaseNotesTypeLabels"] != null) {
        releaseNotesTypeLabels = Map<String, String>.from(
          raw["releaseNotesTypeLabels"],
        );
      }
      if (raw["releaseNotesSectionLabels"] != null) {
        releaseNotesSectionLabels = Map<String, String>.from(
          raw["releaseNotesSectionLabels"],
        );
      }
      releaseNotesErrorText =
          raw["releaseNotesErrorText"] ?? releaseNotesErrorText;
      releaseNotesRetryText =
          raw["releaseNotesRetryText"] ?? releaseNotesRetryText;
      releaseNotesEmptyText =
          raw["releaseNotesEmptyText"] ?? releaseNotesEmptyText;
    } catch (_) {
      // JSON invalide -> on ignore et garde la langue actuelle
    }
  }

  /// Current language code.
  late String lang;

  /// Text displayed when an update is available.
  late String updateAvailableText;

  /// Text displayed with the available version information.
  late String newVersionAvailableText;

  /// Long description displayed before downloading an update.
  late String newVersionLongText;

  /// Text displayed on the restart update button.
  late String restartText;

  /// Title displayed in the restart confirmation dialog.
  late String warningTitleText;

  /// Warning message displayed before restarting.
  late String restartWarningText;

  /// Text displayed for cancelling a restart.
  late String warningCancelText;

  /// Text displayed for confirming a restart.
  late String warningConfirmText;

  /// Text displayed for skipping the current version.
  late String skipThisVersionText;

  /// Text displayed on the download button.
  late String downloadText;

  /// Title displayed when the application is up to date.
  late String upToDateTitleText;

  /// Message displayed when no update is available.
  late String upToDateText;

  /// Title displayed when checking for updates fails.
  late String updateCheckFailedTitleText;

  /// Message displayed when the update check fails.
  late String updateCheckFailedText;

  /// Generic confirmation button text.
  late String okText;

  /// Callback used to generate a tooltip when an update fails.
  String? Function(Object error)? onUpdateFailedTooltip;

  /// Tooltip text displayed when an update fails.
  late String updateFailedTooltipText;

  /// Tooltip text for the release notes button.
  late String releaseNotesButtonTooltipText;

  /// Title displayed for release notes.
  late String releaseNotesTitleText;

  /// Labels used for release note change types.
  late Map<String, String> releaseNotesTypeLabels;

  /// Labels used for release note sections.
  late Map<String, String> releaseNotesSectionLabels;

  /// Error message displayed when release notes cannot be loaded.
  late String releaseNotesErrorText;

  /// Text displayed for retrying release notes loading.
  late String releaseNotesRetryText;

  /// Message displayed when no release notes exist.
  late String releaseNotesEmptyText;
}

/// Replaces `{}` placeholders in [key] with values from [args].
///
/// Returns an empty string if [key] is null.
String getLocalizedString(String? key, List<dynamic> args) {
  for (var i = 0; i < args.length; i++) {
    key = key?.replaceFirst("{}", args[i].toString());
  }
  return key ?? "";
}
