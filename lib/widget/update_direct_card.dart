import "package:desktop_updater/desktop_updater_inherited_widget.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_card.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// Shows the ready-made update card directly when controller state needs it.
class DesktopUpdateDirectCard extends StatelessWidget {
  /// Creates a direct update card wrapper.
  const DesktopUpdateDirectCard({
    super.key,
    required this.controller,
    this.child,
  });

  /// Controller that drives the update card.
  final DesktopUpdaterController controller;

  /// Optional child kept for source compatibility with older examples.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DesktopUpdaterInheritedNotifier(
      controller: controller,
      child: const UpdateCard(),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
    );
  }
}
