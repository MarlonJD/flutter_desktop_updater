#ifndef DESKTOP_UPDATER_RUNTIME_JSON_VALUE_H_
#define DESKTOP_UPDATER_RUNTIME_JSON_VALUE_H_

#include <cstdint>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {

class JsonError : public std::runtime_error {
 public:
  explicit JsonError(const std::string& message) : std::runtime_error(message) {}
};

class JsonValue {
 public:
  enum class Type { kNull, kBoolean, kInteger, kString, kArray, kObject };
  using Array = std::vector<JsonValue>;
  using Object = std::map<std::string, JsonValue>;

  JsonValue();
  explicit JsonValue(bool value);
  explicit JsonValue(std::int64_t value);
  explicit JsonValue(std::string value);
  explicit JsonValue(Array value);
  explicit JsonValue(Object value);

  Type type() const { return type_; }
  bool boolean() const;
  std::int64_t integer() const;
  const std::string& string() const;
  const Array& array() const;
  const Object& object() const;
  Object& object();
  const JsonValue& at(const std::string& key) const;
  const JsonValue* find(const std::string& key) const;

 private:
  Type type_ = Type::kNull;
  bool boolean_ = false;
  std::int64_t integer_ = 0;
  std::string string_;
  Array array_;
  Object object_;
};

JsonValue ParseJson(const std::string& input);
std::string EncodeCanonicalJson(const JsonValue& value);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_JSON_VALUE_H_
