import "package:desktop_updater/src/core/release_notes.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

const _defaultTypeLabels = {
  "feat": "New features",
  "fix": "Bug fixes",
  "other": "Other changes",
};

/// Opens a modal bottom sheet displaying the hosted release notes.
///
/// Fetches notes via [DesktopUpdaterController.fetchReleaseNotes] on first
/// open within a given update cycle. Shows a loading spinner while fetching
/// and an error state with a retry button if the fetch fails.
Future<void> showReleaseNotesBottomSheet(
  BuildContext context, {
  required DesktopUpdaterController notifier,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReleaseNotesSheet(notifier: notifier),
  );
}

class _ReleaseNotesSheet extends StatefulWidget {
  const _ReleaseNotesSheet({required this.notifier});

  final DesktopUpdaterController notifier;

  @override
  State<_ReleaseNotesSheet> createState() => _ReleaseNotesSheetState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<DesktopUpdaterController>("notifier", notifier),
    );
  }
}

class _ReleaseNotesSheetState extends State<_ReleaseNotesSheet> {
  late Future<ReleaseNotes> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.notifier.fetchReleaseNotes();
  }

  void _retry() {
    setState(() {
      _future = widget.notifier.fetchReleaseNotes();
    });
  }

  @override
  Widget build(BuildContext context) {
    final localization = widget.notifier.getLocalization;
    final title = localization?.releaseNotesTitleText ?? "What's new";
    final typeLabels = {
      ..._defaultTypeLabels,
      ...?localization?.releaseNotesTypeLabels,
    };
    final errorText =
        localization?.releaseNotesErrorText ?? "Could not load release notes.";
    final retryText = localization?.releaseNotesRetryText ?? "Try again";
    final emptyText =
        localization?.releaseNotesEmptyText ?? "No release notes available.";

    return DraggableScrollableSheet(
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
              child: FutureBuilder<ReleaseNotes>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            errorText,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          TextButton(
                            onPressed: _retry,
                            child: Text(retryText),
                          ),
                        ],
                      ),
                    );
                  }

                  final grouped = snapshot.data!.grouped();

                  if (grouped.isEmpty) {
                    return Center(child: Text(emptyText));
                  }

                  return ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    children: [
                      for (final entry in grouped.entries) ...[
                        Text(
                          typeLabels[entry.key] ?? entry.key,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        for (final note in entry.value)
                          Padding(
                            padding: const EdgeInsets.only(left: 8, bottom: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("• "),
                                Expanded(child: Text(note.message)),
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
  }
}
