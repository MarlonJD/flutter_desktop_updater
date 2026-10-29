import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/native_install_helper/canonical_json.dart";
import "package:path/path.dart" as path;

/// A validated, scoped edit to an OpenStep Xcode project.
///
/// plutil owns parsing; the span reader only locates values to replace. A second
/// plutil parse must match the intended whole project before any write occurs.
class XcodeProjectEdit {
  XcodeProjectEdit._(this.file, this._original, this.objects, this._expected)
      : _spans = _SpanReader(_original).read();

  /// The app-owned project that will receive the validated edit.
  final File file;
  final String _original;
  final Map<String, dynamic> _expected;
  final _Span _spans;
  final List<_Replacement> _replacements = [];
  String? _validated;

  /// Mutable parsed project objects; use [set] to record each intended change.
  final Map<String, dynamic> objects;

  /// Reads a regular project file. Symlink checks for its parents are the
  /// caller's responsibility.
  static Future<XcodeProjectEdit> read(File file) async {
    await _requireRegularFile(file);
    final original = await file.readAsString();
    final parsed = await _parse(original);
    final objects = parsed["objects"];
    if (objects is! Map<String, dynamic>) {
      throw const FormatException("Xcode project has no objects dictionary.");
    }
    return XcodeProjectEdit._(file, original, objects, parsed);
  }

  /// Changes one field, preserving all bytes outside that field. Ancestors must
  /// already exist; new objects can be inserted as a complete dictionary.
  void set(List<String> keys, Object value) {
    if (_validated != null) throw StateError("Project edit already validated.");
    var dictionary = _expected;
    var span = _spans;
    for (final key in keys.take(keys.length - 1)) {
      dictionary = dictionary[key] as Map<String, dynamic>;
      span = span.fields[key]!;
    }
    final key = keys.last;
    final oldValue = dictionary[key];
    if (_same(oldValue, value)) return;
    final oldSpan = span.fields[key];
    final indent = _indentAt(span.end - 1);
    var encoded = _encode(value, "$indent\t");
    // Preserve reference comments in the lists whose order/inputs we repair.
    if (value is List && oldValue is List && oldSpan != null) {
      final retained = <Object?, String>{};
      for (var i = 0; i < oldValue.length; i++) {
        final item = oldSpan.items[i];
        retained[oldValue[i]] = _original.substring(item.start, item.end);
      }
      encoded =
          "(\n${value.map((item) => "$indent\t\t${retained[item] ?? _encode(item, "$indent\t\t")},\n").join()}$indent\t)";
    }
    if (oldSpan != null) {
      _replacements.add(_Replacement(oldSpan.start, oldSpan.end, encoded));
    } else {
      // Insert immediately before the closing brace. Existing indentation stays
      // intact, and multiple new keys share the same insertion point.
      _replacements.add(
        _Replacement(
          span.end - 1,
          span.end - 1,
          "\t${jsonEncode(key)} = $encoded;\n$indent",
        ),
      );
    }
    dictionary[key] = value;
  }

  String _indentAt(int offset) {
    final line =
        _original.substring(_original.lastIndexOf("\n", offset) + 1, offset);
    return RegExp(r"^[\t ]*").stringMatch(line)!;
  }

  /// Validates that the text edits made precisely the requested semantic changes.
  Future<void> validate() async {
    final edits = [..._replacements]
      ..sort((a, b) => a.start.compareTo(b.start));
    final buffer = StringBuffer();
    var cursor = 0;
    for (final edit in edits) {
      if (edit.start < cursor) {
        throw StateError("Overlapping Xcode project edits.");
      }
      buffer
        ..write(_original.substring(cursor, edit.start))
        ..write(edit.text);
      cursor = edit.end;
    }
    buffer.write(_original.substring(cursor));
    final updated = buffer.toString();
    if (!_same(await _parse(updated), _expected)) {
      throw StateError(
        "Xcode project edit changed unexpected fields; no files were written.",
      );
    }
    _validated = updated;
  }

  /// True when the validated project differs from the original.
  bool get hasChanges => _validated != _original;

  /// Atomically applies a validated edit, rejecting intervening project changes.
  Future<void> apply() async {
    final updated = _validated;
    if (updated == null) {
      throw StateError("Validate the Xcode project edit first.");
    }
    await _requireRegularFile(file);
    if (await file.readAsString() != _original) {
      throw StateError(
        "Xcode project changed during setup. Run helper-policy again.",
      );
    }
    if (updated == _original) return;
    final temporary = await file.parent.createTemp(".desktop-updater-project-");
    try {
      final pending = File(path.join(temporary.path, "project.pbxproj"));
      await pending.writeAsString(updated, flush: true);
      await pending.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

Future<void> _requireRegularFile(File file) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw FileSystemException(
      "Xcode project must be a regular file.",
      file.path,
    );
  }
}

Future<Map<String, dynamic>> _parse(String contents) async {
  final temporary =
      await Directory.systemTemp.createTemp("desktop-updater-pbx-");
  try {
    final input = File(path.join(temporary.path, "project.pbxproj"));
    await input.writeAsString(contents);
    final result = await Process.run(
      "/usr/bin/plutil",
      ["-convert", "json", "-o", "-", input.path],
    );
    if (result.exitCode != 0) {
      throw const FormatException(
        "Cannot parse Runner.xcodeproj/project.pbxproj; no project changes were written.",
      );
    }
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  } finally {
    await temporary.delete(recursive: true);
  }
}

bool _same(Object? a, Object? b) =>
    canonicalNativeInstallHelperJson(a) == canonicalNativeInstallHelperJson(b);

String _encode(Object? value, String indent) {
  if (value is Map) {
    return "{\n${value.entries.map((e) => "$indent\t${jsonEncode(e.key)} = ${_encode(e.value, "$indent\t")};\n").join()}$indent}";
  }
  if (value is List) {
    return "(\n${value.map((e) => "$indent\t${_encode(e, "$indent\t")},\n").join()}$indent)";
  }
  if (value is! String) throw StateError("Expected an OpenStep string.");
  return jsonEncode(value);
}

class _Replacement {
  const _Replacement(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

class _Span {
  _Span(this.start, this.end);
  final int start;
  int end;
  final Map<String, _Span> fields = {};
  final List<_Span> items = [];
}

/// Locates dictionaries, arrays, and scalars without interpreting their values.
/// Unsupported/ambiguous syntax fails closed; plutil validates their meaning.
class _SpanReader {
  _SpanReader(this.source);
  final String source;
  int offset = 0;

  _Span read() {
    _skip();
    final span = _value();
    _skip();
    if (offset != source.length) _fail();
    return span;
  }

  _Span _value() {
    _skip();
    final start = offset;
    final first = _peek;
    final span = _Span(start, start);
    if (first == "{" || first == "(") {
      offset++;
      _skip();
      final close = first == "{" ? "}" : ")";
      while (_peek != close) {
        if (first == "{") {
          final keySpan = _scalar();
          final raw = source.substring(keySpan.start, keySpan.end);
          final key = raw.startsWith('"') ? jsonDecode(raw) as String : raw;
          _expect("=");
          if (span.fields.containsKey(key)) _fail();
          span.fields[key] = _value();
          _expect(";");
        } else {
          final item = _value();
          _skip();
          item.end = offset; // Include a reference's trailing comment.
          span.items.add(item);
          if (_peek != close) _expect(",");
        }
        _skip();
      }
      offset++;
    } else {
      return _scalar();
    }
    span.end = offset;
    return span;
  }

  _Span _scalar() {
    _skip();
    final start = offset;
    if (_peek == '"') {
      offset++;
      while (_peek != '"') {
        if (_peek.isEmpty) _fail();
        if (_peek == r"\") offset++;
        offset++;
      }
      offset++;
    } else {
      while (_peek.isNotEmpty &&
          !RegExp(r"[\s{}()=;,]").hasMatch(_peek) &&
          !source.startsWith("/*", offset) &&
          !source.startsWith("//", offset)) {
        offset++;
      }
    }
    if (start == offset) _fail();
    return _Span(start, offset);
  }

  String get _peek => offset < source.length ? source[offset] : "";

  void _expect(String token) {
    _skip();
    if (_peek != token) _fail();
    offset++;
  }

  void _skip() {
    while (offset < source.length) {
      if (RegExp(r"\s").hasMatch(_peek)) {
        offset++;
      } else if (source.startsWith("//", offset)) {
        final end = source.indexOf("\n", offset);
        offset = end < 0 ? source.length : end + 1;
      } else if (source.startsWith("/*", offset)) {
        final end = source.indexOf("*/", offset + 2);
        if (end < 0) _fail();
        offset = end + 2;
      } else {
        break;
      }
    }
  }

  Never _fail() => throw const FormatException(
        "Unsupported or ambiguous Xcode project syntax; no project changes were written.",
      );
}
