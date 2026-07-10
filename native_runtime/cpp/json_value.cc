#include "json_value.h"

#include <cctype>
#include <climits>
#include <cstdlib>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

class Parser {
 public:
  explicit Parser(const std::string& input) : input_(input) {}

  JsonValue Parse() {
    SkipWhitespace();
    JsonValue result = ParseValue();
    SkipWhitespace();
    if (position_ != input_.size()) {
      throw JsonError("Unexpected trailing JSON data.");
    }
    return result;
  }

 private:
  JsonValue ParseValue() {
    if (position_ >= input_.size()) {
      throw JsonError("Unexpected end of JSON input.");
    }
    switch (input_[position_]) {
      case 'n':
        ConsumeLiteral("null");
        return JsonValue();
      case 't':
        ConsumeLiteral("true");
        return JsonValue(true);
      case 'f':
        ConsumeLiteral("false");
        return JsonValue(false);
      case '"':
        return JsonValue(ParseString());
      case '[':
        return ParseArray();
      case '{':
        return ParseObject();
      default:
        return ParseInteger();
    }
  }

  JsonValue ParseArray() {
    ++position_;
    SkipWhitespace();
    JsonValue::Array result;
    if (ConsumeIf(']')) {
      return JsonValue(std::move(result));
    }
    while (true) {
      SkipWhitespace();
      result.push_back(ParseValue());
      SkipWhitespace();
      if (ConsumeIf(']')) {
        return JsonValue(std::move(result));
      }
      Require(',');
    }
  }

  JsonValue ParseObject() {
    ++position_;
    SkipWhitespace();
    JsonValue::Object result;
    if (ConsumeIf('}')) {
      return JsonValue(std::move(result));
    }
    while (true) {
      SkipWhitespace();
      if (position_ >= input_.size() || input_[position_] != '"') {
        throw JsonError("JSON object keys must be strings.");
      }
      std::string key = ParseString();
      SkipWhitespace();
      Require(':');
      SkipWhitespace();
      if (!result.emplace(key, ParseValue()).second) {
        throw JsonError("Duplicate JSON object key: " + key);
      }
      SkipWhitespace();
      if (ConsumeIf('}')) {
        return JsonValue(std::move(result));
      }
      Require(',');
    }
  }

  JsonValue ParseInteger() {
    const std::size_t start = position_;
    ConsumeIf('-');
    if (position_ >= input_.size()) {
      throw JsonError("Invalid JSON number.");
    }
    if (input_[position_] == '0') {
      ++position_;
    } else {
      if (!std::isdigit(static_cast<unsigned char>(input_[position_]))) {
        throw JsonError("Invalid JSON value.");
      }
      while (position_ < input_.size() &&
             std::isdigit(static_cast<unsigned char>(input_[position_]))) {
        ++position_;
      }
    }
    if (position_ < input_.size() &&
        (input_[position_] == '.' || input_[position_] == 'e' ||
         input_[position_] == 'E')) {
      throw JsonError("Runtime contract JSON requires integer numbers.");
    }
    const std::string text = input_.substr(start, position_ - start);
    char* end = nullptr;
    errno = 0;
    const long long value = std::strtoll(text.c_str(), &end, 10);
    if (errno == ERANGE || end == nullptr || *end != '\0') {
      throw JsonError("JSON integer is out of range.");
    }
    return JsonValue(static_cast<std::int64_t>(value));
  }

  std::string ParseString() {
    Require('"');
    std::string result;
    while (position_ < input_.size()) {
      const unsigned char byte =
          static_cast<unsigned char>(input_[position_++]);
      if (byte == '"') {
        return result;
      }
      if (byte < 0x20) {
        throw JsonError("Unescaped control byte in JSON string.");
      }
      if (byte != '\\') {
        result.push_back(static_cast<char>(byte));
        continue;
      }
      if (position_ >= input_.size()) {
        throw JsonError("Incomplete JSON escape.");
      }
      switch (input_[position_++]) {
        case '"': result.push_back('"'); break;
        case '\\': result.push_back('\\'); break;
        case '/': result.push_back('/'); break;
        case 'b': result.push_back('\b'); break;
        case 'f': result.push_back('\f'); break;
        case 'n': result.push_back('\n'); break;
        case 'r': result.push_back('\r'); break;
        case 't': result.push_back('\t'); break;
        case 'u': AppendCodePoint(ParseUnicodeScalar(), &result); break;
        default: throw JsonError("Unsupported JSON escape.");
      }
    }
    throw JsonError("Unterminated JSON string.");
  }

  std::uint32_t ParseUnicodeScalar() {
    std::uint32_t first = ParseHex4();
    if (first < 0xD800 || first > 0xDFFF) {
      return first;
    }
    if (first > 0xDBFF || position_ + 2 > input_.size() ||
        input_[position_] != '\\' || input_[position_ + 1] != 'u') {
      throw JsonError("Invalid JSON Unicode surrogate pair.");
    }
    position_ += 2;
    const std::uint32_t second = ParseHex4();
    if (second < 0xDC00 || second > 0xDFFF) {
      throw JsonError("Invalid JSON Unicode surrogate pair.");
    }
    return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
  }

  std::uint32_t ParseHex4() {
    if (position_ + 4 > input_.size()) {
      throw JsonError("Incomplete JSON Unicode escape.");
    }
    std::uint32_t value = 0;
    for (int index = 0; index < 4; ++index) {
      const char digit = input_[position_++];
      value <<= 4;
      if (digit >= '0' && digit <= '9') value += digit - '0';
      else if (digit >= 'a' && digit <= 'f') value += digit - 'a' + 10;
      else if (digit >= 'A' && digit <= 'F') value += digit - 'A' + 10;
      else throw JsonError("Invalid JSON Unicode escape.");
    }
    return value;
  }

  static void AppendCodePoint(std::uint32_t value, std::string* output) {
    if (value <= 0x7F) {
      output->push_back(static_cast<char>(value));
    } else if (value <= 0x7FF) {
      output->push_back(static_cast<char>(0xC0 | (value >> 6)));
      output->push_back(static_cast<char>(0x80 | (value & 0x3F)));
    } else if (value <= 0xFFFF) {
      output->push_back(static_cast<char>(0xE0 | (value >> 12)));
      output->push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3F)));
      output->push_back(static_cast<char>(0x80 | (value & 0x3F)));
    } else {
      output->push_back(static_cast<char>(0xF0 | (value >> 18)));
      output->push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3F)));
      output->push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3F)));
      output->push_back(static_cast<char>(0x80 | (value & 0x3F)));
    }
  }

  void SkipWhitespace() {
    while (position_ < input_.size() &&
           std::isspace(static_cast<unsigned char>(input_[position_]))) {
      ++position_;
    }
  }

  bool ConsumeIf(char value) {
    if (position_ < input_.size() && input_[position_] == value) {
      ++position_;
      return true;
    }
    return false;
  }

  void Require(char value) {
    if (!ConsumeIf(value)) {
      throw JsonError(std::string("Expected JSON token ") + value + ".");
    }
  }

  void ConsumeLiteral(const char* value) {
    const std::string literal(value);
    if (input_.compare(position_, literal.size(), literal) != 0) {
      throw JsonError("Invalid JSON literal.");
    }
    position_ += literal.size();
  }

  const std::string& input_;
  std::size_t position_ = 0;
};

void EncodeString(const std::string& value, std::ostringstream* output) {
  *output << '"';
  for (unsigned char byte : value) {
    switch (byte) {
      case '"': *output << "\\\""; break;
      case '\\': *output << "\\\\"; break;
      case '\b': *output << "\\b"; break;
      case '\f': *output << "\\f"; break;
      case '\n': *output << "\\n"; break;
      case '\r': *output << "\\r"; break;
      case '\t': *output << "\\t"; break;
      default:
        if (byte < 0x20) {
          *output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                  << static_cast<int>(byte) << std::dec;
        } else {
          *output << static_cast<char>(byte);
        }
    }
  }
  *output << '"';
}

void Encode(const JsonValue& value, std::ostringstream* output) {
  switch (value.type()) {
    case JsonValue::Type::kNull: *output << "null"; return;
    case JsonValue::Type::kBoolean:
      *output << (value.boolean() ? "true" : "false"); return;
    case JsonValue::Type::kInteger: *output << value.integer(); return;
    case JsonValue::Type::kString: EncodeString(value.string(), output); return;
    case JsonValue::Type::kArray: {
      *output << '[';
      bool first = true;
      for (const JsonValue& entry : value.array()) {
        if (!first) *output << ',';
        first = false;
        Encode(entry, output);
      }
      *output << ']';
      return;
    }
    case JsonValue::Type::kObject: {
      *output << '{';
      bool first = true;
      for (const auto& entry : value.object()) {
        if (!first) *output << ',';
        first = false;
        EncodeString(entry.first, output);
        *output << ':';
        Encode(entry.second, output);
      }
      *output << '}';
      return;
    }
  }
}

}  // namespace

JsonValue::JsonValue() = default;
JsonValue::JsonValue(bool value) : type_(Type::kBoolean), boolean_(value) {}
JsonValue::JsonValue(std::int64_t value)
    : type_(Type::kInteger), integer_(value) {}
JsonValue::JsonValue(std::string value)
    : type_(Type::kString), string_(std::move(value)) {}
JsonValue::JsonValue(Array value)
    : type_(Type::kArray), array_(std::move(value)) {}
JsonValue::JsonValue(Object value)
    : type_(Type::kObject), object_(std::move(value)) {}

bool JsonValue::boolean() const {
  if (type_ != Type::kBoolean) throw JsonError("Expected JSON boolean.");
  return boolean_;
}
std::int64_t JsonValue::integer() const {
  if (type_ != Type::kInteger) throw JsonError("Expected JSON integer.");
  return integer_;
}
const std::string& JsonValue::string() const {
  if (type_ != Type::kString) throw JsonError("Expected JSON string.");
  return string_;
}
const JsonValue::Array& JsonValue::array() const {
  if (type_ != Type::kArray) throw JsonError("Expected JSON array.");
  return array_;
}
const JsonValue::Object& JsonValue::object() const {
  if (type_ != Type::kObject) throw JsonError("Expected JSON object.");
  return object_;
}
JsonValue::Object& JsonValue::object() {
  if (type_ != Type::kObject) throw JsonError("Expected JSON object.");
  return object_;
}
const JsonValue& JsonValue::at(const std::string& key) const {
  const auto iterator = object().find(key);
  if (iterator == object().end()) throw JsonError("Missing JSON key: " + key);
  return iterator->second;
}
const JsonValue* JsonValue::find(const std::string& key) const {
  const auto iterator = object().find(key);
  return iterator == object().end() ? nullptr : &iterator->second;
}

JsonValue ParseJson(const std::string& input) { return Parser(input).Parse(); }

std::string EncodeCanonicalJson(const JsonValue& value) {
  std::ostringstream output;
  Encode(value, &output);
  return output.str();
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
