import "package:desktop_updater_example/main.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  testWidgets("shows the 2.x zip-first demo surface", (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text("desktop_updater 2.x demo"), findsOneWidget);
    expect(
      find.text("app-archive.json -> release.json -> zip"),
      findsOneWidget,
    );
    expect(find.text("Check for updates"), findsOneWidget);
    expect(
      find.textContaining("DESKTOP_UPDATER_APP_ARCHIVE_URL"),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Text && widget.data!.startsWith("Running on:"),
      ),
      findsOneWidget,
    );
  });
}
