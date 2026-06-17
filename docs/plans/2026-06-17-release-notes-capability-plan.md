# Release Notes Capability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add release notes support that accepts the contributor-friendly PR #52 JSON shape, exposes first-class custom UI controller APIs, and lets ready-made widgets show notes without making the feature a one-off `UpdateCard` bottom sheet.

**Architecture:** Treat release notes as an optional capability attached to the selected `ReleaseDescriptor`, not as part of the core download/install state. The controller owns a separate release-notes state and loader API; ready-made UI consumes that API, while custom UI can render the same data as an inline panel, side sheet, or changelog page. A later CLI slice may publish versioned `release-notes.json` files and reference them from `release.json`, but the first runtime slice must work without schema changes.

**Tech Stack:** Dart 3.6+, Flutter Material widgets, existing `DesktopUpdaterController`, `ReleaseDescriptor`, `UpdateCard`, `UpdateDialogListener`, `release publish/validate` CLI, `http`, Flutter tests via `flutter test --no-pub`, and documentation in `README.md`, `docs/ui-widgets.md`, and `docs/publishing.md`.

---

## Non-Negotiable Constraints

- Do not create, switch, rename, delete, or otherwise operate on branches unless the user explicitly asks for that branch action in the same execution turn.
- Do not post GitHub comments or review feedback through any Codex/GitHub connector identity.
- Do not commit, push, publish to pub.dev, run real uploads, or mutate production signing resources unless the user explicitly asks in the execution turn.
- Keep canonical docs, file names, type names, method names, JSON field names, and source comments in English.
- Do not mix package version bumps, changelog release headings, `README.md` dependency bumps, or `example/pubspec.lock` dependency churn into the feature implementation PR.
- Preserve the legacy cleanup guard semantically. Do not delete old-API protections just because the new release notes API needs similar words; narrow the guard to legacy surfaces or add explicit allowlists for the new capability.
- Keep update lifecycle state and release notes state separate. Do not add release notes loading to `UpdateState`.
- Support the PR #52 simple JSON shape so the contributor's endpoint format remains useful.
- Treat the richer canonical JSON shape as additive, not as a rejection of the simple shape.

## Scope Split

Implement this in two independently reviewable slices:

1. Runtime and UI capability:
   - Public release notes models.
   - Simple and rich JSON parsing.
   - Descriptor-aware `releaseNotesLoader`.
   - Convenience `releaseNotesUrl`.
   - Controller `loadReleaseNotes()` and `releaseNotesState`.
   - Ready-made bottom sheet and custom UI docs/examples.
2. CLI metadata extension:
   - Optional `releaseNotes` reference in `release.json`.
   - `release publish` config for copying and uploading `release-notes.json`.
   - `release validate` checks for notes URL reachability and JSON shape.

Do not combine the CLI metadata extension with the first runtime slice unless the user explicitly asks for a larger change.

## File Structure

- Create: `lib/src/core/release_notes.dart`
  - Public model and parser for simple and rich release notes JSON.
- Create: `lib/src/io/release_notes_fetcher.dart`
  - HTTP GET wrapper with injectable `http.Client` and explicit `close()`.
- Modify: `lib/updater_controller.dart`
  - Add `ReleaseNotesLoader`, `releaseNotesUrl`, `loadReleaseNotes()`, `canLoadReleaseNotes`, and separate release notes state/cache.
- Modify: `lib/desktop_updater.dart`
  - Export public release notes models and ready-made UI helper.
- Create: `lib/widget/release_notes_bottom_sheet.dart`
  - Ready-made Material bottom sheet that consumes the controller API.
- Modify: `lib/widget/update_card.dart`
  - Add an actionable notes icon only when notes can be loaded, and keep update failure tooltip text separate.
- Modify: `lib/src/localization.dart`
  - Add release-notes-specific labels and update-failure-tooltip labels without sharing the same fallback.
- Modify: `test/legacy_cleanup_test.dart`
  - Keep legacy API protection while allowing the new release notes capability by exact allowlist or narrower legacy tokens.
- Create: `test/release_notes_test.dart`
- Create: `test/release_notes_fetcher_test.dart`
- Create: `test/updater_controller_release_notes_test.dart`
- Create: `test/release_notes_bottom_sheet_test.dart`
- Modify: `test/update_ready_ui_test.dart`
- Modify: `docs/ui-widgets.md`
  - Add built-in and custom release notes UI patterns.
- Modify: `README.md`
  - Add a small runtime snippet without bumping the package dependency version.
- Modify later slice: `lib/src/core/release_descriptor.dart`
  - Add optional `ReleaseNotesReference`.
- Modify later slice: `lib/src/package/zip_release_packager.dart`
  - Write optional `releaseNotes` descriptor metadata.
- Modify later slice: `lib/src/release_cli/release_publish_config.dart`
  - Parse optional release notes publishing config.
- Modify later slice: `lib/src/release_cli/publish_layout.dart`
  - Add versioned release notes path and URL.
- Modify later slice: `lib/src/release_cli/publish_manifest.dart`
  - Record the generated notes file for manual upload and validate.
- Modify later slice: `lib/src/release_cli/release_publisher.dart`
  - Copy/upload notes with versioned files before `app-archive.json`.
- Modify later slice: `lib/src/release_cli/validate_command.dart`
  - Validate hosted notes shape when the descriptor references it.
- Modify later slice: `docs/publishing.md`
  - Document CLI-generated release notes metadata and upload order.

## Public Runtime Contract

The first runtime slice exposes this API shape:

```dart
typedef ReleaseNotesLoader = Future<ReleaseNotes> Function(
  ReleaseDescriptor descriptor,
);

class DesktopUpdaterController extends ChangeNotifier {
  DesktopUpdaterController({
    required Uri? appArchiveUrl,
    ReleaseNotesLoader? releaseNotesLoader,
    Uri? releaseNotesUrl,
    // existing parameters stay unchanged
  });

  bool get canLoadReleaseNotes;
  ReleaseNotesState get releaseNotesState;

  Future<ReleaseNotes> loadReleaseNotes({
    bool forceRefresh = false,
  });
}
```

State is separate from `UpdateState`:

```dart
sealed class ReleaseNotesState {
  const ReleaseNotesState();
}

final class ReleaseNotesIdle extends ReleaseNotesState {
  const ReleaseNotesIdle();
}

final class ReleaseNotesLoading extends ReleaseNotesState {
  const ReleaseNotesLoading();
}

final class ReleaseNotesLoaded extends ReleaseNotesState {
  const ReleaseNotesLoaded(this.notes);
  final ReleaseNotes notes;
}

final class ReleaseNotesFailed extends ReleaseNotesState {
  const ReleaseNotesFailed(this.error);
  final Object error;
}
```

`releaseNotesUrl` is a convenience shortcut. The preferred custom UI integration is `releaseNotesLoader`, because it receives the active `ReleaseDescriptor` and can request notes by version, platform, channel, locale, account, or environment.

## Supported JSON Shapes

### Simple Contributor-Compatible Shape

This shape is accepted to preserve PR #52's contribution intent:

```json
{
  "data": [
    { "type": "feat", "message": "Added auto test feature" },
    { "type": "fix", "message": "Fixed auto test flow" },
    { "type": "other", "message": "Maintenance" }
  ]
}
```

Parsing rules:

- `data` must be a list.
- Each entry must be an object.
- `message` must be a non-empty string.
- Missing or unknown `type` maps to `other`.
- Aliases normalize as `feat -> features`, `fix -> fixes`, and `other -> other`.

### Rich Canonical Shape

This shape is the package-owned format for richer UI and later CLI validation:

```json
{
  "schemaVersion": 1,
  "format": "desktop_updater.release_notes.v1",
  "summary": "Quality improvements.",
  "sections": [
    {
      "type": "features",
      "title": "New features",
      "items": [
        { "body": "Added auto test feature" }
      ]
    }
  ]
}
```

Parsing rules:

- `schemaVersion` must be `1` when present.
- `format` may be omitted; when present it must be `desktop_updater.release_notes.v1`.
- `summary` is optional plain text.
- `sections` must be a list.
- `sections[].type` normalizes aliases and unknown values to `other`.
- `sections[].title` is optional. Built-in UI may localize section labels instead.
- `sections[].items` must be a list.
- `items[].body` must be a non-empty plain-text string.
- `items[].title` is optional plain text.
- HTML rendering is out of scope for v1.

## Task 1: Add Release Notes Models And Parser

**Files:**
- Create: `lib/src/core/release_notes.dart`
- Modify: `lib/desktop_updater.dart`
- Test: `test/release_notes_test.dart`

- [ ] **Step 1.1: Write fail-first parser tests**

Create `test/release_notes_test.dart` with these tests:

```dart
import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("ReleaseNotes.fromJson", () {
    test("parses the simple contributor data array format", () {
      final notes = ReleaseNotes.fromJson({
        "data": [
          {"type": "feat", "message": "Added auto test feature"},
          {"type": "fix", "message": "Fixed auto test flow"},
          {"type": "other", "message": "Maintenance"},
        ],
      });

      expect(notes.sections.map((section) => section.type), [
        ReleaseNotesSectionType.features,
        ReleaseNotesSectionType.fixes,
        ReleaseNotesSectionType.other,
      ]);
      expect(notes.sections.first.items.single.body, "Added auto test feature");
    });

    test("parses the rich canonical sections format", () {
      final notes = ReleaseNotes.fromJson({
        "schemaVersion": 1,
        "format": "desktop_updater.release_notes.v1",
        "summary": "Quality improvements.",
        "sections": [
          {
            "type": "security",
            "title": "Security",
            "items": [
              {"title": "Hardening", "body": "Improved update checks."},
            ],
          },
        ],
      });

      expect(notes.summary, "Quality improvements.");
      expect(notes.sections.single.type, ReleaseNotesSectionType.security);
      expect(notes.sections.single.title, "Security");
      expect(notes.sections.single.items.single.title, "Hardening");
    });

    test("normalizes legacy type aliases", () {
      expect(
        ReleaseNotes.normalizeType("feat"),
        ReleaseNotesSectionType.features,
      );
      expect(ReleaseNotes.normalizeType("fix"), ReleaseNotesSectionType.fixes);
      expect(ReleaseNotes.normalizeType("unknown"), ReleaseNotesSectionType.other);
    });

    test("throws FormatException for malformed payloads", () {
      expect(() => ReleaseNotes.fromJson({"data": "bad"}), throwsFormatException);
      expect(
        () => ReleaseNotes.fromJson({
          "data": [
            {"type": "feat"},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => ReleaseNotes.fromJson({
          "schemaVersion": 2,
          "sections": [],
        }),
        throwsFormatException,
      );
    });
  });
}
```

Run:

```sh
flutter test --no-pub test/release_notes_test.dart
```

Expected: fail because `ReleaseNotes` does not exist.

- [ ] **Step 1.2: Implement release notes model**

Create `lib/src/core/release_notes.dart` with:

```dart
enum ReleaseNotesSectionType {
  features,
  fixes,
  security,
  breaking,
  other,
}

class ReleaseNotes {
  const ReleaseNotes({
    required this.sections,
    this.summary,
    this.locale,
  });

  factory ReleaseNotes.fromJson(Map<String, dynamic> json) {
    if (json.containsKey("data")) {
      return _fromSimpleData(json);
    }
    return _fromRichSections(json);
  }

  final String? summary;
  final String? locale;
  final List<ReleaseNotesSection> sections;

  static ReleaseNotesSectionType normalizeType(String? value) {
    return switch (value?.trim().toLowerCase()) {
      "feat" || "feature" || "features" => ReleaseNotesSectionType.features,
      "fix" || "fixes" || "bugfix" || "bugfixes" =>
        ReleaseNotesSectionType.fixes,
      "security" => ReleaseNotesSectionType.security,
      "breaking" || "breaking_change" || "breaking-changes" =>
        ReleaseNotesSectionType.breaking,
      "other" || "chore" || null || "" => ReleaseNotesSectionType.other,
      _ => ReleaseNotesSectionType.other,
    };
  }
}

class ReleaseNotesSection {
  const ReleaseNotesSection({
    required this.type,
    required this.items,
    this.title,
  });

  final ReleaseNotesSectionType type;
  final String? title;
  final List<ReleaseNotesItem> items;
}

class ReleaseNotesItem {
  const ReleaseNotesItem({
    required this.body,
    this.title,
  });

  final String? title;
  final String body;
}
```

Keep helper functions private and throw `FormatException` with field-specific messages such as:

```text
release-notes.json data must be a list.
release-notes.json data entries must include a non-empty message.
release-notes.json sections must be a list.
release-notes.json items must include a non-empty body.
```

- [ ] **Step 1.3: Export public model**

Add this export to `lib/desktop_updater.dart`:

```dart
export "package:desktop_updater/src/core/release_notes.dart";
```

- [ ] **Step 1.4: Verify model tests pass**

Run:

```sh
dart format lib/src/core/release_notes.dart test/release_notes_test.dart
flutter test --no-pub test/release_notes_test.dart
```

Expected: format succeeds and release notes parser tests pass.

## Task 2: Add Fetcher And Controller API

**Files:**
- Create: `lib/src/io/release_notes_fetcher.dart`
- Modify: `lib/updater_controller.dart`
- Test: `test/release_notes_fetcher_test.dart`
- Test: `test/updater_controller_release_notes_test.dart`

- [ ] **Step 2.1: Write fail-first fetcher tests**

Create `test/release_notes_fetcher_test.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/io/release_notes_fetcher.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

void main() {
  test("fetch parses simple JSON from a 200 response", () async {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            "data": [
              {"type": "feat", "message": "Added notes"},
            ],
          }),
          200,
        ),
      ),
    );

    final notes = await fetcher.fetch(Uri.parse("https://example.com/notes.json"));

    expect(notes.sections.single.items.single.body, "Added notes");
  });

  test("fetch throws HttpException on non-2xx response", () {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient((_) async => http.Response("Not Found", 404)),
    );

    expect(
      () => fetcher.fetch(Uri.parse("https://example.com/notes.json")),
      throwsA(isA<HttpException>()),
    );
  });

  test("fetch throws FormatException for non-object JSON", () {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient((_) async => http.Response("[]", 200)),
    );

    expect(
      () => fetcher.fetch(Uri.parse("https://example.com/notes.json")),
      throwsFormatException,
    );
  });
}
```

Run:

```sh
flutter test --no-pub test/release_notes_fetcher_test.dart
```

Expected: fail because `ReleaseNotesFetcher` does not exist.

- [ ] **Step 2.2: Implement fetcher with lifecycle**

Create `lib/src/io/release_notes_fetcher.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_notes.dart";
import "package:http/http.dart" as http;

class ReleaseNotesFetcher {
  ReleaseNotesFetcher({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  Future<ReleaseNotes> fetch(Uri url) async {
    final response = await _client.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        "Failed to fetch release notes: HTTP ${response.statusCode}",
        uri: url,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException("release-notes.json must be a JSON object.");
    }
    return ReleaseNotes.fromJson(decoded);
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
```

- [ ] **Step 2.3: Write fail-first controller tests**

Create `test/updater_controller_release_notes_test.dart` with tests for:

```dart
test("canLoadReleaseNotes is false before an update descriptor is selected", () {
  final controller = DesktopUpdaterController(
    appArchiveUrl: null,
    skipInitialVersionCheck: true,
    releaseNotesLoader: (_) async => const ReleaseNotes(sections: []),
  );

  expect(controller.canLoadReleaseNotes, isFalse);
  expect(controller.releaseNotesState, isA<ReleaseNotesIdle>());
});

test("loadReleaseNotes passes the active descriptor to the loader", () async {
  final descriptor = testReleaseDescriptor(version: "1.2.3", platform: "macos");
  ReleaseDescriptor? captured;
  final controller = ReleaseNotesControllerForTest(
    activeDescriptor: descriptor,
    releaseNotesLoader: (descriptor) async {
      captured = descriptor;
      return const ReleaseNotes(
        sections: [
          ReleaseNotesSection(
            type: ReleaseNotesSectionType.features,
            items: [ReleaseNotesItem(body: "Feature")],
          ),
        ],
      );
    },
  );

  final notes = await controller.loadReleaseNotes();

  expect(captured, descriptor);
  expect(notes.sections.single.items.single.body, "Feature");
  expect(controller.releaseNotesState, isA<ReleaseNotesLoaded>());
});

test("loadReleaseNotes caches by active descriptor until forceRefresh", () async {
  var calls = 0;
  final controller = ReleaseNotesControllerForTest(
    activeDescriptor: testReleaseDescriptor(version: "1.2.3"),
    releaseNotesLoader: (_) async {
      calls++;
      return const ReleaseNotes(sections: []);
    },
  );

  await controller.loadReleaseNotes();
  await controller.loadReleaseNotes();
  await controller.loadReleaseNotes(forceRefresh: true);

  expect(calls, 2);
});

test("loadReleaseNotes sets failed state when loader throws", () async {
  final controller = ReleaseNotesControllerForTest(
    activeDescriptor: testReleaseDescriptor(version: "1.2.3"),
    releaseNotesLoader: (_) async => throw StateError("boom"),
  );

  await expectLater(controller.loadReleaseNotes(), throwsStateError);
  expect(controller.releaseNotesState, isA<ReleaseNotesFailed>());
});
```

Use the existing descriptor fixture helpers from `test/update_ready_ui_test.dart` or create a small local `testReleaseDescriptor()` helper matching the repository's `ReleaseDescriptor` constructor.

Run:

```sh
flutter test --no-pub test/updater_controller_release_notes_test.dart
```

Expected: fail because controller APIs do not exist.

- [ ] **Step 2.4: Implement controller release notes API**

Modify `lib/updater_controller.dart`:

```dart
typedef ReleaseNotesLoader = Future<ReleaseNotes> Function(
  ReleaseDescriptor descriptor,
);

class DesktopUpdaterController extends ChangeNotifier {
  DesktopUpdaterController({
    required Uri? appArchiveUrl,
    // existing parameters...
    ReleaseNotesLoader? releaseNotesLoader,
    Uri? releaseNotesUrl,
  }) : _releaseNotesLoader = releaseNotesLoader,
       _releaseNotesUrl = releaseNotesUrl,
       _releaseNotesFetcher =
           releaseNotesUrl == null ? null : ReleaseNotesFetcher(),
       // existing initializer list...
}
```

Add:

```dart
ReleaseNotesState _releaseNotesState = const ReleaseNotesIdle();
ReleaseNotes? _cachedReleaseNotes;
String? _cachedReleaseNotesKey;

bool get canLoadReleaseNotes {
  return _activeDescriptor != null &&
      (_releaseNotesLoader != null || _releaseNotesUrl != null);
}

ReleaseNotesState get releaseNotesState => _releaseNotesState;

Future<ReleaseNotes> loadReleaseNotes({bool forceRefresh = false}) async {
  final descriptor = _activeDescriptor;
  if (descriptor == null) {
    throw StateError("No active update descriptor is available.");
  }
  if (_releaseNotesLoader == null && _releaseNotesUrl == null) {
    throw StateError("No release notes loader is configured.");
  }

  final cacheKey = _releaseNotesCacheKey(descriptor);
  if (!forceRefresh &&
      _cachedReleaseNotes != null &&
      _cachedReleaseNotesKey == cacheKey) {
    return _cachedReleaseNotes!;
  }

  _releaseNotesState = const ReleaseNotesLoading();
  notifyListeners();
  try {
    final loader = _releaseNotesLoader;
    final notes = loader == null
        ? await _releaseNotesFetcher!.fetch(_releaseNotesUrl!)
        : await loader(descriptor);
    _cachedReleaseNotes = notes;
    _cachedReleaseNotesKey = cacheKey;
    _releaseNotesState = ReleaseNotesLoaded(notes);
    notifyListeners();
    return notes;
  } on Object catch (error) {
    _releaseNotesState = ReleaseNotesFailed(error);
    notifyListeners();
    rethrow;
  }
}
```

Reset `_cachedReleaseNotes`, `_cachedReleaseNotesKey`, and `_releaseNotesState`
when `checkVersion()` starts and when no update remains selected.

Override `dispose()`:

```dart
@override
void dispose() {
  _releaseNotesFetcher?.close();
  super.dispose();
}
```

- [ ] **Step 2.5: Verify controller tests pass**

Run:

```sh
dart format lib/updater_controller.dart lib/src/io/release_notes_fetcher.dart test/release_notes_fetcher_test.dart test/updater_controller_release_notes_test.dart
flutter test --no-pub test/release_notes_fetcher_test.dart test/updater_controller_release_notes_test.dart
```

Expected: all release notes fetcher and controller tests pass.

## Task 3: Add Ready-Made Release Notes UI

**Files:**
- Create: `lib/widget/release_notes_bottom_sheet.dart`
- Modify: `lib/widget/update_card.dart`
- Modify: `lib/src/localization.dart`
- Modify: `lib/desktop_updater.dart`
- Test: `test/release_notes_bottom_sheet_test.dart`
- Test: `test/update_ready_ui_test.dart`

- [ ] **Step 3.1: Write fail-first bottom sheet tests**

Create `test/release_notes_bottom_sheet_test.dart` with widget tests for:

```text
loading state shows CircularProgressIndicator
loaded state shows summary, sections, and item bodies
empty state shows releaseNotesEmptyText
failed state shows releaseNotesErrorText and retry button
retry calls controller.loadReleaseNotes(forceRefresh: true)
localized section labels override built-in labels
```

Use a test controller subclass or controller fixture that overrides
`loadReleaseNotes()` and exposes a stable `releaseNotesState`.

Run:

```sh
flutter test --no-pub test/release_notes_bottom_sheet_test.dart
```

Expected: fail because the bottom sheet helper does not exist.

- [ ] **Step 3.2: Implement bottom sheet helper**

Create `lib/widget/release_notes_bottom_sheet.dart`:

```dart
Future<void> showReleaseNotesBottomSheet(
  BuildContext context, {
  required DesktopUpdaterController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ReleaseNotesBottomSheet(controller: controller),
  );
}

class ReleaseNotesBottomSheet extends StatelessWidget {
  const ReleaseNotesBottomSheet({
    super.key,
    required this.controller,
  });

  final DesktopUpdaterController controller;
}
```

The widget must:

- Call `controller.loadReleaseNotes()` once after opening if state is idle.
- Render from `controller.releaseNotesState` through `ListenableBuilder`.
- Use `releaseNotesTitleText`, `releaseNotesErrorText`, `releaseNotesRetryText`, `releaseNotesEmptyText`, and section label overrides.
- Keep all note text selectable only if it does not make scrolling unstable; otherwise use normal text first and add selection in a follow-up.

- [ ] **Step 3.3: Write fail-first UpdateCard tests**

Extend `test/update_ready_ui_test.dart`:

```dart
testWidgets("description icon is hidden when release notes are not configured", (tester) async {
  final controller = _ReadyUiTestController()..showAvailableUpdate();
  await tester.pumpWidget(_hostCard(controller));
  expect(find.byIcon(Icons.description_outlined), findsNothing);
});

testWidgets("description icon is shown when release notes can load", (tester) async {
  final controller = _ReadyUiTestController(
    releaseNotesLoader: (_) async => const ReleaseNotes(sections: []),
  )..showAvailableUpdate();
  await tester.pumpWidget(_hostCard(controller));
  expect(find.byIcon(Icons.description_outlined), findsOneWidget);
});

testWidgets("update failure tooltip does not reuse release notes error text", (tester) async {
  final controller = _ReadyUiTestController(
    localization: const DesktopUpdateLocalization(
      releaseNotesErrorText: "Could not load release notes.",
    ),
  )..showFailedUpdate();
  await tester.pumpWidget(_hostCard(controller));

  final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
  expect(tooltip.message, "Update failed. Please try again.");
});
```

Run:

```sh
flutter test --no-pub test/update_ready_ui_test.dart
```

Expected: fail because the icon behavior and tooltip split do not exist yet.

- [ ] **Step 3.4: Implement UpdateCard integration and localization split**

Modify `lib/src/localization.dart`:

```dart
final String? updateFailedTooltipText;
final String? releaseNotesButtonTooltipText;
final String? releaseNotesTitleText;
final Map<String, String>? releaseNotesSectionLabels;
final String? releaseNotesErrorText;
final String? releaseNotesRetryText;
final String? releaseNotesEmptyText;
```

Modify `lib/widget/update_card.dart`:

```dart
if (state is UpdateFailed)
  Tooltip(
    message: notifier.getLocalization?.updateFailedTooltipText ??
        "Update failed. Please try again.",
    child: Icon(Icons.error_outline, color: colorScheme.error),
  )
else if (notifier.canLoadReleaseNotes)
  IconButton(
    tooltip: notifier.getLocalization?.releaseNotesButtonTooltipText ??
        "Release notes",
    icon: const Icon(Icons.description_outlined),
    onPressed: () {
      unawaited(
        showReleaseNotesBottomSheet(context, controller: notifier),
      );
    },
  )
```

Export the bottom sheet helper from `lib/desktop_updater.dart`.

- [ ] **Step 3.5: Verify UI tests pass**

Run:

```sh
dart format lib/widget/release_notes_bottom_sheet.dart lib/widget/update_card.dart lib/src/localization.dart test/release_notes_bottom_sheet_test.dart test/update_ready_ui_test.dart
flutter test --no-pub test/release_notes_bottom_sheet_test.dart test/update_ready_ui_test.dart
```

Expected: bottom sheet and ready UI tests pass.

## Task 4: Publish Custom UI Examples And Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/ui-widgets.md`
- Modify: `example/lib/app.dart`
- Create: `example/lib/release_notes_examples.dart`
- Test: `test/native_helper_diagnostics_docs_test.dart` or a new docs grep test if the existing file is too specific.

- [ ] **Step 4.1: Add docs tests for custom UI examples**

Add a docs test that asserts:

```dart
test("release notes docs show built-in and custom UI patterns", () {
  final readme = File("README.md").readAsStringSync();
  final uiDocs = File("docs/ui-widgets.md").readAsStringSync();

  expect(readme, contains("releaseNotesLoader"));
  expect(readme, contains("releaseNotesUrl"));
  expect(uiDocs, contains("Release Notes Patterns"));
  expect(uiDocs, contains("Inline panel"));
  expect(uiDocs, contains("Side sheet"));
  expect(uiDocs, contains("Changelog page"));
});
```

Run:

```sh
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
```

Expected: fail until docs are updated.

- [ ] **Step 4.2: Add README quick snippets without version bump**

Add a short section to `README.md` after ready-made UI:

````markdown
## Release Notes

For the stock card, provide a release notes loader or a simple URL:

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  releaseNotesLoader: (descriptor) {
    return myNotesApi.fetch(
      version: descriptor.version,
      platform: descriptor.platform,
      channel: descriptor.channel,
    );
  },
);
```

Simple hosted notes can also use `releaseNotesUrl`. Custom UI can call
`controller.loadReleaseNotes()` and render `controller.releaseNotesState`.
````

Do not change the dependency version in the README as part of this feature PR.

- [ ] **Step 4.3: Add UI widget docs with four patterns**

Add `## Release Notes Patterns` to `docs/ui-widgets.md` with:

1. Built-in card and bottom sheet.
2. Custom inline panel.
3. Side sheet or drawer for wide desktop screens.
4. Dedicated changelog page inside Settings > Updates.

Each pattern must use the same controller API:

```dart
final notes = await controller.loadReleaseNotes();
```

Include this warning:

```text
Do not fetch release notes directly from a widget when the controller already
has a loader. Use the controller so caching, retry state, descriptor context,
and ready-made UI stay aligned.
```

- [ ] **Step 4.4: Add example widgets**

Create `example/lib/release_notes_examples.dart` with:

```dart
class InlineReleaseNotesPanel extends StatelessWidget { ... }
class ReleaseNotesSideSheetButton extends StatelessWidget { ... }
class ChangelogPage extends StatelessWidget { ... }
```

Each widget must read `controller.releaseNotesState` and call
`controller.loadReleaseNotes()` rather than creating its own HTTP client.

Wire one non-invasive example into `example/lib/app.dart`, such as a small
section in the updates/settings area. Do not make release notes the primary
example app workflow.

- [ ] **Step 4.5: Verify docs and example compile**

Run:

```sh
dart format README.md docs/ui-widgets.md example/lib/app.dart example/lib/release_notes_examples.dart test/native_helper_diagnostics_docs_test.dart
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
flutter test --no-pub
```

Expected: docs grep passes and the full package test suite passes.

## Task 5: Keep Legacy Guard And Public Compatibility Honest

**Files:**
- Modify: `test/legacy_cleanup_test.dart`
- Modify: `test/compat/metadata_selection_220_contract_test.dart` or create `test/compat/release_notes_runtime_contract_test.dart`
- Test: `test/legacy_cleanup_test.dart`
- Test: `test/compat/release_notes_runtime_contract_test.dart`

- [ ] **Step 5.1: Write compatibility tests for new public API**

Create `test/compat/release_notes_runtime_contract_test.dart`:

```dart
import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("release notes public models are exported", () {
    expect(ReleaseNotes, isNotNull);
    expect(ReleaseNotesSection, isNotNull);
    expect(ReleaseNotesItem, isNotNull);
    expect(ReleaseNotesState, isNotNull);
  });

  test("simple contributor JSON remains supported", () {
    final notes = ReleaseNotes.fromJson({
      "data": [
        {"type": "feat", "message": "Contributor shape works"},
      ],
    });

    expect(notes.sections.single.items.single.body, "Contributor shape works");
  });
}
```

Run:

```sh
flutter test --no-pub test/compat/release_notes_runtime_contract_test.dart
```

Expected: fail until Task 1 and exports are present.

- [ ] **Step 5.2: Narrow the legacy cleanup guard**

Modify `test/legacy_cleanup_test.dart` so it still prevents old 1.x folder-update API from returning, but does not block the new release notes capability.

Replace the broad forbidden token:

```dart
"releaseNotes",
```

with a precise legacy guard comment and tokens that map to old public API or files:

```dart
// Keep legacy folder-update API out of the 2.x runtime. The new release notes
// capability is allowed through ReleaseNotes models and releaseNotesLoader.
"getReleaseNotes",
"setReleaseNotes",
"ReleaseNotesModel",
```

If old 1.x source evidence shows a different exact token, use that exact token
instead of the examples above. Do not remove the test case.

- [ ] **Step 5.3: Verify compatibility and guard tests**

Run:

```sh
flutter test --no-pub test/legacy_cleanup_test.dart test/compat/release_notes_runtime_contract_test.dart
```

Expected: tests pass while legacy folder-update tokens remain blocked.

## Task 6: Plan And Implement CLI Metadata Extension As A Separate Slice

**Files:**
- Modify: `lib/src/core/release_descriptor.dart`
- Modify: `lib/src/package/zip_release_packager.dart`
- Modify: `lib/src/release_cli/release_publish_config.dart`
- Modify: `lib/src/release_cli/publish_layout.dart`
- Modify: `lib/src/release_cli/publish_manifest.dart`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `lib/src/release_cli/validate_command.dart`
- Modify: `docs/publishing.md`
- Test: `test/release_descriptor_test.dart`
- Test: `test/release_cli/release_publish_config_test.dart`
- Test: `test/release_cli/publish_layout_test.dart`
- Test: `test/release_cli/publish_manifest_test.dart`
- Test: `test/release_cli/release_publisher_build_test.dart`
- Test: `test/release_cli/release_validate_test.dart`

This task is the long-term schema/CLI plan. It should be implemented only after
Tasks 1 through 5 land or after the user explicitly asks to include CLI metadata
in the same change.

- [ ] **Step 6.1: Add descriptor reference tests**

Extend `test/release_descriptor_test.dart`:

```dart
test("parses optional release notes reference", () {
  final descriptor = ReleaseDescriptor.fromJson({
    ..._descriptorJson(),
    "releaseNotes": {
      "url": "https://updates.example.com/releases/1.31.1/windows/release-notes.json",
      "format": "desktop_updater.release_notes.v1",
    },
  });

  expect(
    descriptor.releaseNotes!.url.toString(),
    "https://updates.example.com/releases/1.31.1/windows/release-notes.json",
  );
  expect(descriptor.releaseNotes!.format, "desktop_updater.release_notes.v1");
  expect(descriptor.toJson()["releaseNotes"], isA<Map<String, dynamic>>());
});
```

Run:

```sh
flutter test --no-pub test/release_descriptor_test.dart
```

Expected: fail because `releaseNotes` descriptor metadata does not exist.

- [ ] **Step 6.2: Add optional descriptor metadata**

Add to `ReleaseDescriptor`:

```dart
final ReleaseNotesReference? releaseNotes;
```

Add:

```dart
class ReleaseNotesReference {
  const ReleaseNotesReference({
    required this.url,
    this.format = "desktop_updater.release_notes.v1",
  });

  factory ReleaseNotesReference.fromJson(Map<String, dynamic> json) { ... }

  final Uri url;
  final String format;

  Map<String, dynamic> toJson() { ... }
}
```

Validation rules:

```text
releaseNotes.url is required when releaseNotes exists
releaseNotes.url must be absolute HTTP(S)
releaseNotes.format must be desktop_updater.release_notes.v1 when present
```

`ReleaseDescriptor.toCanonicalSignatureJson()` already signs `toJson()`. The
new `releaseNotes` field becomes signed metadata only when present; old
descriptors without it remain unchanged.

- [ ] **Step 6.3: Add config and layout tests**

Extend release publish config and layout tests for:

```yaml
releaseNotes:
  source: release-notes.json
  publishPath: releases/{version}/{platform}/release-notes.json
```

Expected layout:

```text
local: dist/desktop_updater/releases/1.31.1/windows/release-notes.json
remote: https://updates.example.com/releases/1.31.1/windows/release-notes.json
```

Run:

```sh
flutter test --no-pub test/release_cli/release_publish_config_test.dart test/release_cli/publish_layout_test.dart
```

Expected: fail until config and layout support exists.

- [ ] **Step 6.4: Copy, validate, and upload notes before app archive**

Modify the publisher so `release publish`:

```text
reads releaseNotes.source
validates JSON through ReleaseNotes.fromJson
copies to versioned release output path
writes releaseNotes reference into release.json
uploads notes file with versioned files before app-archive.json
validates hosted notes after hosted release.json/artifact validation
uploads app-archive.json last
```

Manual publish output must list the notes file when present:

```text
Release notes:
https://updates.example.com/releases/1.31.1/windows/release-notes.json
```

- [ ] **Step 6.5: Add hosted validate checks**

Modify `release validate` so a descriptor with `releaseNotes`:

```text
fetches the releaseNotes.url
requires HTTP 2xx
parses the JSON with ReleaseNotes.fromJson
fails with a clear message when shape is invalid
does not require release notes when descriptor has no releaseNotes field
```

Run:

```sh
flutter test --no-pub test/release_cli/release_validate_test.dart test/release_cli/release_publisher_build_test.dart
```

Expected: tests pass.

- [ ] **Step 6.6: Document CLI-generated release notes metadata**

Update `docs/publishing.md` with:

````markdown
## Release Notes Metadata

Runtime release notes can be supplied by app code through `releaseNotesLoader`
or by publishing a versioned `release-notes.json` file.

```yaml
releaseNotes:
  source: release-notes.json
  publishPath: releases/{version}/{platform}/release-notes.json
```

`release publish` validates the JSON, writes the versioned notes file, stores a
`releaseNotes` reference in `release.json`, uploads the notes file with the
versioned release files, and uploads `app-archive.json` last.
````

Run:

```sh
flutter test --no-pub test/release_cli/release_validate_test.dart test/release_cli/release_publisher_build_test.dart
dart format docs/publishing.md
```

Expected: tests pass and docs format does not change code.

## Task 7: Final Verification And Contributor Handoff

**Files:**
- Verify all files touched in Tasks 1 through 5 for runtime slice.
- Verify CLI files too only if Task 6 is included.

- [ ] **Step 7.1: Run runtime verification**

Run:

```sh
dart format --set-exit-if-changed lib test example
flutter test --no-pub test/release_notes_test.dart test/release_notes_fetcher_test.dart test/updater_controller_release_notes_test.dart test/release_notes_bottom_sheet_test.dart test/update_ready_ui_test.dart test/legacy_cleanup_test.dart test/compat/release_notes_runtime_contract_test.dart test/native_helper_diagnostics_docs_test.dart
flutter test --no-pub
```

Expected: targeted tests and full suite pass. If `flutter analyze --no-fatal-infos`
is run, record the known analyzer-info baseline separately instead of treating
existing info debt as a feature regression.

- [ ] **Step 7.2: Confirm no release churn**

Run:

```sh
git diff -- pubspec.yaml CHANGELOG.md README.md example/pubspec.lock
```

Expected:

```text
pubspec.yaml has no version bump.
CHANGELOG.md has no release heading unless the maintainer explicitly asked.
README.md does not bump the dependency version.
example/pubspec.lock has no dependency churn.
README.md only contains feature docs when Task 4 is in scope.
```

- [ ] **Step 7.3: Draft contributor-friendly PR response**

Prepare this text for the maintainer to post manually:

```markdown
Thanks for the PR. The need is real: the icon should not be decorative, and the
simple `{ "data": [...] }` release-notes shape is useful.

I am going to keep the contribution direction but fold it into a slightly wider
package API:

- support your simple `data` format,
- add a descriptor-aware `releaseNotesLoader` for custom UI,
- keep `releaseNotesUrl` as a convenience path,
- expose controller state for custom inline panels, side sheets, or changelog
  pages,
- make `UpdateCard` consume the same public API,
- keep version bumps and lockfile churn out of this feature PR.

That should make the feature work for the built-in card without trapping it
inside the built-in card.
```

Do not post it through any Codex/GitHub connector identity.

## Execution Prompt

Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement `docs/plans/2026-06-17-release-notes-capability-plan.md`. Keep canonical docs and source identifiers in English. First implement the runtime slice: public `ReleaseNotes` models, simple and rich JSON parsing, descriptor-aware `releaseNotesLoader`, convenience `releaseNotesUrl`, `controller.loadReleaseNotes()`, separate `releaseNotesState`, ready-made `UpdateCard` bottom sheet integration, custom UI docs/examples, and compatibility tests. Preserve PR #52's `{ "data": [...] }` JSON shape. Do not include package version bumps, release changelog headings, README dependency bumps, `example/pubspec.lock` churn, branch operations, commits, pushes, GitHub comments, or pub.dev publishing unless the user explicitly asks in the same execution turn. Treat CLI-generated `releaseNotes` metadata in `release.json` as a separate second slice unless the user explicitly widens scope. Run the targeted tests listed in Task 7 and report passed, skipped, and blocked checks separately.
