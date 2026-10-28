import "dart:collection";
import "dart:convert";

/// Decodes helper JSON, rejecting duplicate keys and trailing content.
Object? decodeStrictNativeInstallHelperJson(String source) {
  _DuplicateKeyScanner(source).scan();
  try {
    return jsonDecode(source);
  } on FormatException {
    throw const NativeInstallHelperContractFailure("invalidJson");
  }
}

/// Strictly decodes and canonicalizes a helper JSON document.
String canonicalizeNativeInstallHelperJson(String source) {
  return canonicalNativeInstallHelperJson(
    decodeStrictNativeInstallHelperJson(source),
  );
}

/// Encodes helper JSON with recursive UTF-8 key ordering.
String canonicalNativeInstallHelperJson(Object? value) {
  return jsonEncode(_sortJson(value));
}

Object? _sortJson(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>(_compareUtf8Strings);
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const NativeInstallHelperContractFailure("nonStringObjectKey");
      }
      sorted[entry.key as String] = _sortJson(entry.value);
    }
    return sorted;
  }
  if (value is List) {
    return value.map(_sortJson).toList();
  }
  if (value is double && !value.isFinite) {
    throw const NativeInstallHelperContractFailure("nonFiniteNumber");
  }
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  throw const NativeInstallHelperContractFailure("unsupportedJsonValue");
}

int _compareUtf8Strings(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final sharedLength = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < sharedLength; index += 1) {
    final comparison = leftBytes[index].compareTo(rightBytes[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return leftBytes.length.compareTo(rightBytes.length);
}

/// A stable failure code shared by helper tools and conformance fixtures.
final class NativeInstallHelperContractFailure implements Exception {
  /// Creates a failure with its protocol code.
  const NativeInstallHelperContractFailure(this.code);

  /// The machine-readable failure code.
  final String code;

  @override
  String toString() => code;
}

final class _DuplicateKeyScanner {
  _DuplicateKeyScanner(this.source);

  final String source;
  int _index = 0;

  void scan() {
    _skipWhitespace();
    _scanValue();
    _skipWhitespace();
    if (_index != source.length) {
      _invalid();
    }
  }

  void _scanValue() {
    if (_index >= source.length) {
      _invalid();
    }
    switch (source.codeUnitAt(_index)) {
      case 0x7b:
        _scanObject();
      case 0x5b:
        _scanArray();
      case 0x22:
        _scanString();
      case 0x74:
        _scanLiteral("true");
      case 0x66:
        _scanLiteral("false");
      case 0x6e:
        _scanLiteral("null");
      default:
        _scanNumber();
    }
  }

  void _scanObject() {
    _index += 1;
    _skipWhitespace();
    if (_consume(0x7d)) {
      return;
    }
    final keys = <String>{};
    while (true) {
      if (_index >= source.length || source.codeUnitAt(_index) != 0x22) {
        _invalid();
      }
      final key = _scanString();
      if (!keys.add(key)) {
        throw NativeInstallHelperContractFailure("duplicateKey:$key");
      }
      _skipWhitespace();
      if (!_consume(0x3a)) {
        _invalid();
      }
      _skipWhitespace();
      _scanValue();
      _skipWhitespace();
      if (_consume(0x7d)) {
        return;
      }
      if (!_consume(0x2c)) {
        _invalid();
      }
      _skipWhitespace();
    }
  }

  void _scanArray() {
    _index += 1;
    _skipWhitespace();
    if (_consume(0x5d)) {
      return;
    }
    while (true) {
      _scanValue();
      _skipWhitespace();
      if (_consume(0x5d)) {
        return;
      }
      if (!_consume(0x2c)) {
        _invalid();
      }
      _skipWhitespace();
    }
  }

  String _scanString() {
    final start = _index;
    _index += 1;
    var escaped = false;
    while (_index < source.length) {
      final codeUnit = source.codeUnitAt(_index);
      _index += 1;
      if (escaped) {
        escaped = false;
        if (codeUnit == 0x75) {
          for (var count = 0; count < 4; count += 1) {
            if (_index >= source.length || !_isHex(source.codeUnitAt(_index))) {
              _invalid();
            }
            _index += 1;
          }
        } else if (!const <int>{
          0x22,
          0x5c,
          0x2f,
          0x62,
          0x66,
          0x6e,
          0x72,
          0x74,
        }.contains(codeUnit)) {
          _invalid();
        }
        continue;
      }
      if (codeUnit == 0x5c) {
        escaped = true;
      } else if (codeUnit == 0x22) {
        final literal = source.substring(start, _index);
        try {
          return jsonDecode(literal) as String;
        } on FormatException {
          _invalid();
        }
      } else if (codeUnit < 0x20) {
        _invalid();
      }
    }
    _invalid();
  }

  void _scanLiteral(String literal) {
    if (!source.startsWith(literal, _index)) {
      _invalid();
    }
    _index += literal.length;
  }

  void _scanNumber() {
    final match = _numberPattern.matchAsPrefix(source, _index);
    if (match == null) {
      _invalid();
    }
    _index = match.end;
  }

  void _skipWhitespace() {
    while (_index < source.length &&
        const <int>{0x20, 0x0a, 0x0d, 0x09}
            .contains(source.codeUnitAt(_index))) {
      _index += 1;
    }
  }

  bool _consume(int codeUnit) {
    if (_index < source.length && source.codeUnitAt(_index) == codeUnit) {
      _index += 1;
      return true;
    }
    return false;
  }

  Never _invalid() {
    throw const NativeInstallHelperContractFailure("invalidJson");
  }
}

bool _isHex(int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}

final _numberPattern = RegExp(
  r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?",
);
