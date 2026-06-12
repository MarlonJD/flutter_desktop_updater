import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";

/// Exposes a [DesktopUpdaterController] to ready-made or custom update UI.
class DesktopUpdaterInheritedNotifier
    extends InheritedNotifier<DesktopUpdaterController> {
  /// Creates an inherited notifier for [controller].
  const DesktopUpdaterInheritedNotifier({
    super.key,
    required DesktopUpdaterController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Returns the nearest updater inherited notifier, if one exists.
  static DesktopUpdaterInheritedNotifier? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<DesktopUpdaterInheritedNotifier>();
  }

  /// Returns the nearest updater inherited notifier.
  static DesktopUpdaterInheritedNotifier of(BuildContext context) {
    final notifier = maybeOf(context);
    assert(
      notifier != null,
      "No DesktopUpdaterInheritedNotifier found in context.",
    );
    return notifier!;
  }
}
