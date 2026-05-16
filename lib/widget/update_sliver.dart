import "package:desktop_updater/desktop_updater_inherited_widget.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_card.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// Desktop update sliver widget, it is used to show update card in sliver
/// app bar when update is available
class DesktopUpdateSliver extends StatefulWidget {
  /// Default constructor
  const DesktopUpdateSliver({super.key, required this.controller});

  /// [DesktopUpdaterController] instance
  final DesktopUpdaterController controller;

  @override
  State<DesktopUpdateSliver> createState() => _DesktopUpdateSliverState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
    );
  }
}

class _DesktopUpdateSliverState extends State<DesktopUpdateSliver> {
  @override
  Widget build(BuildContext context) {
    return DesktopUpdaterInheritedNotifier(
      controller: widget.controller,
      child: StatefulBuilder(
        builder: (context, setState) {
          final desktopInheritedNotifier = DesktopUpdaterInheritedNotifier.of(
            context,
          );
          final notifier = desktopInheritedNotifier?.notifier;

          if (((notifier?.needUpdate ?? false) == false) ||
              (notifier?.skipUpdate ?? false)) {
            // Empty sliver empty to avoid error
            return const SliverToBoxAdapter();
          } else {
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
          }
        },
      ),
    );
  }
}
