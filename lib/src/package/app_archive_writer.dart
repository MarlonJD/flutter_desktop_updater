import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_index.dart";

/// Creates or updates a schema v3 app archive with one release item.
Future<ReleaseIndex> upsertAppArchive({
  required File archiveFile,
  required String appName,
  required ReleaseIndexItem item,
  ReleaseSupportPolicy? supportPolicy,
}) async {
  final existing = await _readExistingIndex(archiveFile, appName);
  final items = [
    for (final existingItem in existing.items)
      if (!_isSameReleaseSlot(existingItem, item)) existingItem,
    item,
  ]..sort(_compareItems);

  final updated = ReleaseIndex(
    schemaVersion: 3,
    appName: appName,
    supportPolicy: supportPolicy ?? existing.supportPolicy,
    items: items,
  );

  await archiveFile.parent.create(recursive: true);
  await archiveFile.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert(updated.toJson())}\n",
  );

  return updated;
}

Future<ReleaseIndex> _readExistingIndex(
  File archiveFile,
  String appName,
) async {
  if (!await archiveFile.exists()) {
    return ReleaseIndex(
      schemaVersion: 3,
      appName: appName,
      supportPolicy: null,
      items: const [],
    );
  }

  final json = jsonDecode(await archiveFile.readAsString());
  return ReleaseIndex.fromJson(json as Map<String, dynamic>);
}

bool _isSameReleaseSlot(ReleaseIndexItem left, ReleaseIndexItem right) {
  return left.platform == right.platform &&
      left.channel == right.channel &&
      left.version == right.version &&
      left.buildNumber == right.buildNumber;
}

int _compareItems(ReleaseIndexItem left, ReleaseIndexItem right) {
  final platform = left.platform.compareTo(right.platform);
  if (platform != 0) {
    return platform;
  }

  final channel = left.channel.compareTo(right.channel);
  if (channel != 0) {
    return channel;
  }

  final version = left.version.compareTo(right.version);
  if (version != 0) {
    return version;
  }

  return (left.buildNumber ?? 0).compareTo(right.buildNumber ?? 0);
}
