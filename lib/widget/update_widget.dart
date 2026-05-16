import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_card.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

class DesktopUpdateWidget extends StatefulWidget {
  const DesktopUpdateWidget({
    super.key,
    required this.controller,
    required this.child,
  });

  final DesktopUpdaterController controller;
  final Widget child;

  @override
  State<DesktopUpdateWidget> createState() => _DesktopUpdateWidgetState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
    );
  }
}

class _DesktopUpdateWidgetState extends State<DesktopUpdateWidget> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      primary: false,
      slivers: <Widget>[
        DesktopUpdaterInheritedNotifier(
          controller: widget.controller,
          child: StatefulBuilder(
            builder: (context, setState) {
              final desktopInheritedNotifier =
                  DesktopUpdaterInheritedNotifier.of(context);
              final notifier = desktopInheritedNotifier?.notifier;

              if (((notifier?.needUpdate ?? false) == false) ||
                  (notifier?.skipUpdate ?? false)) {
                // Empty sliver empty to avoid error
                return const SliverToBoxAdapter();
              } else {
                return SliverAppBar.large(
                  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                  expandedHeight: 300,
                  collapsedHeight: 92,
                  pinned: false,
                  flexibleSpace: const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: UpdateCard(),
                  ),
                );
              }
            },
          ),
        ),
        SliverList(
          delegate: SliverChildListDelegate([
            const SizedBox(height: 16),
            Center(child: widget.child),
          ]),
        ),
      ],
    );
  }
}
