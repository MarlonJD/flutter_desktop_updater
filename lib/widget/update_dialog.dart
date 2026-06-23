import "dart:async";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// Controls mandatory ready-to-install behavior in dialog-based update UI.
enum MandatoryReadyToInstallBehavior {
  /// Show a restart confirmation with `Save first` and `Restart`.
  promptToSaveFirst,

  /// Restart immediately when the user presses the ready-to-install action.
  restartWithoutPrompt,
}

/// Listens for available updates and presents them in a dialog.
class UpdateDialogListener extends StatefulWidget {
  /// Creates a listener that shows an update dialog for [controller].
  const UpdateDialogListener({
    super.key,
    required this.controller,
    this.backgroundColor,
    this.iconColor,
    this.shadowColor,
    this.textColor,
    this.buttonTextColor,
    this.buttonIconColor,
    this.mandatoryReadyToInstallBehavior =
        MandatoryReadyToInstallBehavior.promptToSaveFirst,
  });

  /// The controller that provides update state and actions.
  final DesktopUpdaterController controller;

  /// The background color of the dialog. if null, it will use Theme.of(context).colorScheme.surfaceContainerHigh,
  final Color? backgroundColor;

  /// The color of the icon. if null, it will use Theme.of(context).colorScheme.primary,
  final Color? iconColor;

  /// The color of the shadow. if null, it will use Theme.of(context).shadowColor,
  final Color? shadowColor;

  /// The color of the text. if null, it will use Theme.of(context).colorScheme.onSurface,
  final Color? textColor;

  /// The color of the button text. if null, it will use Theme.of(context).colorScheme.primary,
  final Color? buttonTextColor;

  /// The color of the button icon. if null, it will use Theme.of(context).colorScheme.primary,
  final Color? buttonIconColor;

  /// Dialog behavior after a mandatory update has been staged.
  final MandatoryReadyToInstallBehavior mandatoryReadyToInstallBehavior;

  @override
  State<UpdateDialogListener> createState() => _UpdateDialogListenerState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
      )
      ..add(ColorProperty("backgroundColor", backgroundColor))
      ..add(ColorProperty("iconColor", iconColor))
      ..add(ColorProperty("shadowColor", shadowColor))
      ..add(ColorProperty("buttonTextColor", buttonTextColor))
      ..add(ColorProperty("buttonIconColor", buttonIconColor))
      ..add(ColorProperty("textColor", textColor))
      ..add(
        EnumProperty<MandatoryReadyToInstallBehavior>(
          "mandatoryReadyToInstallBehavior",
          mandatoryReadyToInstallBehavior,
        ),
      );
  }
}

class _UpdateDialogListenerState extends State<UpdateDialogListener> {
  Object? _dialogRequest;

  @override
  void didUpdateWidget(covariant UpdateDialogListener oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      _dialogRequest = null;
    }
  }

  void _tryShowDialog() {
    final controller = widget.controller;

    if (_dialogRequest != null || !_shouldShowDialog(controller)) {
      return;
    }

    final request = Object();
    _dialogRequest = request;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _dialogRequest != request ||
          controller != widget.controller ||
          !_shouldShowDialog(controller)) {
        _clearDialogRequest(request);
        return;
      }

      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: _canDismissDialog(controller.state),
          builder: (context) {
            return UpdateDialogWidget(
              controller: controller,
              backgroundColor: widget.backgroundColor,
              iconColor: widget.iconColor,
              shadowColor: widget.shadowColor,
              textColor: widget.textColor,
              buttonTextColor: widget.buttonTextColor,
              buttonIconColor: widget.buttonIconColor,
              mandatoryReadyToInstallBehavior:
                  widget.mandatoryReadyToInstallBehavior,
            );
          },
        ).whenComplete(() {
          _clearDialogRequest(request);
        }),
      );
    });
  }

  bool _shouldShowDialog(DesktopUpdaterController controller) {
    return !controller.skipUpdate &&
        switch (controller.state) {
          UpdateAvailable() ||
          UpdateFreshInstallRequired() ||
          UpdateBlockedBySupportPolicy() =>
            true,
          _ => false,
        };
  }

  void _clearDialogRequest(Object request) {
    if (_dialogRequest == request) {
      _dialogRequest = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        _tryShowDialog();
        return const SizedBox.shrink();
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<DesktopUpdaterController>(
          "controller",
          widget.controller,
        ),
      )
      ..add(ColorProperty("backgroundColor", widget.backgroundColor))
      ..add(ColorProperty("iconColor", widget.iconColor))
      ..add(ColorProperty("shadowColor", widget.shadowColor));
  }
}

/// Shows an update dialog.
Future showUpdateDialog<T>(
  BuildContext context, {
  required DesktopUpdaterController controller,
  Color? backgroundColor,
  Color? iconColor,
  Color? shadowColor,
  MandatoryReadyToInstallBehavior mandatoryReadyToInstallBehavior =
      MandatoryReadyToInstallBehavior.promptToSaveFirst,
}) {
  return showDialog(
    context: context,
    barrierDismissible: _canDismissDialog(controller.state),
    builder: (context) {
      return UpdateDialogWidget(
        controller: controller,
        backgroundColor: backgroundColor,
        iconColor: iconColor,
        shadowColor: shadowColor,
        mandatoryReadyToInstallBehavior: mandatoryReadyToInstallBehavior,
      );
    },
  );
}

/// Shows optional Material feedback for a user-triggered update check result.
Future<void> showManualUpdateCheckResultDialog(
  BuildContext context, {
  required DesktopUpdaterController controller,
  required ManualUpdateCheckResult result,
  bool showAvailableUpdate = false,
  Color? backgroundColor,
  Color? iconColor,
  Color? shadowColor,
  Color? textColor,
  Color? buttonTextColor,
  MandatoryReadyToInstallBehavior mandatoryReadyToInstallBehavior =
      MandatoryReadyToInstallBehavior.promptToSaveFirst,
}) async {
  switch (result) {
    case ManualUpdateCheckAvailable():
      if (!showAvailableUpdate) {
        return;
      }
      await showUpdateDialog<void>(
        context,
        controller: controller,
        backgroundColor: backgroundColor,
        iconColor: iconColor,
        shadowColor: shadowColor,
        mandatoryReadyToInstallBehavior: mandatoryReadyToInstallBehavior,
      );
    case ManualUpdateCheckFreshInstallRequired() ||
          ManualUpdateCheckBlockedBySupportPolicy():
      await showUpdateDialog<void>(
        context,
        controller: controller,
        backgroundColor: backgroundColor,
        iconColor: iconColor,
        shadowColor: shadowColor,
        mandatoryReadyToInstallBehavior: mandatoryReadyToInstallBehavior,
      );
    case ManualUpdateCheckUpToDate():
      await showDialog<void>(
        context: context,
        builder: (context) {
          final localization = controller.getLocalization;
          final appName = controller.appName ?? "This application";
          final appVersion = controller.appVersion ?? "";
          final versionLabel =
              appVersion.isEmpty ? appName : "$appName $appVersion";

          return AlertDialog(
            backgroundColor: backgroundColor,
            iconColor: iconColor,
            shadowColor: shadowColor,
            title: Text(
              localization?.upToDateTitleText ?? "Application is up to date",
              style: TextStyle(color: textColor),
            ),
            content: Text(
              getLocalizedString(localization?.upToDateText, [versionLabel]) ??
                  "$versionLabel is the latest available version.",
              style: TextStyle(color: textColor),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  localization?.okText ?? "OK",
                  style: TextStyle(color: buttonTextColor),
                ),
              ),
            ],
          );
        },
      );
    case ManualUpdateCheckFailed():
      await showDialog<void>(
        context: context,
        builder: (context) {
          final localization = controller.getLocalization;
          final state = controller.state;
          final report = state is UpdateFailed ? state.report : null;

          return AlertDialog(
            backgroundColor: backgroundColor,
            iconColor: iconColor,
            shadowColor: shadowColor,
            title: Text(
              localization?.updateCheckFailedTitleText ??
                  "Could not check for updates",
              style: TextStyle(color: textColor),
            ),
            content: Text(
              localization?.updateCheckFailedText ?? "Please try again later.",
              style: TextStyle(color: textColor),
            ),
            actions: [
              if (report != null)
                TextButton(
                  onPressed: () {
                    showUpdateProblemReportDialog(
                      context,
                      controller: controller,
                      report: report,
                    );
                  },
                  child: Text(
                    "View report",
                    style: TextStyle(color: buttonTextColor),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  localization?.okText ?? "OK",
                  style: TextStyle(color: buttonTextColor),
                ),
              ),
            ],
          );
        },
      );
  }
}

/// A widget that shows an update dialog.
class UpdateDialogWidget extends StatelessWidget {
  /// Creates an update dialog widget.
  const UpdateDialogWidget({
    super.key,
    required DesktopUpdaterController controller,
    this.backgroundColor,
    this.iconColor,
    this.shadowColor,
    this.textColor,
    this.buttonTextColor,
    this.buttonIconColor,
    this.mandatoryReadyToInstallBehavior =
        MandatoryReadyToInstallBehavior.promptToSaveFirst,
  }) : notifier = controller;

  /// The controller for the update dialog.
  final DesktopUpdaterController notifier;

  /// The background color of the dialog. if null, it will use Theme.of(context).colorScheme.surfaceContainerHigh,
  final Color? backgroundColor;

  /// The color of the icon. if null, it will use Theme.of(context).colorScheme.primary,
  final Color? iconColor;

  /// The color of the shadow. if null, it will use Theme.of(context).shadowColor,
  final Color? shadowColor;

  /// The color of the text. if null, it will use Theme.of(context).colorScheme.onSurface,
  final Color? textColor;

  /// The color of the button text. if null, it will use Theme.of(context).colorScheme.primary,
  final Color? buttonTextColor;

  /// The color of the button icon. if null, it will use Theme.of(context).colorScheme.primary,
  final Color? buttonIconColor;

  /// Dialog behavior after a mandatory update has been staged.
  final MandatoryReadyToInstallBehavior mandatoryReadyToInstallBehavior;

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setState) {
        return ListenableBuilder(
          listenable: notifier,
          builder: (context, child) {
            final state = notifier.state;
            if (state is UpdateFailed) {
              return AlertDialog(
                backgroundColor: backgroundColor,
                iconColor: iconColor,
                shadowColor: shadowColor,
                title: Text(
                  "Update failed",
                  style: TextStyle(color: textColor),
                ),
                content: Text(
                  "Please try again later.",
                  style: TextStyle(color: textColor),
                ),
                actions: [
                  TextButton.icon(
                    icon: Icon(Icons.refresh, color: buttonIconColor),
                    label: Text(
                      "Check again",
                      style: TextStyle(color: buttonTextColor),
                    ),
                    onPressed: notifier.checkVersion,
                  ),
                  if (state.report != null)
                    TextButton.icon(
                      icon: Icon(
                        Icons.assignment_outlined,
                        color: buttonIconColor,
                      ),
                      label: Text(
                        "View report",
                        style: TextStyle(color: buttonTextColor),
                      ),
                      onPressed: () {
                        showUpdateProblemReportDialog(
                          context,
                          controller: notifier,
                          report: state.report!,
                        );
                      },
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      "Close",
                      style: TextStyle(color: buttonTextColor),
                    ),
                  ),
                ],
              );
            }
            final totalBytes = _updateTotalBytes(
              state: state,
              descriptor: notifier.activeDescriptor,
            );
            return AlertDialog(
              backgroundColor: backgroundColor,
              iconColor: iconColor,
              shadowColor: shadowColor,
              title: Text(
                notifier.getLocalization?.updateAvailableText ??
                    "Update Available",
                style: TextStyle(color: textColor),
              ),
              content: Text(
                _dialogContentText(
                  notifier: notifier,
                  state: state,
                  totalBytes: totalBytes,
                ),
                style: TextStyle(color: buttonTextColor),
              ),
              actions: [
                if (state is UpdateDownloading)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        icon: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            value: _progressValue(state),
                          ),
                        ),
                        label: Row(
                          children: [
                            Text(
                              "${(_progressValue(state) * 100).toInt()}% "
                              "(${_formatMegabytes(state.receivedBytes)} MB / "
                              "${_formatMegabytes(state.totalBytes)} MB)",
                            ),
                          ],
                        ),
                        onPressed: null,
                      ),
                    ],
                  )
                else if (state is UpdateReadyToInstall)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.restart_alt),
                        label: Text(
                          notifier.getLocalization?.restartText ??
                              "Restart to update",
                        ),
                        onPressed: () {
                          final isMandatory =
                              _isMandatoryUpdate(notifier.state);
                          if (isMandatory &&
                              mandatoryReadyToInstallBehavior ==
                                  MandatoryReadyToInstallBehavior
                                      .restartWithoutPrompt) {
                            unawaited(notifier.restartApp());
                            return;
                          }
                          showDialog(
                            context: context,
                            barrierDismissible: !isMandatory,
                            builder: (restartContext) {
                              return AlertDialog(
                                title: Text(
                                  notifier.getLocalization?.warningTitleText ??
                                      "Are you sure?",
                                ),
                                content: Text(
                                  notifier.getLocalization
                                          ?.restartWarningText ??
                                      (isMandatory
                                          ? "This update is required. Save your work before restarting to finish the installation."
                                          : "A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?"),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      Navigator.of(restartContext).pop();
                                      if (isMandatory) {
                                        Navigator.of(context).pop();
                                      }
                                    },
                                    child: Text(
                                      isMandatory
                                          ? notifier.getLocalization
                                                  ?.saveFirstText ??
                                              "Save first"
                                          : notifier.getLocalization
                                                  ?.warningCancelText ??
                                              "Not now",
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: notifier.restartApp,
                                    child: Text(
                                      notifier.getLocalization
                                              ?.warningConfirmText ??
                                          "Restart",
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ],
                  )
                else if (state is UpdateFreshInstallRequired)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (!_isMandatoryUpdate(state))
                        TextButton.icon(
                          icon: Icon(Icons.close, color: buttonIconColor),
                          label: Text(
                            notifier.getLocalization?.warningCancelText ??
                                "Not now",
                            style: TextStyle(color: buttonTextColor),
                          ),
                          onPressed: () {
                            unawaited(notifier.makeSkipUpdate());
                          },
                        ),
                      if (!_isMandatoryUpdate(state)) const SizedBox(width: 8),
                      TextButton.icon(
                        icon: Icon(Icons.open_in_new, color: buttonIconColor),
                        label: Text(
                          notifier.getLocalization?.downloadLatestText ??
                              "Download latest",
                          style: TextStyle(color: buttonTextColor),
                        ),
                        onPressed: notifier.openFreshInstallDownload,
                      ),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (!_isMandatoryUpdate(state))
                        TextButton.icon(
                          icon: Icon(Icons.close, color: buttonIconColor),
                          label: Text(
                            notifier.getLocalization?.skipThisVersionText ??
                                "Skip this version",
                            style: TextStyle(color: buttonTextColor),
                          ),
                          onPressed: () {
                            unawaited(notifier.makeSkipUpdate());
                          },
                        ),
                      if (!_isMandatoryUpdate(state)) const SizedBox(width: 8),
                      TextButton.icon(
                        icon: Icon(Icons.download, color: buttonIconColor),
                        label: Text(
                          notifier.getLocalization?.downloadText ?? "Download",
                          style: TextStyle(color: buttonTextColor),
                        ),
                        onPressed: notifier.downloadUpdate,
                      ),
                    ],
                  ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DiagnosticsProperty<DesktopUpdaterController>("notifier", notifier))
      ..add(ColorProperty("backgroundColor", backgroundColor))
      ..add(ColorProperty("iconColor", iconColor))
      ..add(ColorProperty("shadowColor", shadowColor))
      ..add(ColorProperty("buttonTextColor", buttonTextColor))
      ..add(ColorProperty("buttonIconColor", buttonIconColor))
      ..add(ColorProperty("textColor", textColor))
      ..add(
        EnumProperty<MandatoryReadyToInstallBehavior>(
          "mandatoryReadyToInstallBehavior",
          mandatoryReadyToInstallBehavior,
        ),
      );
  }
}

bool _canDismissDialog(UpdateState state) {
  return !_isMandatoryUpdate(state);
}

bool _isMandatoryUpdate(UpdateState state) {
  return switch (state) {
    UpdateAvailable(:final mandatory) ||
    UpdateReadyToInstall(:final mandatory) ||
    UpdateFreshInstallRequired(:final mandatory) =>
      mandatory,
    UpdateBlockedBySupportPolicy() => true,
    _ => false,
  };
}

String _dialogContentText({
  required DesktopUpdaterController notifier,
  required UpdateState state,
  required int totalBytes,
}) {
  if (state is UpdateFreshInstallRequired) {
    return state.freshInstall.message ??
        notifier.getLocalization?.freshInstallRequiredText ??
        "This version cannot safely install the update. Please download the "
            "latest version.";
  }
  if (state is UpdateBlockedBySupportPolicy) {
    return notifier.getLocalization?.supportPolicyBlockedText ??
        "This version is no longer supported. Please update to continue.";
  }
  if (state is UpdateAvailable && state.supportPolicy != null) {
    final policy = state.supportPolicy!;
    return getLocalizedString(
          notifier.getLocalization?.supportPolicyWarningText,
          [
            policy.minimumSupportedVersion,
            policy.enforcedAfter.toIso8601String(),
          ],
        ) ??
        getLocalizedString(
          "Please update to version {} before {}.",
          [
            policy.minimumSupportedVersion,
            policy.enforcedAfter.toIso8601String(),
          ],
        ) ??
        "";
  }

  final availableText = getLocalizedString(
        notifier.getLocalization?.newVersionAvailableText,
        [notifier.appName, notifier.appVersion],
      ) ??
      getLocalizedString(
        "{} {} is available",
        [notifier.appName, notifier.appVersion],
      ) ??
      "";
  final longText = getLocalizedString(
        notifier.getLocalization?.newVersionLongText,
        [_formatMegabytes(totalBytes)],
      ) ??
      getLocalizedString(
        "New version is ready to download, click the button below to start "
        "downloading. This will download {} MB of data.",
        [_formatMegabytes(totalBytes)],
      ) ??
      "";
  return "$availableText, $longText";
}

int _updateTotalBytes({
  required UpdateState state,
  required ReleaseDescriptor? descriptor,
}) {
  if (state is UpdateDownloading) {
    return state.totalBytes;
  }
  return descriptor?.artifact.length ?? 0;
}

double _progressValue(UpdateDownloading state) {
  if (state.totalBytes <= 0) {
    return 0;
  }
  return state.receivedBytes / state.totalBytes;
}

String _formatMegabytes(num bytes) {
  return (bytes / 1024 / 1024).toStringAsFixed(2);
}
