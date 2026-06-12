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
      return UpdateDialogWidget(
        controller: controller,
        backgroundColor: backgroundColor,
        iconColor: iconColor,
        shadowColor: shadowColor,
      );
    },
  );
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
    return StatefulBuilder(
      builder: (context, setState) {
        return ListenableBuilder(
          listenable: notifier,
          builder: (context, child) {
            final state = notifier.state;
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
                "${getLocalizedString(notifier.getLocalization?.newVersionAvailableText, [notifier.appName, notifier.appVersion]) ?? (getLocalizedString("{} {} is available", [notifier.appName, notifier.appVersion])) ?? ""}, ${getLocalizedString(notifier.getLocalization?.newVersionLongText, [
                          _formatMegabytes(totalBytes),
                        ]) ?? (getLocalizedString("New version is ready to download, click the button below to start downloading. This will download {} MB of data.", [
                          _formatMegabytes(totalBytes),
                        ])) ?? ""}",
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
                                  notifier.getLocalization?.warningTitleText ??
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
                          onPressed: notifier.makeSkipUpdate,
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
      ..add(ColorProperty("textColor", textColor));
  }
}

bool _canDismissDialog(UpdateState state) {
  return !_isMandatoryUpdate(state);
}

bool _isMandatoryUpdate(UpdateState state) {
  return state is UpdateAvailable && state.mandatory;
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
