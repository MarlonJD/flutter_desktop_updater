import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_card.dart";
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
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (_blocksAppContent(controller.state)) {
          return Center(
            child: UpdateCard(controller: controller),
          );
        }

        return CustomScrollView(
          primary: false,
          slivers: [
            DesktopUpdateSliver(controller: controller),
            SliverToBoxAdapter(
              child: child,
            ),
          ],
        );
      },
    );
  }

  bool _blocksAppContent(UpdateState state) {
    return switch (state) {
      UpdateBlockedBySupportPolicy() => true,
      UpdateFreshInstallRequired(:final mandatory) => mandatory,
      _ => false,
    };
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
    );
  }
}
