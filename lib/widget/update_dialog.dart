import "dart:async";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

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
      ..add(ColorProperty("textColor", textColor));
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
            );
          },
        ).whenComplete(() {
          _clearDialogRequest(request);
        }),
      );
    });
  }

  bool _shouldShowDialog(DesktopUpdaterController controller) {
    return controller.state is UpdateAvailable && !controller.skipUpdate;
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
}) {
  return showDialog(
    context: context,
    barrierDismissible: _canDismissDialog(controller.state),
    builder: (context) {
      return _withLocalizationDirection(
        controller,
        UpdateDialogWidget(
          controller: controller,
          backgroundColor: backgroundColor,
          iconColor: iconColor,
          shadowColor: shadowColor,
        ),
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

          final dialog = AlertDialog(
            backgroundColor: backgroundColor,
            iconColor: iconColor,
            shadowColor: shadowColor,
            title: Text(
              localization?.upToDateTitleText ?? "Application is up to date",
              style: TextStyle(color: textColor),
            ),
            content: Text(
              getLocalizedString(localization?.upToDateText, [versionLabel]) ??
                  getLocalizedString(
                    defaultDesktopUpdateLocalization.upToDateText,
                    [versionLabel],
                  ) ??
                  "",
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
          return _withLocalizationDirection(controller, dialog);
        },
      );
    case ManualUpdateCheckFailed():
      await showDialog<void>(
        context: context,
        builder: (context) {
          final localization = controller.getLocalization;
          final state = controller.state;
          final report = state is UpdateFailed ? state.report : null;

          final dialog = AlertDialog(
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
          return _withLocalizationDirection(controller, dialog);
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

  @override
  Widget build(BuildContext context) {
    return _withLocalizationDirection(
      notifier,
      StatefulBuilder(
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
                  "${_availableVersionText(notifier)}, "
                  "${_longUpdateText(notifier, totalBytes)}",
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
                            showDialog(
                              context: context,
                              builder: (context) {
                                return AlertDialog(
                                  title: Text(
                                    notifier.getLocalization
                                            ?.warningTitleText ??
                                        "Are you sure?",
                                  ),
                                  content: Text(
                                    notifier.getLocalization
                                            ?.restartWarningText ??
                                        "A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?",
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () {
                                        Navigator.of(context).pop();
                                      },
                                      child: Text(
                                        notifier.getLocalization
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
                        if (!_isMandatoryUpdate(state))
                          const SizedBox(width: 8),
                        TextButton.icon(
                          icon: Icon(Icons.download, color: buttonIconColor),
                          label: Text(
                            notifier.getLocalization?.downloadText ??
                                "Download",
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
      ),
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
      ..add(ColorProperty("textColor", textColor));
  }
}

bool _canDismissDialog(UpdateState state) {
  return !_isMandatoryUpdate(state);
}

bool _isMandatoryUpdate(UpdateState state) {
  return state is UpdateAvailable && state.mandatory;
}

Widget _withLocalizationDirection(
  DesktopUpdaterController controller,
  Widget child,
) {
  final textDirection = controller.getLocalization?.textDirection;
  if (textDirection == null) {
    return child;
  }
  return Directionality(textDirection: textDirection, child: child);
}

String _availableVersionText(DesktopUpdaterController notifier) {
  return getLocalizedString(
        notifier.getLocalization?.newVersionAvailableText,
        [notifier.appName, notifier.appVersion],
      ) ??
      getLocalizedString(
        defaultDesktopUpdateLocalization.newVersionAvailableText,
        [notifier.appName, notifier.appVersion],
      ) ??
      "";
}

String _longUpdateText(
  DesktopUpdaterController notifier,
  int totalBytes,
) {
  return getLocalizedString(
        notifier.getLocalization?.newVersionLongText,
        [_formatMegabytes(totalBytes)],
      ) ??
      getLocalizedString(
        defaultDesktopUpdateLocalization.newVersionLongText,
        [_formatMegabytes(totalBytes)],
      ) ??
      "";
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
