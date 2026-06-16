const _knownTypes = {"feat", "fix", "other"};

/// One entry in a hosted release notes document.
class ReleaseNotesEntry {
  /// Creates a release notes entry.
  const ReleaseNotesEntry({required this.type, required this.message});

  /// Parses a release notes entry from JSON.
  ///
  /// The [type] field is normalised: only "feat", "fix", and "other" are
  /// accepted. A missing or unrecognised type is mapped to "other".
  factory ReleaseNotesEntry.fromJson(Map<String, dynamic> json) {
    final rawType = json["type"] as String?;
    return ReleaseNotesEntry(
      type: _knownTypes.contains(rawType) ? rawType! : "other",
      message: json["message"] as String? ?? "",
    );
  }

  /// Normalised type: always "feat", "fix", or "other".
  final String type;

  /// Human-readable description of the change.
  final String message;
}

/// Parsed release notes from a hosted JSON object.
class ReleaseNotes {
  /// Creates a release notes container.
  const ReleaseNotes(this.entries);

  /// Parses release notes from a `{ "data": [...] }` JSON object.
  factory ReleaseNotes.fromJson(Map<String, dynamic> json) {
    final data = json["data"] as List<dynamic>? ?? [];
    return ReleaseNotes(
      data
          .map((e) => ReleaseNotesEntry.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  /// All parsed entries in source order.
  final List<ReleaseNotesEntry> entries;

  static const _typeOrder = ["feat", "fix", "other"];

  /// Groups entries by type, preserving source order within each group.
  ///
  /// Keys are always emitted in the fixed order: feat → fix → other.
  /// Buckets with no entries are omitted from the result.
  Map<String, List<ReleaseNotesEntry>> grouped() {
    final buckets = <String, List<ReleaseNotesEntry>>{};
    for (final entry in entries) {
      buckets.putIfAbsent(entry.type, () => []).add(entry);
    }
    return {
      for (final type in _typeOrder)
        if (buckets.containsKey(type)) type: buckets[type]!,
    };
  }
}
