import "package:desktop_updater/desktop_updater.dart";
import "package:flutter/material.dart";

class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  _UpdateCardState createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktopInheritedNotifier = DesktopUpdaterInheritedNotifier.of(
          context,
        );
        final notifier = desktopInheritedNotifier?.notifier;

        if (constraints.maxHeight < 100) {
          return Card.filled(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      IconButton.filled(
                        onPressed: () {},
                        icon: const Icon(Icons.update),
                      ),
                      const SizedBox(width: 16),
                      Row(
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                notifier
                                        ?.getLocalization
                                        ?.updateAvailableText ??
                                    "Update Available",
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                              ),
                              Text(
                                getLocalizedString(
                                      notifier
                                          ?.getLocalization
                                          ?.newVersionAvailableText,
                                      [notifier?.appName, notifier?.appVersion],
                                    ) ??
                                    (getLocalizedString("{} {} is available", [
                                      notifier?.appName,
                                      notifier?.appVersion,
                                    ])) ??
                                    "",
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        } else {
          return SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Card.filled(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  // color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLowest,
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Icon(
                                  Icons.update,
                                  size: 24,
                                  opticalSize: 24,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text(
                          notifier?.getLocalization?.updateAvailableText ??
                              "Update Available",
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                        ),
                        Text(
                          getLocalizedString(
                                notifier
                                    ?.getLocalization
                                    ?.newVersionAvailableText,
                                [notifier?.appName, notifier?.appVersion],
                              ) ??
                              (getLocalizedString("{} {} is available", [
                                notifier?.appName,
                                notifier?.appVersion,
                              ])) ??
                              "",
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          getLocalizedString(
                                notifier?.getLocalization?.newVersionLongText,
                                [
                                  ((notifier?.downloadSize ?? 0) / 1024 / 1024)
                                      .toStringAsFixed(2),
                                ],
                              ) ??
                              (getLocalizedString(
                                "New version is ready to download, click the button below to start downloading. This will download {} MB of data.",
                                [
                                  ((notifier?.downloadSize ?? 0) / 1024 / 1024)
                                      .toStringAsFixed(2),
                                ],
                              )) ??
                              "",
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            if ((notifier?.isDownloading ?? false) &&
                                !(notifier?.isDownloaded ?? false))
                              Row(
                                children: [
                                  FilledButton.icon(
                                    icon: SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        value: notifier?.downloadProgress,
                                      ),
                                    ),
                                    label: Row(
                                      children: [
                                        Text(
                                          "${((notifier?.downloadProgress ?? 0.0) * 100).toInt()}% (${((notifier?.downloadedSize ?? 0.0) / 1024 / 1024).toStringAsFixed(2)} MB / ${((notifier?.downloadSize ?? 0.0) / 1024 / 1024).toStringAsFixed(2)} MB)",
                                        ),
                                      ],
                                    ),
                                    onPressed: null,
                                  ),
                                ],
                              )
                            else if (notifier?.isDownloading == false &&
                                (notifier?.isDownloaded ?? false))
                              FilledButton.icon(
                                icon: const Icon(Icons.restart_alt),
                                label: Text(
                                  notifier?.getLocalization?.restartText ??
                                      "Restart to update",
                                ),
                                onPressed: () {
                                  showDialog(
                                    context: context,
                                    builder: (context) {
                                      return AlertDialog(
                                        title: Text(
                                          notifier
                                                  ?.getLocalization
                                                  ?.warningTitleText ??
                                              "Are you sure?",
                                        ),
                                        content: Text(
                                          notifier
                                                  ?.getLocalization
                                                  ?.restartWarningText ??
                                              "A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?",
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () {
                                              Navigator.of(context).pop();
                                            },
                                            child: Text(
                                              notifier
                                                      ?.getLocalization
                                                      ?.warningCancelText ??
                                                  "Not now",
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              notifier?.restartApp();
                                            },
                                            child: Text(
                                              notifier
                                                      ?.getLocalization
                                                      ?.warningConfirmText ??
                                                  "Restart",
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                                },
                              )
                            else
                              Row(
                                mainAxisAlignment: MainAxisAlignment.start,
                                children: [
                                  FilledButton.icon(
                                    icon: const Icon(Icons.download),
                                    label: Text(
                                      notifier?.getLocalization?.downloadText ??
                                          "Download",
                                    ),
                                    onPressed: notifier?.downloadUpdate,
                                  ),
                                  const SizedBox(width: 8),
                                  if ((notifier?.isMandatory ?? false) == false)
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.close),
                                      label: Text(
                                        notifier
                                                ?.getLocalization
                                                ?.skipThisVersionText ??
                                            "Skip this version",
                                      ),
                                      onPressed: () {
                                        notifier?.makeSkipUpdate();
                                      },
                                    ),
                                ],
                              ),
                            // Release notes
                            IconButton(
                              tooltip: "Release notes",
                              iconSize: 24,
                              onPressed: () {
                                showModalBottomSheet(
                                  context: context,
                                  showDragHandle: true,
                                  builder: (context) {
                                    return SafeArea(
                                      child: ClipRRect(
                                        borderRadius: const BorderRadius.only(
                                          topLeft: Radius.circular(22),
                                          topRight: Radius.circular(22),
                                        ),
                                        child: DraggableScrollableSheet(
                                          expand: false,
                                          shouldCloseOnMinExtent: false,
                                          snapSizes: const [0.6, 1],
                                          initialChildSize: 0.6,
                                          minChildSize: 0.6,
                                          snap: true,
                                          builder: (context, scrollController) {
                                            return StatefulBuilder(
                                              builder: (context, setState) {
                                                return GestureDetector(
                                                  onTap: () {
                                                    FocusScope.of(
                                                      context,
                                                    ).unfocus();
                                                  },
                                                  child: Scaffold(
                                                    backgroundColor:
                                                        Theme.of(context)
                                                            .colorScheme
                                                            .surfaceContainerLow,
                                                    body: Padding(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                          ),
                                                      child: CustomScrollView(
                                                        controller:
                                                            scrollController,
                                                        slivers: <Widget>[
                                                          SliverList(
                                                            delegate: SliverChildListDelegate([
                                                              Text(
                                                                "Release notes",
                                                                style: Theme.of(context)
                                                                    .textTheme
                                                                    .bodyLarge
                                                                    ?.copyWith(
                                                                      color: Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface,
                                                                    ),
                                                              ),
                                                              const SizedBox(
                                                                height: 16,
                                                              ),
                                                              Text(
                                                                notifier?.releaseNotes
                                                                        ?.map(
                                                                          (e) =>
                                                                              "• ${e?.message}\n",
                                                                        )
                                                                        .join() ??
                                                                    "",
                                                                style: Theme.of(context)
                                                                    .textTheme
                                                                    .bodyMedium
                                                                    ?.copyWith(
                                                                      color: Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurfaceVariant,
                                                                    ),
                                                              ),
                                                            ]),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    bottomNavigationBar: Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            bottom: 8,
                                                          ),
                                                      child: Container(
                                                        margin: EdgeInsets.zero,
                                                        decoration: BoxDecoration(
                                                          borderRadius:
                                                              const BorderRadius.all(
                                                                Radius.circular(
                                                                  12,
                                                                ),
                                                              ),
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .surfaceContainerLow,
                                                        ),
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 8,
                                                            ),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .end,
                                                          children: [
                                                            TextButton(
                                                              onPressed: () {
                                                                Navigator.of(
                                                                  context,
                                                                ).pop();
                                                              },
                                                              child: const Text(
                                                                "Close",
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                              icon: const Icon(Icons.description_outlined),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }
      },
    );
  }
}
