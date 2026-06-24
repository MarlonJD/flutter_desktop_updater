import "dart:io";
import "dart:ui" as ui;

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

const _surfaceSize = Size(760, 300);
const _outputDirectory = "docs/assets/localization";
const _fontFamily = "DesktopUpdaterLocalizationScreenshots";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFonts(family: _fontFamily, paths: _textFontPaths);
    await _loadFonts(family: "MaterialIcons", paths: _materialIconFontPaths());
  });

  for (final example in _examples) {
    testWidgets("writes ${example.fileName}", (tester) async {
      await tester.binding.setSurfaceSize(_surfaceSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final boundaryKey = GlobalKey();
      final controller = _ScreenshotController(
        localization: example.localization,
      )..showAvailableUpdate();

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: example.seedColor,
              brightness: Brightness.light,
            ),
            fontFamily: _fontFamily,
            useMaterial3: true,
          ),
          home: RepaintBoundary(
            key: boundaryKey,
            child: DecoratedBox(
              decoration: BoxDecoration(color: example.backgroundColor),
              child: Center(
                child: SizedBox(
                  width: 700,
                  child: DesktopUpdateDirectCard(controller: controller),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File("$_outputDirectory/${example.fileName}");
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
      });
    });
  }
}

Future<void> _loadFonts({
  required String family,
  required List<String> paths,
}) async {
  final loader = FontLoader(family);
  var hasFont = false;
  for (final path in paths.where((path) => File(path).existsSync())) {
    loader.addFont(_fontData(path));
    hasFont = true;
  }
  if (!hasFont) {
    return;
  }
  await loader.load();
}

Future<ByteData> _fontData(String path) async {
  return ByteData.sublistView(await File(path).readAsBytes());
}

const _textFontPaths = [
  "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
  "/System/Library/Fonts/GeezaPro.ttc",
  "/System/Library/Fonts/SFHebrew.ttf",
  "/System/Library/Fonts/AppleSDGothicNeo.ttc",
  "/System/Library/Fonts/Hiragino Sans GB.ttc",
  "/System/Library/Fonts/Supplemental/Arial.ttf",
];

List<String> _materialIconFontPaths() {
  final flutterRoot = Platform.environment["FLUTTER_ROOT"];
  return [
    if (flutterRoot != null && flutterRoot.isNotEmpty)
      "$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf",
    "/Users/marlonjd/Developer/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf",
  ];
}

const _examples = [
  _ScreenshotExample(
    fileName: "arabic-rtl.png",
    seedColor: Color(0xFF0F766E),
    backgroundColor: Color(0xFFE6F4F1),
    localization: DesktopUpdateLocalization(
      textDirection: TextDirection.rtl,
      updateAvailableText: "يتوفر تحديث",
      newVersionAvailableText: "يتوفر {} {}",
      newVersionLongText:
          "الإصدار الجديد جاهز للتنزيل. سيؤدي ذلك إلى تنزيل {} ميغابايت.",
      downloadText: "تنزيل",
      skipThisVersionText: "تخطي هذا الإصدار",
      releaseNotesButtonTooltipText: "ملاحظات الإصدار",
    ),
  ),
  _ScreenshotExample(
    fileName: "hebrew-rtl.png",
    seedColor: Color(0xFF1D4ED8),
    backgroundColor: Color(0xFFEFF4FF),
    localization: DesktopUpdateLocalization(
      textDirection: TextDirection.rtl,
      updateAvailableText: "עדכון זמין",
      newVersionAvailableText: "{} {} זמין",
      newVersionLongText: "גרסה חדשה מוכנה להורדה. ההורדה תשתמש ב-{} מ״ב.",
      downloadText: "הורדה",
      skipThisVersionText: "דלג על גרסה זו",
      releaseNotesButtonTooltipText: "הערות גרסה",
    ),
  ),
  _ScreenshotExample(
    fileName: "japanese.png",
    seedColor: Color(0xFFB91C1C),
    backgroundColor: Color(0xFFFFF1F1),
    localization: DesktopUpdateLocalization(
      textDirection: TextDirection.ltr,
      updateAvailableText: "アップデートがあります",
      newVersionAvailableText: "{} {} を利用できます",
      newVersionLongText: "新しいバージョンをダウンロードできます。{} MB のデータを取得します。",
      downloadText: "ダウンロード",
      skipThisVersionText: "このバージョンをスキップ",
      releaseNotesButtonTooltipText: "リリースノート",
    ),
  ),
  _ScreenshotExample(
    fileName: "korean.png",
    seedColor: Color(0xFF6D28D9),
    backgroundColor: Color(0xFFF4F0FF),
    localization: DesktopUpdateLocalization(
      textDirection: TextDirection.ltr,
      updateAvailableText: "업데이트 사용 가능",
      newVersionAvailableText: "{} {} 버전을 사용할 수 있습니다",
      newVersionLongText: "새 버전을 다운로드할 준비가 되었습니다. {} MB의 데이터를 다운로드합니다.",
      downloadText: "다운로드",
      skipThisVersionText: "이 버전 건너뛰기",
      releaseNotesButtonTooltipText: "릴리스 노트",
    ),
  ),
  _ScreenshotExample(
    fileName: "cyrillic-ru.png",
    seedColor: Color(0xFF2563EB),
    backgroundColor: Color(0xFFEEF5FF),
    localization: DesktopUpdateLocalization(
      textDirection: TextDirection.ltr,
      updateAvailableText: "Доступно обновление",
      newVersionAvailableText: "Доступна версия {} {}",
      newVersionLongText:
          "Новая версия готова к загрузке. Будет загружено {} МБ.",
      downloadText: "Скачать",
      skipThisVersionText: "Пропустить эту версию",
      releaseNotesButtonTooltipText: "Примечания к выпуску",
    ),
  ),
];

class _ScreenshotExample {
  const _ScreenshotExample({
    required this.fileName,
    required this.seedColor,
    required this.backgroundColor,
    required this.localization,
  });

  final String fileName;
  final Color seedColor;
  final Color backgroundColor;
  final DesktopUpdateLocalization localization;
}

class _ScreenshotController extends DesktopUpdaterController {
  _ScreenshotController({super.localization})
    : super(
        appArchiveUrl: null,
        releaseNotesUrl: Uri.parse("https://example.com/release-notes.json"),
        skipInitialVersionCheck: true,
      );

  UpdateState _state = const UpdateIdle();

  final ReleaseDescriptor _descriptor = ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.desktop",
    appName: "Atlas Desk",
    version: "2.4.0",
    buildNumber: 240,
    platform: "linux",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://updates.example.com/atlas-desk.zip"),
      sha256: "a" * 64,
      length: 96 * 1024 * 1024,
    ),
    install: const ReleaseInstall(strategy: "wholeDirectoryReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 24),
  );

  @override
  String? get appName => "Atlas Desk";

  @override
  String? get appVersion => "2.4.0";

  @override
  bool get skipUpdate => false;

  @override
  ReleaseDescriptor? get activeDescriptor => _descriptor;

  @override
  UpdateState get state => _state;

  void showAvailableUpdate() {
    _state = UpdateAvailable(descriptor: _descriptor, mandatory: false);
    notifyListeners();
  }

  @override
  Future<void> downloadUpdate() async {}

  @override
  Future<void> makeSkipUpdate() async {}
}
