import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// Loads macOS install-location status.
typedef MacOSInstallLocationStatusLoader = Future<MacOSInstallLocationStatus>
    Function();

/// Moves the running macOS app to `/Applications`.
typedef MacOSMoveToApplicationsMover = Future<void> Function({
  required bool replaceExisting,
});

/// Opt-in wrapper that offers to move a macOS app into `/Applications`.
class MacOSMoveToApplicationsPrompt extends StatefulWidget {
  /// Creates a Move to Applications prompt wrapper.
  const MacOSMoveToApplicationsPrompt({
    super.key,
    required this.child,
    this.statusLoader,
    this.mover,
    this.localization = defaultDesktopUpdateLocalization,
    this.titleText,
    this.bodyText,
    this.moveText,
    this.skipText,
    this.replaceTitleText,
    this.replaceBodyText,
    this.replaceText,
    this.cancelText,
  });

  /// App content rendered normally behind the optional prompt.
  final Widget child;

  /// Optional status loader for tests or app-owned policy.
  final MacOSInstallLocationStatusLoader? statusLoader;

  /// Optional mover for tests or app-owned policy.
  final MacOSMoveToApplicationsMover? mover;

  /// Localized copy used by this prompt.
  final DesktopUpdateLocalization localization;

  /// Dialog title override.
  final String? titleText;

  /// Dialog body override.
  final String? bodyText;

  /// Primary move button text override.
  final String? moveText;

  /// Skip button text override.
  final String? skipText;

  /// Replace confirmation title override.
  final String? replaceTitleText;

  /// Replace confirmation body override.
  final String? replaceBodyText;

  /// Replace confirmation button text override.
  final String? replaceText;

  /// Replace cancellation button text override.
  final String? cancelText;

  @override
  State<MacOSMoveToApplicationsPrompt> createState() =>
      _MacOSMoveToApplicationsPromptState();
}

class _MacOSMoveToApplicationsPromptState
    extends State<MacOSMoveToApplicationsPrompt> {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadStatusAndPrompt();
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  Future<void> _loadStatusAndPrompt() async {
    final loader = widget.statusLoader ??
        () => DesktopUpdater().checkMacOSInstallLocation();
    final status = await loader();
    if (!mounted || _dismissed || !status.shouldOfferMovePrompt) {
      return;
    }
    await _showMovePrompt();
  }

  Future<void> _showMovePrompt() {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_titleText),
          content: Text(_bodyText),
          actions: [
            TextButton(
              onPressed: () {
                _dismissed = true;
                Navigator.of(context).pop();
              },
              child: Text(_skipText),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _move(replaceExisting: false);
              },
              child: Text(_moveText),
            ),
          ],
        );
      },
    );
  }

  Future<void> _move({required bool replaceExisting}) async {
    final mover = widget.mover ??
        ({required bool replaceExisting}) {
          return DesktopUpdater().moveMacOSAppToApplications(
            replaceExisting: replaceExisting,
          );
        };
    try {
      await mover(replaceExisting: replaceExisting);
      _dismissed = true;
    } on PlatformException catch (error) {
      if (error.code != "AlreadyExists" || replaceExisting || !mounted) {
        rethrow;
      }
      final shouldReplace = await _showReplacePrompt();
      if (shouldReplace == true) {
        await _move(replaceExisting: true);
      }
    }
  }

  Future<bool?> _showReplacePrompt() {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_replaceTitleText),
          content: Text(_replaceBodyText),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_cancelText),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_replaceText),
            ),
          ],
        );
      },
    );
  }

  String get _titleText {
    return widget.titleText ??
        widget.localization.macosMoveToApplicationsTitleText ??
        defaultDesktopUpdateLocalization.macosMoveToApplicationsTitleText!;
  }

  String get _bodyText {
    return widget.bodyText ??
        widget.localization.macosMoveToApplicationsBodyText ??
        defaultDesktopUpdateLocalization.macosMoveToApplicationsBodyText!;
  }

  String get _moveText {
    return widget.moveText ??
        widget.localization.macosMoveToApplicationsMoveText ??
        defaultDesktopUpdateLocalization.macosMoveToApplicationsMoveText!;
  }

  String get _skipText {
    return widget.skipText ??
        widget.localization.macosMoveToApplicationsSkipText ??
        defaultDesktopUpdateLocalization.macosMoveToApplicationsSkipText!;
  }

  String get _replaceTitleText {
    return widget.replaceTitleText ??
        widget.localization.macosMoveToApplicationsReplaceTitleText ??
        defaultDesktopUpdateLocalization
            .macosMoveToApplicationsReplaceTitleText!;
  }

  String get _replaceBodyText {
    return widget.replaceBodyText ??
        widget.localization.macosMoveToApplicationsReplaceBodyText ??
        defaultDesktopUpdateLocalization
            .macosMoveToApplicationsReplaceBodyText!;
  }

  String get _replaceText {
    return widget.replaceText ??
        widget.localization.macosMoveToApplicationsReplaceText ??
        defaultDesktopUpdateLocalization.macosMoveToApplicationsReplaceText!;
  }

  String get _cancelText {
    return widget.cancelText ??
        widget.localization.macosMoveToApplicationsCancelText ??
        defaultDesktopUpdateLocalization.macosMoveToApplicationsCancelText!;
  }
}
