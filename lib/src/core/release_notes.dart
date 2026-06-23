const _knownTypes = {"feat", "fix", "other"};
const _richFormat = "desktop_updater.release_notes.v1";

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
    final message = _requiredString(
      json["message"],
      "release-notes.json data entries must include a non-empty message.",
    );
    return ReleaseNotesEntry(
      type: _knownTypes.contains(rawType) ? rawType! : "other",
      message: message,
    );
  }

  /// Normalised type: always "feat", "fix", or "other".
  final String type;

  /// Human-readable description of the change.
  final String message;
}

/// Section type used by the richer release notes model.
enum ReleaseNotesSectionType {
  /// User-visible features or additions.
  features,

  /// Bug fixes.
  fixes,

  /// Security fixes or hardening.
  security,

  /// Breaking changes or migration notes.
  breaking,

  /// Everything else.
  other,
}

/// One item inside a release notes section.
class ReleaseNotesItem {
  /// Creates a release notes item.
  const ReleaseNotesItem({
    required this.body,
    this.title,
  });

  /// Optional short title for the change.
  final String? title;

  /// Plain-text description of the change.
  final String body;
}

/// A typed release notes section.
class ReleaseNotesSection {
  /// Creates a release notes section.
  const ReleaseNotesSection({
    required this.type,
    required this.items,
    this.title,
  });

  /// Normalized section type.
  final ReleaseNotesSectionType type;

  /// Optional section title from the hosted JSON.
  final String? title;

  /// Items in this section.
  final List<ReleaseNotesItem> items;
}

/// Parsed release notes from a hosted JSON object.
class ReleaseNotes {
  /// Creates a release notes container.
  ///
  /// [entries] keeps the contributor-friendly simple model source compatible
  /// for callers that still use [grouped].
  const ReleaseNotes({
    required this.sections,
    List<ReleaseNotesEntry>? entries,
    this.summary,
    this.locale,
  }) : _entries = entries;

  /// Parses release notes from a simple `{ "data": [...] }` object or the rich
  /// canonical `sections` shape.
  factory ReleaseNotes.fromJson(Map<String, dynamic> json) {
    if (json.containsKey("data")) {
      return _fromSimpleData(json);
    }
    return _fromRichSections(json);
  }

  final List<ReleaseNotesEntry>? _entries;

  /// All parsed entries in source order.
  List<ReleaseNotesEntry> get entries =>
      _entries ??
      _entriesFromSections(
        sections,
      );

  /// Optional top-level summary text.
  final String? summary;

  /// Optional locale identifier for the hosted notes.
  final String? locale;

  /// Rich release notes sections.
  final List<ReleaseNotesSection> sections;

  static const _typeOrder = ["feat", "fix", "other"];

  /// Normalizes simple and rich type strings into section types.
  static ReleaseNotesSectionType normalizeType(String? value) {
    return switch (value?.trim().toLowerCase()) {
      "feat" || "feature" || "features" => ReleaseNotesSectionType.features,
      "fix" ||
      "fixes" ||
      "bugfix" ||
      "bugfixes" =>
        ReleaseNotesSectionType.fixes,
      "security" => ReleaseNotesSectionType.security,
      "breaking" ||
      "breaking_change" ||
      "breaking-change" ||
      "breaking_changes" ||
      "breaking-changes" =>
        ReleaseNotesSectionType.breaking,
      "other" || "chore" || null || "" => ReleaseNotesSectionType.other,
      _ => ReleaseNotesSectionType.other,
    };
  }

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

/// State for optional release notes loading.
sealed class ReleaseNotesState {
  /// Creates release notes state.
  const ReleaseNotesState();
}

/// No release notes request has started.
final class ReleaseNotesIdle extends ReleaseNotesState {
  /// Creates an idle release notes state.
  const ReleaseNotesIdle();
}

/// Release notes are being loaded.
final class ReleaseNotesLoading extends ReleaseNotesState {
  /// Creates a loading release notes state.
  const ReleaseNotesLoading();
}

/// Release notes loaded successfully.
final class ReleaseNotesLoaded extends ReleaseNotesState {
  /// Creates a loaded release notes state.
  const ReleaseNotesLoaded(this.notes);

  /// Loaded notes.
  final ReleaseNotes notes;
}

/// Release notes loading failed.
final class ReleaseNotesFailed extends ReleaseNotesState {
  /// Creates a failed release notes state.
  const ReleaseNotesFailed(this.error);

  /// Error thrown by the loader or fetcher.
  final Object error;
}

ReleaseNotes _fromSimpleData(Map<String, dynamic> json) {
  final data = json["data"];
  if (data is! List) {
    throw const FormatException("release-notes.json data must be a list.");
  }
  final entries = <ReleaseNotesEntry>[];
  for (final entry in data) {
    if (entry is! Map) {
      throw const FormatException(
        "release-notes.json data entries must be objects.",
      );
    }
    entries.add(
      ReleaseNotesEntry.fromJson(Map<String, dynamic>.from(entry)),
    );
  }
  return ReleaseNotes(
    entries: List.unmodifiable(entries),
    sections: List.unmodifiable(_sectionsFromEntries(entries)),
  );
}

ReleaseNotes _fromRichSections(Map<String, dynamic> json) {
  final schemaVersion = json["schemaVersion"];
  if (schemaVersion != null && schemaVersion != 1) {
    throw const FormatException(
      "release-notes.json schemaVersion must be 1 when provided.",
    );
  }

  final format = json["format"];
  if (format != null && format != _richFormat) {
    throw const FormatException(
      "release-notes.json format must be desktop_updater.release_notes.v1.",
    );
  }

  final sectionsValue = json["sections"];
  if (sectionsValue == null) {
    return ReleaseNotes(
      sections: const [],
      summary: _optionalString(json["summary"], "release-notes.json summary"),
      locale: _optionalString(json["locale"], "release-notes.json locale"),
    );
  }
  if (sectionsValue is! List) {
    throw const FormatException("release-notes.json sections must be a list.");
  }

  final sections = <ReleaseNotesSection>[];
  for (final sectionValue in sectionsValue) {
    if (sectionValue is! Map) {
      throw const FormatException(
        "release-notes.json section entries must be objects.",
      );
    }
    final sectionJson = Map<String, dynamic>.from(sectionValue);
    final itemsValue = sectionJson["items"];
    if (itemsValue is! List) {
      throw const FormatException(
        "release-notes.json section items must be a list.",
      );
    }

    final items = <ReleaseNotesItem>[];
    for (final itemValue in itemsValue) {
      if (itemValue is! Map) {
        throw const FormatException(
          "release-notes.json items must be objects.",
        );
      }
      final itemJson = Map<String, dynamic>.from(itemValue);
      items.add(
        ReleaseNotesItem(
          title: _optionalString(
            itemJson["title"],
            "release-notes.json item title",
          ),
          body: _requiredString(
            itemJson["body"],
            "release-notes.json items must include a non-empty body.",
          ),
        ),
      );
    }

    sections.add(
      ReleaseNotesSection(
        type: ReleaseNotes.normalizeType(sectionJson["type"] as String?),
        title: _optionalString(
          sectionJson["title"],
          "release-notes.json section title",
        ),
        items: List.unmodifiable(items),
      ),
    );
  }

  return ReleaseNotes(
    entries: List.unmodifiable(_entriesFromSections(sections)),
    sections: List.unmodifiable(sections),
    summary: _optionalString(json["summary"], "release-notes.json summary"),
    locale: _optionalString(json["locale"], "release-notes.json locale"),
  );
}

List<ReleaseNotesSection> _sectionsFromEntries(
  List<ReleaseNotesEntry> entries,
) {
  final buckets = <String, List<ReleaseNotesEntry>>{};
  for (final entry in entries) {
    buckets.putIfAbsent(entry.type, () => []).add(entry);
  }

  return [
    for (final type in ReleaseNotes._typeOrder)
      if (buckets.containsKey(type))
        ReleaseNotesSection(
          type: ReleaseNotes.normalizeType(type),
          items: [
            for (final entry in buckets[type]!)
              ReleaseNotesItem(body: entry.message),
          ],
        ),
  ];
}

List<ReleaseNotesEntry> _entriesFromSections(
  List<ReleaseNotesSection> sections,
) {
  return [
    for (final section in sections)
      for (final item in section.items)
        ReleaseNotesEntry(
          type: _legacyTypeForSection(section.type),
          message: item.body,
        ),
  ];
}

String _legacyTypeForSection(ReleaseNotesSectionType type) {
  return switch (type) {
    ReleaseNotesSectionType.features => "feat",
    ReleaseNotesSectionType.fixes => "fix",
    ReleaseNotesSectionType.security ||
    ReleaseNotesSectionType.breaking ||
    ReleaseNotesSectionType.other =>
      "other",
  };
}

String _requiredString(Object? value, String message) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException(message);
  }
  return value;
}

String? _optionalString(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException("$field must be a string.");
  }
  return value.trim().isEmpty ? null : value;
}
