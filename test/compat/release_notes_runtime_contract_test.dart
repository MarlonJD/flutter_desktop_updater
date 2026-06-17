import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("release notes public models are exported", () {
    expect(const ReleaseNotes(sections: []), isA<ReleaseNotes>());
    expect(
      const ReleaseNotesSection(
        type: ReleaseNotesSectionType.features,
        items: [],
      ),
      isA<ReleaseNotesSection>(),
    );
    expect(const ReleaseNotesItem(body: "Body"), isA<ReleaseNotesItem>());
    expect(const ReleaseNotesIdle(), isA<ReleaseNotesState>());
  });

  test("simple contributor JSON remains supported", () {
    final notes = ReleaseNotes.fromJson({
      "data": [
        {"type": "feat", "message": "Contributor shape works"},
      ],
    });

    expect(notes.entries.single.message, "Contributor shape works");
    expect(notes.sections.single.items.single.body, "Contributor shape works");
  });
}
