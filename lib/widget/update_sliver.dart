import "package:desktop_updater/desktop_updater_inherited_widget.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_card.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// A sliver that reveals the ready-made update card when an update is active.
class DesktopUpdateSliver extends StatelessWidget {
  /// Creates a desktop update sliver.
  const DesktopUpdateSliver({
    super.key,
    required this.controller,
  });

  /// Controller that drives the update sliver.
  final DesktopUpdaterController controller;

  @override
  Widget build(BuildContext context) {
    return DesktopUpdaterInheritedNotifier(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!_shouldShowSliver(controller)) {
            return const SliverToBoxAdapter();
          }

          return const SliverAppBar.large(
            automaticallyImplyLeading: false,
            expandedHeight: 300,
            collapsedHeight: 92,
            pinned: false,
            flexibleSpace: Padding(
              padding: EdgeInsets.only(top: 16),
              child: UpdateCard(),
            ),
          );
        },
      ),
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

bool _shouldShowSliver(DesktopUpdaterController controller) {
  if (controller.skipUpdate) {
    return false;
  }

  return switch (controller.state) {
    UpdateAvailable() || UpdateDownloading() || UpdateReadyToInstall() => true,
    _ => false,
  };
}
