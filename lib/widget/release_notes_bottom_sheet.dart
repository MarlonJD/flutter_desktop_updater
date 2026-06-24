import "dart:async";

import "package:desktop_updater/src/core/release_notes.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

const _defaultTypeLabels = {
  "feat": "New features",
  "fix": "Bug fixes",
  "features": "New features",
  "fixes": "Bug fixes",
  "security": "Security",
  "breaking": "Breaking changes",
  "other": "Other changes",
};

/// Opens a modal bottom sheet displaying the hosted release notes.
///
/// Loads notes via [DesktopUpdaterController.loadReleaseNotes] on first open
/// within a given update cycle. Shows a loading spinner while fetching and an
/// error state with a retry button if loading fails.
Future<void> showReleaseNotesBottomSheet(
  BuildContext context, {
  DesktopUpdaterController? controller,
  DesktopUpdaterController? notifier,
}) {
  final resolved = controller ?? notifier;
  if (resolved == null) {
    throw ArgumentError.notNull("controller");
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReleaseNotesSheet(controller: resolved),
  );
}

class _ReleaseNotesSheet extends StatefulWidget {
  const _ReleaseNotesSheet({required this.controller});

  final DesktopUpdaterController controller;

  @override
  State<_ReleaseNotesSheet> createState() => _ReleaseNotesSheetState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<DesktopUpdaterController>("controller", controller),
    );
  }
}

class _ReleaseNotesSheetState extends State<_ReleaseNotesSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  void _load({bool forceRefresh = false}) {
    unawaited(
      widget.controller
          .loadReleaseNotes(forceRefresh: forceRefresh)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localization = widget.controller.getLocalization;
    final title = localization?.releaseNotesTitleText ?? "What's new";
    final typeLabels = {
      ..._defaultTypeLabels,
      ...?localization?.releaseNotesTypeLabels,
      ...?localization?.releaseNotesSectionLabels,
    };
    final errorText =
        localization?.releaseNotesErrorText ?? "Could not load release notes.";
    final retryText = localization?.releaseNotesRetryText ?? "Try again";
    final emptyText =
        localization?.releaseNotesEmptyText ?? "No release notes available.";

    final sheet = DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, child) {
                  final state = widget.controller.releaseNotesState;
                  if (state is ReleaseNotesIdle ||
                      state is ReleaseNotesLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (state is ReleaseNotesFailed) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            errorText,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          TextButton(
                            onPressed: () => _load(forceRefresh: true),
                            child: Text(retryText),
                          ),
                        ],
                      ),
                    );
                  }

                  final notes = (state as ReleaseNotesLoaded).notes;
                  final sections = notes.sections
                      .where((section) => section.items.isNotEmpty)
                      .toList(growable: false);

                  if (sections.isEmpty) {
                    return Center(child: Text(emptyText));
                  }

                  return ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    children: [
                      if (notes.summary != null) ...[
                        Text(
                          notes.summary!,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                      ],
                      for (final section in sections) ...[
                        Text(
                          section.title ??
                              _sectionLabel(section.type, typeLabels),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        for (final note in section.items)
                          Padding(
                            padding: const EdgeInsets.only(left: 8, bottom: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("• "),
                                Expanded(
                                  child: Text(
                                    note.title == null
                                        ? note.body
                                        : "${note.title}: ${note.body}",
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
    final textDirection = localization?.textDirection;
    if (textDirection == null) {
      return sheet;
    }
    return Directionality(textDirection: textDirection, child: sheet);
  }
}

String _sectionLabel(
  ReleaseNotesSectionType type,
  Map<String, String> labels,
) {
  final legacyKey = _legacySectionKey(type);
  if (legacyKey != null && labels.containsKey(legacyKey)) {
    return labels[legacyKey]!;
  }
  return labels[_sectionKey(type)] ?? _sectionKey(type);
}

String _sectionKey(ReleaseNotesSectionType type) {
  return switch (type) {
    ReleaseNotesSectionType.features => "features",
    ReleaseNotesSectionType.fixes => "fixes",
    ReleaseNotesSectionType.security => "security",
    ReleaseNotesSectionType.breaking => "breaking",
    ReleaseNotesSectionType.other => "other",
  };
}

String? _legacySectionKey(ReleaseNotesSectionType type) {
  return switch (type) {
    ReleaseNotesSectionType.features => "feat",
    ReleaseNotesSectionType.fixes => "fix",
    ReleaseNotesSectionType.other => "other",
    ReleaseNotesSectionType.security ||
    ReleaseNotesSectionType.breaking =>
      null,
  };
}
