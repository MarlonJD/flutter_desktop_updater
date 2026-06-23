import "dart:async";

import "package:desktop_updater/desktop_updater_inherited_widget.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/src/localization.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/release_notes_bottom_sheet.dart";
import "package:desktop_updater/widget/update_problem_report_dialog.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// A ready-made Material card for the desktop update flow.
class UpdateCard extends StatelessWidget {
  /// Creates an update card.
  ///
  /// When [controller] is omitted, the card reads the nearest
  /// [DesktopUpdaterInheritedNotifier].
  const UpdateCard({
    super.key,
    this.controller,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
  });

  /// Optional controller for direct use outside an inherited updater scope.
  final DesktopUpdaterController? controller;

  /// Outer card margin.
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final notifier = controller ??
        DesktopUpdaterInheritedNotifier.maybeOf(context)?.notifier;
    if (notifier == null || !_shouldShowReadyUi(notifier)) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: notifier,
      builder: (context, child) {
        if (!_shouldShowReadyUi(notifier)) {
          return const SizedBox.shrink();
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight < 100) {
              return _CompactUpdateCard(notifier: notifier, margin: margin);
            }

            return _ExpandedUpdateCard(notifier: notifier, margin: margin);
          },
        );
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
      )
      ..add(DiagnosticsProperty<EdgeInsetsGeometry>("margin", margin));
  }
}

class _CompactUpdateCard extends StatelessWidget {
  const _CompactUpdateCard({
    required this.notifier,
    required this.margin,
  });

  final DesktopUpdaterController notifier;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card.filled(
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const IconButton.filled(
              onPressed: null,
              icon: Icon(Icons.update),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    notifier.getLocalization?.updateAvailableText ??
                        "Update Available",
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                  ),
                  Text(
                    _availableVersionText(notifier),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<DesktopUpdaterController>("notifier", notifier),
      )
      ..add(DiagnosticsProperty<EdgeInsetsGeometry>("margin", margin));
  }
}

class _ExpandedUpdateCard extends StatelessWidget {
  const _ExpandedUpdateCard({
    required this.notifier,
    required this.margin,
  });

  final DesktopUpdaterController notifier;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final state = notifier.state;

    return Card.filled(
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.update,
                  color: colorScheme.primary,
                  opticalSize: 24,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              notifier.getLocalization?.updateAvailableText ??
                  "Update Available",
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                  ),
            ),
            Text(
              _availableVersionText(notifier),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            Text(
              _longUpdateText(notifier),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: _UpdateCardActions(notifier: notifier)),
                if (state is UpdateFailed)
                  Tooltip(
                    message: _updateFailedTooltip(
                      state.error,
                      notifier.getLocalization,
                    ),
                    child: Icon(
                      Icons.error_outline,
                      color: colorScheme.error,
                    ),
                  )
                else if (notifier.canLoadReleaseNotes)
                  IconButton(
                    tooltip: notifier
                            .getLocalization?.releaseNotesButtonTooltipText ??
                        "Release notes",
                    icon: const Icon(Icons.description_outlined),
                    onPressed: () {
                      unawaited(
                        showReleaseNotesBottomSheet(
                          context,
                          controller: notifier,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<DesktopUpdaterController>("notifier", notifier),
      )
      ..add(DiagnosticsProperty<EdgeInsetsGeometry>("margin", margin));
  }
}

class _UpdateCardActions extends StatelessWidget {
  const _UpdateCardActions({required this.notifier});

  final DesktopUpdaterController notifier;

  @override
  Widget build(BuildContext context) {
    final state = notifier.state;

    return switch (state) {
      UpdateDownloading() => FilledButton.icon(
          icon: SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(value: _progressValue(state)),
          ),
          label: Text(_progressLabel(state)),
          onPressed: null,
        ),
      UpdateReadyToInstall() => FilledButton.icon(
          icon: const Icon(Icons.restart_alt),
          label: Text(
            notifier.getLocalization?.restartText ?? "Restart to update",
          ),
          onPressed: () => _showRestartDialog(context, notifier),
        ),
      UpdateFailed(:final report) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text("Check again"),
              onPressed: notifier.checkVersion,
            ),
            if (report != null)
              OutlinedButton.icon(
                icon: const Icon(Icons.assignment_outlined),
                label: const Text("View report"),
                onPressed: () {
                  showUpdateProblemReportDialog(
                    context,
                    controller: notifier,
                    report: report,
                  );
                },
              ),
          ],
        ),
      _ => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.download),
              label: Text(notifier.getLocalization?.downloadText ?? "Download"),
              onPressed: notifier.downloadUpdate,
            ),
            if (!_isMandatoryUpdate(state))
              OutlinedButton.icon(
                icon: const Icon(Icons.close),
                label: Text(
                  notifier.getLocalization?.skipThisVersionText ??
                      "Skip this version",
                ),
                onPressed: () {
                  unawaited(notifier.makeSkipUpdate());
                },
              ),
          ],
        ),
    };
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<DesktopUpdaterController>("notifier", notifier),
    );
  }
}

bool _shouldShowReadyUi(DesktopUpdaterController controller) {
  if (controller.skipUpdate) {
    return false;
  }

  return switch (controller.state) {
    UpdateAvailable() ||
    UpdateDownloading() ||
    UpdateReadyToInstall() ||
    UpdateFailed() =>
      true,
    _ => false,
  };
}

bool _isMandatoryUpdate(UpdateState state) {
  return state is UpdateAvailable && state.mandatory;
}

String _availableVersionText(DesktopUpdaterController notifier) {
  return getLocalizedString(
        notifier.getLocalization?.newVersionAvailableText,
        [notifier.appName, notifier.appVersion],
      );
}

String _longUpdateText(DesktopUpdaterController notifier) {
  final state = notifier.state;
  if (state is UpdateFailed) {
    return "Please try again later.";
  }

  final totalBytes = _updateTotalBytes(
    state: state,
    descriptor: notifier.activeDescriptor,
  );
  return getLocalizedString(
        notifier.getLocalization?.newVersionLongText,
        [_formatMegabytes(totalBytes)],
      );
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

String _progressLabel(UpdateDownloading state) {
  return "${(_progressValue(state) * 100).toInt()}% "
      "(${_formatMegabytes(state.receivedBytes)} MB / "
      "${_formatMegabytes(state.totalBytes)} MB)";
}

String _formatMegabytes(num bytes) {
  return (bytes / 1024 / 1024).toStringAsFixed(2);
}

void _showRestartDialog(
  BuildContext context,
  DesktopUpdaterController notifier,
) {
  showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(
          notifier.getLocalization?.warningTitleText ?? "Are you sure?",
        ),
        content: Text(
          notifier.getLocalization?.restartWarningText ??
              "A restart is required to complete the update installation.\n"
                  "Any unsaved changes will be lost. Would you like to "
                  "restart now?",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Text(
              notifier.getLocalization?.warningCancelText ?? "Not now",
            ),
          ),
          TextButton(
            onPressed: notifier.restartApp,
            child: Text(
              notifier.getLocalization?.warningConfirmText ?? "Restart",
            ),
          ),
        ],
      );
    },
  );
}

String _updateFailedTooltip(
  Object error,
  DesktopUpdateLocalization? loc,
) {
  final custom = loc?.onUpdateFailedTooltip?.call(error);
  if (custom != null) return custom;
  return loc?.updateFailedTooltipText ?? "Update failed. Please try again.";
}
