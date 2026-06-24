import "dart:convert";

import "package:desktop_updater/desktop_updater.dart";
import "package:flutter/services.dart";
import "package:flutter/widgets.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("bundled locale loads strings and explicit overrides win", () async {
    final localization =
        await DesktopUpdateLocalizationLoader.fromBundledLocale(
      "fr",
      overrides: const DesktopUpdateLocalization(
        restartText: "Installer maintenant",
        onUpdateFailedTooltip: _customTooltip,
      ),
    );

    expect(localization.updateAvailableText, "Mise à jour disponible");
    expect(localization.restartText, "Installer maintenant");
    expect(localization.onUpdateFailedTooltip?.call(Object()), "Custom error");
  });

  test("custom asset JSON can be loaded outside bundled locales", () async {
    final bundle = _MapAssetBundle({
      "assets/i18n/desktop_updater_custom.json": jsonEncode({
        "schemaVersion": 1,
        "locale": "custom",
        "strings": {
          "downloadText": "Fetch it",
          "releaseNotesTypeLabels": {"feat": "Highlights"},
        },
      }),
    });

    final localization = await DesktopUpdateLocalizationLoader.fromAsset(
      "assets/i18n/desktop_updater_custom.json",
      bundle: bundle,
      overrides: const DesktopUpdateLocalization(
        downloadText: "Download now",
      ),
    );

    expect(localization.downloadText, "Download now");
    expect(
      localization.releaseNotesTypeLabels,
      containsPair("feat", "Highlights"),
    );
    expect(
      localization.releaseNotesTypeLabels,
      containsPair("fix", "Bug fixes"),
    );
    expect(localization.restartText, "Restart to update");
  });

  test("resolver constructor supports app-owned i18n functions", () {
    final localization = DesktopUpdateLocalization.resolvedBy(
      translate: (key, fallback) {
        return switch (key) {
          DesktopUpdateLocalizationKey.restartText => "Translated restart",
          DesktopUpdateLocalizationKey.downloadText => "Translated download",
          _ => null,
        };
      },
      onUpdateFailedTooltip: _customTooltip,
    );

    expect(localization.restartText, "Translated restart");
    expect(localization.downloadText, "Translated download");
    expect(localization.updateAvailableText, "Update available");
    expect(localization.onUpdateFailedTooltip?.call(Object()), "Custom error");
  });

  test("locale and script infer text direction with JSON override", () async {
    final bundle = _MapAssetBundle({
      "assets/i18n/ar.json": jsonEncode({
        "schemaVersion": 1,
        "locale": "ar",
        "strings": <String, Object?>{},
      }),
      "assets/i18n/az-Arab.json": jsonEncode({
        "schemaVersion": 1,
        "locale": "az-Arab",
        "strings": <String, Object?>{},
      }),
      "assets/i18n/az-Latn.json": jsonEncode({
        "schemaVersion": 1,
        "locale": "az-Latn",
        "strings": <String, Object?>{},
      }),
      "assets/i18n/en-rtl.json": jsonEncode({
        "schemaVersion": 1,
        "locale": "en",
        "textDirection": "rtl",
        "strings": <String, Object?>{},
      }),
    });

    expect(
      (await DesktopUpdateLocalizationLoader.fromAsset(
        "assets/i18n/ar.json",
        bundle: bundle,
      ))
          .textDirection,
      TextDirection.rtl,
    );
    expect(
      (await DesktopUpdateLocalizationLoader.fromAsset(
        "assets/i18n/az-Arab.json",
        bundle: bundle,
      ))
          .textDirection,
      TextDirection.rtl,
    );
    expect(
      (await DesktopUpdateLocalizationLoader.fromAsset(
        "assets/i18n/az-Latn.json",
        bundle: bundle,
      ))
          .textDirection,
      TextDirection.ltr,
    );
    expect(
      (await DesktopUpdateLocalizationLoader.fromAsset(
        "assets/i18n/en-rtl.json",
        bundle: bundle,
      ))
          .textDirection,
      TextDirection.rtl,
    );
  });
}

String _customTooltip(Object error) => "Custom error";

class _MapAssetBundle extends CachingAssetBundle {
  _MapAssetBundle(this.assets);

  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final value = assets[key];
    if (value == null) {
      throw FlutterError("Unable to load asset: $key");
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }
}
