class SourceSlice {
  const SourceSlice(this.source, this.code);

  final String source;
  final String code;

  SourceSlice sub(int start, int end) =>
      SourceSlice(source.substring(start, end), code.substring(start, end));

  SourceSlice trimmed() {
    final start = source.length - source.trimLeft().length;
    final end = source.trimRight().length;
    return sub(start, end);
  }
}

String maskNonCode(String source, {bool ruby = false}) {
  final token = ruby
      ? RegExp(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|#[^\n]*''')
      : RegExp(r'''"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/''');
  return source.replaceAllMapped(
    token,
    (match) => match.group(0)!.replaceAll(RegExp(r"[^\n]"), " "),
  );
}

int skipWhitespace(String source, int start) {
  final result = source.indexOf(RegExp(r"\S"), start);
  return result < 0 ? source.length : result;
}

int? matchingClose(String source, int open, String left, String right) {
  if (open < 0 || open >= source.length || source[open] != left) return null;
  var depth = 0;
  for (var index = open; index < source.length; index++) {
    if (source[index] == left) depth++;
    if (source[index] == right && --depth == 0) return index;
  }
  return null;
}

List<SourceSlice> splitTopLevel(SourceSlice value) {
  final result = <SourceSlice>[];
  var start = 0;
  var depth = 0;
  for (var index = 0; index < value.code.length; index++) {
    final character = value.code[index];
    if ("([{".contains(character)) depth++;
    if (")]}".contains(character)) depth--;
    if (character == "," && depth == 0) {
      result.add(value.sub(start, index).trimmed());
      start = index + 1;
    }
  }
  if (value.source.substring(start).trim().isNotEmpty) {
    result.add(value.sub(start, value.source.length).trimmed());
  }
  return result;
}

List<String> splitTopLevelText(String source) => splitTopLevel(
      SourceSlice(source, maskNonCode(source, ruby: true)),
    ).map((part) => part.source).toList();
