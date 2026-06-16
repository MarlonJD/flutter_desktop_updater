import "dart:async";

import "package:desktop_updater/updater_controller.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// Shows a Material problem report dialog for a failed update.
Future<void> showUpdateProblemReportDialog(
  BuildContext context, {
  required DesktopUpdaterController controller,
  required UpdateProblemReport report,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return UpdateProblemReportDialog(
        controller: controller,
        report: report,
      );
    },
  );
}

/// Desktop-style update problem report dialog.
class UpdateProblemReportDialog extends StatelessWidget {
  /// Creates a problem report dialog.
  const UpdateProblemReportDialog({
    super.key,
    required this.controller,
    required this.report,
  });

  /// Controller that owns retry and app-owned report actions.
  final DesktopUpdaterController controller;

  /// Redacted report shown and copied by the dialog.
  final UpdateProblemReport report;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final detailsMaxHeight = _detailsMaxHeightFor(
      MediaQuery.sizeOf(context).height,
    );
    final actionsWidth = _actionsWidthFor(MediaQuery.sizeOf(context).width);

    return AlertDialog(
      scrollable: true,
      title: const Text("Update failed"),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "The update could not be completed. You can try again, "
              "copy a redacted local report, or send it through an "
              "app-owned reporting flow.",
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text("Technical details"),
              childrenPadding: const EdgeInsets.only(top: 8),
              children: [
                Container(
                  key: const Key("desktopUpdaterProblemReportDetails"),
                  width: double.infinity,
                  constraints: BoxConstraints(maxHeight: detailsMaxHeight),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        report.toPlainText(),
                        style: textTheme.bodySmall?.copyWith(
                          fontFamily: "monospace",
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actions: [
        SizedBox(
          width: actionsWidth,
          child: _ProblemReportDialogActions(
            controller: controller,
            report: report,
            width: actionsWidth,
          ),
        ),
      ],
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
      )
      ..add(DiagnosticsProperty<UpdateProblemReport>("report", report));
  }
}

class _ProblemReportDialogActions extends StatelessWidget {
  const _ProblemReportDialogActions({
    required this.controller,
    required this.report,
    required this.width,
  });

  final DesktopUpdaterController controller;
  final UpdateProblemReport report;
  final double width;

  @override
  Widget build(BuildContext context) {
    final copy = _ProblemReportActionButton.outlined(
      key: const Key("desktopUpdaterProblemReportCopyAction"),
      label: "Copy report",
      onPressed: () {
        unawaited(_copyReport(context, report));
      },
    );
    final retry = _ProblemReportActionButton.outlined(
      key: const Key("desktopUpdaterProblemReportRetryAction"),
      label: "Try again",
      onPressed: () {
        unawaited(_retry(controller));
      },
    );
    final close = _ProblemReportActionButton.outlined(
      key: const Key("desktopUpdaterProblemReportCloseAction"),
      label: "Close",
      onPressed: () => Navigator.of(context).pop(),
    );
    final submit = _ProblemReportActionButton.filled(
      key: const Key("desktopUpdaterProblemReportSubmitAction"),
      label: "Report issue",
      onPressed: () {
        unawaited(controller.reportProblem(report));
      },
    );

    if (width < _actionsSingleColumnBreakpoint) {
      return Column(
        key: const Key("desktopUpdaterProblemReportActions"),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          copy,
          const SizedBox(height: _actionSpacing),
          retry,
          const SizedBox(height: _actionSpacing),
          close,
          if (controller.canReportProblem) ...[
            const SizedBox(height: _actionSpacing),
            submit,
          ],
        ],
      );
    }

    final buttonWidth = (width - _actionSpacing) / 2;
    return Column(
      key: const Key("desktopUpdaterProblemReportActions"),
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: buttonWidth, child: copy),
            const SizedBox(width: _actionSpacing),
            SizedBox(width: buttonWidth, child: retry),
          ],
        ),
        const SizedBox(height: _actionSpacing),
        Row(
          mainAxisAlignment: controller.canReportProblem
              ? MainAxisAlignment.start
              : MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.max,
          children: [
            SizedBox(width: buttonWidth, child: close),
            if (controller.canReportProblem) ...[
              const SizedBox(width: _actionSpacing),
              SizedBox(width: buttonWidth, child: submit),
            ],
          ],
        ),
      ],
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
      )
      ..add(DiagnosticsProperty<UpdateProblemReport>("report", report))
      ..add(DoubleProperty("width", width));
  }
}

class _ProblemReportActionButton extends StatelessWidget {
  const _ProblemReportActionButton.outlined({
    super.key,
    required this.label,
    required this.onPressed,
  }) : filled = false;

  const _ProblemReportActionButton.filled({
    super.key,
    required this.label,
    required this.onPressed,
  }) : filled = true;

  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    final style = ButtonStyle(
      minimumSize: WidgetStateProperty.all(
        const Size.fromHeight(_actionButtonHeight),
      ),
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 12),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    if (filled) {
      return FilledButton(
        style: style,
        onPressed: onPressed,
        child: child,
      );
    }
    return OutlinedButton(
      style: style,
      onPressed: onPressed,
      child: child,
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty("label", label))
      ..add(ObjectFlagProperty<VoidCallback>.has("onPressed", onPressed))
      ..add(
        FlagProperty(
          "filled",
          value: filled,
          ifTrue: "filled",
          ifFalse: "outlined",
        ),
      );
  }
}

const _actionButtonHeight = 40.0;
const _actionSpacing = 12.0;
const _actionsSingleColumnBreakpoint = 280.0;
const _wideActionsWidth = 292.0;

double _actionsWidthFor(double screenWidth) {
  const dialogHorizontalInset = 48.0;
  final availableWidth = screenWidth - dialogHorizontalInset;
  if (availableWidth <= 0) {
    return _wideActionsWidth;
  }
  if (availableWidth < _wideActionsWidth) {
    return availableWidth;
  }
  return _wideActionsWidth;
}

double _detailsMaxHeightFor(double screenHeight) {
  if (screenHeight < 600) {
    return 96;
  }
  return 240;
}

Future<void> _retry(DesktopUpdaterController controller) async {
  try {
    await controller.checkVersion();
  } on Object {
    // Dialog retry is a user-facing action; the controller state carries errors.
  }
}

Future<void> _copyReport(
  BuildContext context,
  UpdateProblemReport report,
) async {
  await Clipboard.setData(ClipboardData(text: report.toPlainText()));
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    const SnackBar(content: Text("Report copied")),
  );
}
