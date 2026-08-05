import "dart:convert";

/// Decodes JSON while rejecting duplicate object keys and trailing content.
Object? parseStrictJson(String source) => _StrictJsonParser(source).parse();

final class _StrictJsonParser {
  _StrictJsonParser(this._source);

  final String _source;
  var _offset = 0;

  Object? parse() {
    final value = _parseValue();
    _skipWhitespace();
    if (_offset != _source.length) {
      throw const FormatException("Unexpected trailing JSON content.");
    }
    return value;
  }

  Object? _parseValue() {
    _skipWhitespace();
    if (_offset >= _source.length) {
      throw const FormatException("Unexpected end of JSON.");
    }
    final char = _source[_offset];
    if (char == "{") return _parseObject();
    if (char == "[") return _parseArray();
    if (char == '"') return _parseString();
    if (_matches("true")) {
      _offset += 4;
      return true;
    }
    if (_matches("false")) {
      _offset += 5;
      return false;
    }
    if (_matches("null")) {
      _offset += 4;
      return null;
    }
    if (char == "-" ||
        (char == "0") ||
        (char.codeUnitAt(0) >= 0x31 && char.codeUnitAt(0) <= 0x39)) {
      return _parseNumber();
    }
    throw FormatException("Unexpected JSON character $char.");
  }

  Map<String, Object?> _parseObject() {
    _expect("{");
    final result = <String, Object?>{};
    _skipWhitespace();
    if (_tryConsume("}")) return result;
    while (true) {
      _skipWhitespace();
      if (_offset >= _source.length || _source[_offset] != '"') {
        throw const FormatException("JSON object keys must be strings.");
      }
      final key = _parseString();
      if (result.containsKey(key)) {
        throw FormatException("Duplicate JSON key $key.");
      }
      _skipWhitespace();
      _expect(":");
      result[key] = _parseValue();
      _skipWhitespace();
      if (_tryConsume("}")) return result;
      _expect(",");
    }
  }

  List<Object?> _parseArray() {
    _expect("[");
    final result = <Object?>[];
    _skipWhitespace();
    if (_tryConsume("]")) return result;
    while (true) {
      result.add(_parseValue());
      _skipWhitespace();
      if (_tryConsume("]")) return result;
      _expect(",");
    }
  }

  String _parseString() {
    final start = _offset;
    _expect('"');
    var escaped = false;
    while (_offset < _source.length) {
      final char = _source[_offset];
      if (!escaped && char == '"') {
        _offset += 1;
        try {
          return jsonDecode(_source.substring(start, _offset)) as String;
        } on FormatException {
          throw const FormatException("Invalid JSON string.");
        }
      }
      if (!escaped && char == r"\") {
        escaped = true;
      } else {
        escaped = false;
      }
      _offset += 1;
    }
    throw const FormatException("Unterminated JSON string.");
  }

  num _parseNumber() {
    final start = _offset;
    while (_offset < _source.length &&
        RegExp(r"[-+0-9.eE]").hasMatch(_source[_offset])) {
      _offset += 1;
    }
    final literal = _source.substring(start, _offset);
    if (!RegExp(
      r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$",
    ).hasMatch(literal)) {
      throw const FormatException("Invalid JSON number.");
    }
    final value = num.tryParse(literal);
    if (value == null) {
      throw const FormatException("Invalid JSON number.");
    }
    return value;
  }

  void _skipWhitespace() {
    while (_offset < _source.length &&
        const {" ", "\n", "\r", "\t"}.contains(_source[_offset])) {
      _offset += 1;
    }
  }

  bool _matches(String value) => _source.startsWith(value, _offset);

  bool _tryConsume(String value) {
    if (!_matches(value)) return false;
    _offset += value.length;
    return true;
  }

  void _expect(String value) {
    if (!_tryConsume(value)) {
      throw FormatException("Expected JSON token $value.");
    }
  }
}
