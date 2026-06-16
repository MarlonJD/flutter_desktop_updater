import "package:desktop_updater/src/core/release_notes.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("ReleaseNotesEntry.fromJson", () {
    test("parses feat type", () {
      final entry = ReleaseNotesEntry.fromJson({
        "type": "feat",
        "message": "Add dark mode",
      });
      expect(entry.type, "feat");
      expect(entry.message, "Add dark mode");
    });

    test("parses fix type", () {
      final entry = ReleaseNotesEntry.fromJson({
        "type": "fix",
        "message": "Fix crash",
      });
      expect(entry.type, "fix");
    });

    test("parses other type", () {
      final entry = ReleaseNotesEntry.fromJson({
        "type": "other",
        "message": "Maintenance",
      });
      expect(entry.type, "other");
    });

    test("normalises null type to other", () {
      final entry = ReleaseNotesEntry.fromJson({"message": "No type"});
      expect(entry.type, "other");
    });

    test("normalises unknown type to other", () {
      final entry = ReleaseNotesEntry.fromJson({
        "type": "chore",
        "message": "Chore task",
      });
      expect(entry.type, "other");
    });
  });

  group("ReleaseNotes.fromJson", () {
    test("parses empty data array", () {
      final notes = ReleaseNotes.fromJson({"data": []});
      expect(notes.entries, isEmpty);
    });

    test("parses multiple entries", () {
      final notes = ReleaseNotes.fromJson({
        "data": [
          {"type": "feat", "message": "Feature 1"},
          {"type": "fix", "message": "Fix 1"},
        ],
      });
      expect(notes.entries, hasLength(2));
    });

    test("treats missing data key as empty", () {
      final notes = ReleaseNotes.fromJson({});
      expect(notes.entries, isEmpty);
    });
  });

  group("ReleaseNotes.grouped", () {
    test("returns feat, fix, other in fixed order regardless of source order", () {
      final notes = ReleaseNotes.fromJson({
        "data": [
          {"type": "other", "message": "Other first"},
          {"type": "fix", "message": "Fix second"},
          {"type": "feat", "message": "Feat third"},
        ],
      });
      expect(notes.grouped().keys.toList(), ["feat", "fix", "other"]);
    });

    test("omits empty buckets", () {
      final notes = ReleaseNotes.fromJson({
        "data": [
          {"type": "feat", "message": "Feature only"},
        ],
      });
      expect(notes.grouped().keys.toList(), ["feat"]);
      expect(notes.grouped(), isNot(contains("fix")));
      expect(notes.grouped(), isNot(contains("other")));
    });

    test("preserves source order within a bucket", () {
      final notes = ReleaseNotes.fromJson({
        "data": [
          {"type": "feat", "message": "First"},
          {"type": "feat", "message": "Second"},
        ],
      });
      final entries = notes.grouped()["feat"]!;
      expect(entries[0].message, "First");
      expect(entries[1].message, "Second");
    });

    test("empty entries returns empty map", () {
      expect(const ReleaseNotes([]).grouped(), isEmpty);
    });
  });
}
