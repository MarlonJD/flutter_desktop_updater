import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_sliver.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// Wraps app content with the ready-made update sliver experience.
class DesktopUpdateWidget extends StatelessWidget {
  /// Creates a desktop update widget.
  const DesktopUpdateWidget({
    super.key,
    required this.controller,
    required this.child,
  });

  /// Controller that drives the ready-made update UI.
  final DesktopUpdaterController controller;

  /// Main application content rendered below the update card.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      primary: false,
      slivers: [
        DesktopUpdateSliver(controller: controller),
        SliverToBoxAdapter(
          child: child,
        ),
      ],
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
