import "dart:async";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";

class InlineReleaseNotesPanel extends StatelessWidget {
  const InlineReleaseNotesPanel({
    super.key,
    required this.controller,
  });

  final DesktopUpdaterController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.canLoadReleaseNotes) {
      return const SizedBox.shrink();
    }

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      "Release notes",
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        unawaited(controller.loadReleaseNotes());
                      },
                      icon: const Icon(Icons.article_outlined),
                      label: const Text("Load"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _ReleaseNotesStateView(
                  state: controller.releaseNotesState,
                  onRetry: () {
                    unawaited(
                      controller.loadReleaseNotes(forceRefresh: true),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class ReleaseNotesSideSheetButton extends StatelessWidget {
  const ReleaseNotesSideSheetButton({
    super.key,
    required this.controller,
  });

  final DesktopUpdaterController controller;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: controller.canLoadReleaseNotes
          ? () async {
              await controller.loadReleaseNotes();
              if (!context.mounted) return;
              await showDialog<void>(
                context: context,
                builder: (context) {
                  return Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 420,
                      child: Material(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: ListenableBuilder(
                            listenable: controller,
                            builder: (context, _) {
                              return _ReleaseNotesStateView(
                                state: controller.releaseNotesState,
                                onRetry: () {
                                  unawaited(
                                    controller.loadReleaseNotes(
                                      forceRefresh: true,
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            }
          : null,
      icon: const Icon(Icons.view_sidebar_outlined),
      label: const Text("Side sheet"),
    );
  }
}

class ChangelogPage extends StatefulWidget {
  const ChangelogPage({
    super.key,
    required this.controller,
  });

  final DesktopUpdaterController controller;

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  @override
  void initState() {
    super.initState();
    if (widget.controller.canLoadReleaseNotes) {
      unawaited(widget.controller.loadReleaseNotes());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Changelog")),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            return _ReleaseNotesStateView(
              state: widget.controller.releaseNotesState,
              onRetry: () {
                unawaited(
                  widget.controller.loadReleaseNotes(forceRefresh: true),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ReleaseNotesStateView extends StatelessWidget {
  const _ReleaseNotesStateView({
    required this.state,
    required this.onRetry,
  });

  final ReleaseNotesState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      ReleaseNotesIdle() => const Text("Notes have not been loaded yet."),
      ReleaseNotesLoading() => const LinearProgressIndicator(),
      ReleaseNotesLoaded(:final notes) => _ReleaseNotesList(notes: notes),
      ReleaseNotesFailed() => Row(
          children: [
            const Expanded(child: Text("Could not load release notes.")),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text("Retry"),
            ),
          ],
        ),
    };
  }
}

class _ReleaseNotesList extends StatelessWidget {
  const _ReleaseNotesList({required this.notes});

  final ReleaseNotes notes;

  @override
  Widget build(BuildContext context) {
    final sections = notes.sections
        .where((section) => section.items.isNotEmpty)
        .toList(growable: false);
    if (sections.isEmpty) {
      return const Text("No release notes available.");
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (notes.summary != null) ...[
          Text(notes.summary!),
          const SizedBox(height: 12),
        ],
        for (final section in sections) ...[
          Text(
            section.title ?? _sectionLabel(section.type),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          for (final item in section.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text("- ${item.body}"),
            ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

String _sectionLabel(ReleaseNotesSectionType type) {
  return switch (type) {
    ReleaseNotesSectionType.features => "New features",
    ReleaseNotesSectionType.fixes => "Bug fixes",
    ReleaseNotesSectionType.security => "Security",
    ReleaseNotesSectionType.breaking => "Breaking changes",
    ReleaseNotesSectionType.other => "Other changes",
  };
}
