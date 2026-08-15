#include "release_contract.h"

#include <algorithm>
#include <cctype>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>

#include "optional/monocypher-ed25519.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string Trim(const std::string& value) {
  std::size_t start = 0;
  while (start < value.size() &&
         std::isspace(static_cast<unsigned char>(value[start]))) {
    ++start;
  }
  std::size_t end = value.size();
  while (end > start &&
         std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    --end;
  }
  return value.substr(start, end - start);
}

std::string RequiredString(const JsonValue& value, const std::string& key) {
  const std::string result = value.at(key).string();
  if (result.empty()) throw JsonError("Empty JSON string: " + key);
  return result;
}

std::string RequiredTrimmedString(const JsonValue& value,
                                  const std::string& key) {
  const std::string result = Trim(value.at(key).string());
  if (result.empty()) throw JsonError("Empty JSON string: " + key);
  return result;
}

bool HasScheme(const std::string& value) {
  const std::size_t separator = value.find(':');
  return separator != std::string::npos && separator > 0;
}

bool IsSafeWindowsExecutableRelativePath(const std::string& value) {
  if (value.empty() || value.front() == '/' || value.front() == '\\' ||
      value.find(':') != std::string::npos) {
    return false;
  }
  std::size_t start = 0;
  while (start < value.size()) {
    const std::size_t end = value.find_first_of("/\\", start);
    const std::string segment = value.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
    if (segment.empty() || segment == "." || segment == ".." ||
        segment.back() == '.' || segment.back() == ' ' ||
        segment.find_first_of("*?\"<>|") != std::string::npos) {
      return false;
    }
    if (end == std::string::npos) break;
    start = end + 1;
  }
  if (value.size() < 4) return false;
  std::string suffix = value.substr(value.size() - 4);
  std::transform(suffix.begin(), suffix.end(), suffix.begin(),
                 [](unsigned char byte) {
                   return static_cast<char>(std::tolower(byte));
                 });
  return suffix == ".exe";
}

std::int64_t ParseComponent(const std::string& value);

struct ParsedInstant {
  std::int64_t seconds = 0;
  int microseconds = 0;
};

bool IsLeapYear(std::int64_t year) {
  return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

int DaysInMonth(std::int64_t year, int month) {
  static const int kDays[] = {31, 28, 31, 30, 31, 30,
                              31, 31, 30, 31, 30, 31};
  return month == 2 && IsLeapYear(year) ? 29 : kDays[month - 1];
}

std::int64_t DaysFromCivil(std::int64_t year, int month, int day) {
  year -= month <= 2 ? 1 : 0;
  const std::int64_t era = (year >= 0 ? year : year - 399) / 400;
  const std::int64_t year_of_era = year - era * 400;
  const int month_prime = month + (month > 2 ? -3 : 9);
  const std::int64_t day_of_year =
      (153 * month_prime + 2) / 5 + day - 1;
  const std::int64_t day_of_era = year_of_era * 365 + year_of_era / 4 -
                                  year_of_era / 100 + day_of_year;
  return era * 146097 + day_of_era - 719468;
}

ParsedInstant ParseInstant(const std::string& value) {
  if (value.size() < 20 || value[4] != '-' || value[7] != '-' ||
      value[10] != 'T' || value[13] != ':' || value[16] != ':') {
    throw JsonError("Invalid ISO-8601 instant.");
  }
  auto number = [&value](std::size_t offset, std::size_t length) {
    return ParseComponent(value.substr(offset, length));
  };
  const std::int64_t year = number(0, 4);
  const int month = static_cast<int>(number(5, 2));
  const int day = static_cast<int>(number(8, 2));
  const int hour = static_cast<int>(number(11, 2));
  const int minute = static_cast<int>(number(14, 2));
  const int second = static_cast<int>(number(17, 2));
  if (month < 1 || month > 12 || day < 1 ||
      day > DaysInMonth(year, month) || hour > 23 || minute > 59 ||
      second > 59) {
    throw JsonError("Invalid ISO-8601 instant.");
  }

  std::size_t zone = 19;
  int microseconds = 0;
  if (zone < value.size() && value[zone] == '.') {
    ++zone;
    const std::size_t fraction_start = zone;
    int digits = 0;
    while (zone < value.size() &&
           std::isdigit(static_cast<unsigned char>(value[zone]))) {
      if (digits < 6) {
        microseconds = microseconds * 10 + (value[zone] - '0');
      }
      ++digits;
      ++zone;
    }
    if (zone == fraction_start) throw JsonError("Invalid ISO-8601 instant.");
    while (digits < 6) {
      microseconds *= 10;
      ++digits;
    }
  }

  std::int64_t offset = 0;
  if (zone < value.size() && value[zone] == 'Z' && zone + 1 == value.size()) {
    offset = 0;
  } else if (zone + 6 == value.size() &&
             (value[zone] == '+' || value[zone] == '-') &&
             value[zone + 3] == ':') {
    const int offset_hour = static_cast<int>(number(zone + 1, 2));
    const int offset_minute = static_cast<int>(number(zone + 4, 2));
    if (offset_hour > 23 || offset_minute > 59) {
      throw JsonError("Invalid ISO-8601 instant.");
    }
    offset = offset_hour * 3600 + offset_minute * 60;
    if (value[zone] == '-') offset = -offset;
  } else {
    throw JsonError("Invalid ISO-8601 instant.");
  }

  return {DaysFromCivil(year, month, day) * 86400 + hour * 3600 +
              minute * 60 + second - offset,
          microseconds};
}

std::int64_t FloorDiv(std::int64_t value, std::int64_t divisor) {
  std::int64_t quotient = value / divisor;
  if (value % divisor < 0) --quotient;
  return quotient;
}

std::string FormatInstant(const ParsedInstant& instant) {
  const std::int64_t days = FloorDiv(instant.seconds, 86400);
  const std::int64_t seconds_of_day = instant.seconds - days * 86400;
  std::int64_t civil = days + 719468;
  const std::int64_t era =
      (civil >= 0 ? civil : civil - 146096) / 146097;
  const std::int64_t day_of_era = civil - era * 146097;
  const std::int64_t year_of_era =
      (day_of_era - day_of_era / 1460 + day_of_era / 36524 -
       day_of_era / 146096) /
      365;
  std::int64_t year = year_of_era + era * 400;
  const std::int64_t day_of_year =
      day_of_era -
      (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
  const std::int64_t month_prime = (5 * day_of_year + 2) / 153;
  const int day = static_cast<int>(day_of_year -
                                   (153 * month_prime + 2) / 5 + 1);
  const int month = static_cast<int>(month_prime + (month_prime < 10 ? 3 : -9));
  year += month <= 2 ? 1 : 0;
  const int hour = static_cast<int>(seconds_of_day / 3600);
  const int minute = static_cast<int>((seconds_of_day % 3600) / 60);
  const int second = static_cast<int>(seconds_of_day % 60);

  char buffer[64];
  if (instant.microseconds % 1000 == 0) {
    std::snprintf(buffer, sizeof(buffer),
                  "%04lld-%02d-%02dT%02d:%02d:%02d.%03dZ",
                  static_cast<long long>(year), month, day, hour, minute,
                  second, instant.microseconds / 1000);
  } else {
    std::snprintf(buffer, sizeof(buffer),
                  "%04lld-%02d-%02dT%02d:%02d:%02d.%06dZ",
                  static_cast<long long>(year), month, day, hour, minute,
                  second, instant.microseconds);
  }
  return buffer;
}

std::int64_t ParseComponent(const std::string& value) {
  if (value.empty() || !std::all_of(value.begin(), value.end(), ::isdigit)) {
    throw JsonError("Invalid semantic version component.");
  }
  char* end = nullptr;
  const long long parsed = std::strtoll(value.c_str(), &end, 10);
  if (end == nullptr || *end != '\0' || parsed < 0) {
    throw JsonError("Invalid semantic version component.");
  }
  return static_cast<std::int64_t>(parsed);
}

std::vector<std::string> Split(const std::string& value, char separator) {
  std::vector<std::string> result;
  std::size_t start = 0;
  while (true) {
    const std::size_t next = value.find(separator, start);
    result.push_back(value.substr(start, next - start));
    if (next == std::string::npos) return result;
    start = next + 1;
  }
}

int ComparePrerelease(const std::vector<std::string>& left,
                      const std::vector<std::string>& right) {
  if (left.empty() != right.empty()) return left.empty() ? 1 : -1;
  const std::size_t count = std::min(left.size(), right.size());
  for (std::size_t index = 0; index < count; ++index) {
    if (left[index] == right[index]) continue;
    const bool left_numeric =
        !left[index].empty() &&
        std::all_of(left[index].begin(), left[index].end(), ::isdigit);
    const bool right_numeric =
        !right[index].empty() &&
        std::all_of(right[index].begin(), right[index].end(), ::isdigit);
    if (left_numeric && right_numeric) {
      const std::int64_t left_value = ParseComponent(left[index]);
      const std::int64_t right_value = ParseComponent(right[index]);
      return left_value < right_value ? -1 : 1;
    }
    if (left_numeric != right_numeric) return left_numeric ? -1 : 1;
    return left[index] < right[index] ? -1 : 1;
  }
  if (left.size() == right.size()) return 0;
  return left.size() < right.size() ? -1 : 1;
}

bool RolloutIncludes(const ReleaseIndexItem& item,
                     const std::string& identity,
                     const Sha256Function& sha256) {
  if (!item.has_rollout) return true;
  if (item.rollout.percentage == 100) return true;
  const std::string normalized_identity = Trim(identity);
  if (item.rollout.percentage <= 0 || normalized_identity.empty()) return false;
  const std::vector<std::uint8_t> digest = sha256(
      item.rollout.salt + "\n" + item.channel + "\n" + normalized_identity);
  if (digest.size() != 32) throw JsonError("SHA-256 provider returned bad size.");
  std::uint32_t value = 0;
  for (std::size_t index = 0; index < 4; ++index) {
    value = (value << 8) + digest[index];
  }
  return value % 100 < static_cast<std::uint32_t>(item.rollout.percentage);
}

void ValidateArtifact(const ReleaseArtifact& artifact) {
  static const std::regex kSha256("^[0-9a-f]{64}$");
  if (artifact.kind != "zip" && artifact.kind != "dmg" &&
      artifact.kind != "pkgInstaller" && artifact.kind != "innoInstaller") {
    throw JsonError("Unsupported artifact kind: " + artifact.kind);
  }
  if (!HasScheme(artifact.url)) throw JsonError("Artifact URL is not absolute.");
  if (!std::regex_match(artifact.sha256, kSha256)) {
    throw JsonError("Invalid artifact SHA-256.");
  }
  if (artifact.length < 0) throw JsonError("Invalid artifact length.");
}

bool OptionalBoolean(const JsonValue& value,
                     const std::string& key,
                     bool default_value) {
  const JsonValue* found = value.find(key);
  return found == nullptr ? default_value : found->boolean();
}

std::string OptionalStringWithDefault(const JsonValue& value,
                                      const std::string& key,
                                      const std::string& default_value) {
  const JsonValue* found = value.find(key);
  return found == nullptr ? default_value : found->string();
}

JsonValue::Array OptionalStringArray(const JsonValue& value,
                                     const std::string& key) {
  const JsonValue* found = value.find(key);
  if (found == nullptr) return {};
  JsonValue::Array result;
  for (const JsonValue& entry : found->array()) {
    if (entry.type() != JsonValue::Type::kString) {
      throw JsonError("Unsupported string-list entry.");
    }
    result.emplace_back(entry.string());
  }
  return result;
}

JsonValue NormalizeInstall(const JsonValue& install,
                           bool normalize_legacy_pkg_launch_mode = true) {
  JsonValue::Object normalized;
  normalized.emplace("strategy",
                     JsonValue(RequiredTrimmedString(install, "strategy")));
  if (const JsonValue* inno = install.find("inno")) {
    JsonValue::Object authenticode;
    const JsonValue* raw_authenticode = inno->find("authenticode");
    const bool required = raw_authenticode == nullptr
                              ? false
                              : OptionalBoolean(*raw_authenticode, "required",
                                                false);
    authenticode.emplace("required", JsonValue(required));
    if (raw_authenticode != nullptr) {
      JsonValue::Array thumbprints =
          OptionalStringArray(*raw_authenticode, "sha256Thumbprints");
      if (!thumbprints.empty()) {
        authenticode.emplace("sha256Thumbprints",
                             JsonValue(std::move(thumbprints)));
      }
    }

    JsonValue::Object metadata;
    metadata.emplace("silentArgs",
                     JsonValue(OptionalStringArray(*inno, "silentArgs")));
    metadata.emplace(
        "inheritInstallDirectory",
        JsonValue(OptionalBoolean(*inno, "inheritInstallDirectory", true)));
    metadata.emplace(
        "installedExecutableRelativePath",
        JsonValue(RequiredString(*inno, "installedExecutableRelativePath")));
    metadata.emplace(
        "installedExecutableSha256",
        JsonValue(RequiredString(*inno, "installedExecutableSha256")));
    metadata.emplace(
        "logFileName",
        JsonValue(OptionalStringWithDefault(
            *inno, "logFileName", "desktop_updater_inno_install.log")));
    metadata.emplace(
        "relaunchAfterInstall",
        JsonValue(OptionalBoolean(*inno, "relaunchAfterInstall", true)));
    metadata.emplace(
        "requiresElevation",
        JsonValue(OptionalStringWithDefault(*inno, "requiresElevation",
                                             "")));
    metadata.emplace("authenticode", JsonValue(std::move(authenticode)));
    normalized.emplace("inno", JsonValue(std::move(metadata)));
  }
  if (const JsonValue* dmg = install.find("macosDmg")) {
    JsonValue::Object metadata;
    metadata.emplace("appBundleName",
                     JsonValue(RequiredString(*dmg, "appBundleName")));
    metadata.emplace(
        "verifyPrimarySignature",
        JsonValue(OptionalBoolean(*dmg, "verifyPrimarySignature", true)));
    normalized.emplace("macosDmg", JsonValue(std::move(metadata)));
  }
  if (const JsonValue* pkg = install.find("macosPkg")) {
    JsonValue::Object metadata;
    const std::string raw_launch_mode =
        OptionalStringWithDefault(*pkg, "launchMode", "installerApp");
    metadata.emplace("launchMode",
                     JsonValue(normalize_legacy_pkg_launch_mode &&
                                       raw_launch_mode == "installerApp"
                                   ? "privilegedInstallerTool"
                                   : raw_launch_mode));
    metadata.emplace(
        "expectedPackageIds",
        JsonValue(OptionalStringArray(*pkg, "expectedPackageIds")));
    metadata.emplace(
        "relaunchAfterInstall",
        JsonValue(OptionalBoolean(*pkg, "relaunchAfterInstall", false)));
    normalized.emplace("macosPkg", JsonValue(std::move(metadata)));
  }
  return JsonValue(std::move(normalized));
}

void ValidateInstall(const ReleaseDescriptor& descriptor) {
  const std::string strategy = RequiredString(descriptor.install, "strategy");
  if (strategy == "pkgInstaller" &&
      descriptor.artifact.kind != "pkgInstaller") {
    throw JsonError("PKG strategy requires a PKG artifact.");
  }
  if (strategy == "innoInstaller" &&
      (descriptor.platform != "windows" ||
       descriptor.artifact.kind != "innoInstaller")) {
    throw JsonError("Inno strategy requires a Windows installer artifact.");
  }
  if (descriptor.artifact.kind == "dmg") {
    if (descriptor.platform != "macos" || strategy != "wholeBundleReplace") {
      throw JsonError("Invalid DMG install strategy.");
    }
    const JsonValue& metadata = descriptor.install.at("macosDmg");
    const std::string name = RequiredString(metadata, "appBundleName");
    if (name.size() < 4 || name.substr(name.size() - 4) != ".app" ||
        name.find('/') != std::string::npos) {
      throw JsonError("Invalid DMG app bundle name.");
    }
  } else if (descriptor.artifact.kind == "pkgInstaller") {
    if (descriptor.platform != "macos" || strategy != "pkgInstaller" ||
        !descriptor.has_build_number) {
      throw JsonError("Invalid PKG install strategy.");
    }
    const JsonValue& metadata = descriptor.install.at("macosPkg");
    if (RequiredString(metadata, "launchMode") !=
            "privilegedInstallerTool" ||
        metadata.at("expectedPackageIds").array().empty()) {
      throw JsonError("Invalid PKG install metadata.");
    }
  } else if (descriptor.artifact.kind == "innoInstaller") {
    if (descriptor.platform != "windows" || strategy != "innoInstaller") {
      throw JsonError("Invalid Inno install strategy.");
    }
    const JsonValue& metadata = descriptor.install.at("inno");
    const std::string installed_executable =
        RequiredString(metadata, "installedExecutableRelativePath");
    const std::string installed_executable_sha256 =
        RequiredString(metadata, "installedExecutableSha256");
    static const std::regex kInstalledExecutableSha256("^[0-9a-f]{64}$");
    if (!IsSafeWindowsExecutableRelativePath(installed_executable) ||
        !std::regex_match(installed_executable_sha256,
                          kInstalledExecutableSha256)) {
      throw JsonError("Invalid Inno installed executable identity.");
    }
    static const std::set<std::string> kAllowedArguments = {
        "/CLOSEAPPLICATIONS", "/FORCECLOSEAPPLICATIONS", "/NOCANCEL",
        "/NORESTART",         "/SILENT",                "/SP-",
        "/SUPPRESSMSGBOXES",  "/VERYSILENT"};
    const JsonValue::Array& arguments = metadata.at("silentArgs").array();
    std::set<std::string> unique_arguments;
    int silent_mode_count = 0;
    bool has_no_restart = false;
    for (const JsonValue& value : arguments) {
      const std::string argument = value.string();
      if (kAllowedArguments.count(argument) == 0 ||
          !unique_arguments.insert(argument).second) {
        throw JsonError("Invalid Inno fixed argument vector.");
      }
      if (argument == "/VERYSILENT" || argument == "/SILENT") {
        ++silent_mode_count;
      }
      has_no_restart = has_no_restart || argument == "/NORESTART";
    }
    if (silent_mode_count != 1 || !has_no_restart ||
        !metadata.at("inheritInstallDirectory").boolean()) {
      throw JsonError("Invalid Inno silent arguments.");
    }
    const JsonValue* log_value = metadata.find("logFileName");
    const std::string log_file =
        log_value == nullptr ? "desktop_updater_inno_install.log"
                             : log_value->string();
    if (Trim(log_file).empty() || log_file == "." || log_file == ".." ||
        log_file.find_first_of("\\/:*?\"<>|") != std::string::npos ||
        log_file.back() == '.' || log_file.back() == ' ') {
      throw JsonError("Invalid Inno log file name.");
    }
    const JsonValue* elevation_value = metadata.find("requiresElevation");
    const std::string elevation =
        elevation_value == nullptr ? "" : elevation_value->string();
    if (elevation != "always") {
      throw JsonError("Inno descriptor does not require protected elevation.");
    }
    const JsonValue* authenticode = metadata.find("authenticode");
    const JsonValue* required_value =
        authenticode == nullptr ? nullptr : authenticode->find("required");
    const bool required =
        required_value != nullptr && required_value->boolean();
    const JsonValue* thumbprints = authenticode == nullptr
                                       ? nullptr
                                       : authenticode->find("sha256Thumbprints");
    if (!required || thumbprints == nullptr || thumbprints->array().empty()) {
      throw JsonError("Protected Inno requires Authenticode thumbprints.");
    }
    static const std::regex kThumbprint("^[0-9A-Fa-f]{64}$");
    std::set<std::string> unique_thumbprints;
    for (const JsonValue& thumbprint : thumbprints->array()) {
      std::string normalized = thumbprint.string();
      std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                     [](unsigned char value) {
                       return static_cast<char>(std::tolower(value));
                     });
      if (!std::regex_match(thumbprint.string(), kThumbprint) ||
          !unique_thumbprints.insert(normalized).second) {
        throw JsonError("Invalid or duplicate Authenticode thumbprint.");
      }
    }
  }
}

JsonValue NormalizeDelta(const JsonValue& delta) {
  static const std::regex kSha256("^[0-9a-f]{64}$");
  const std::string from_version = RequiredString(delta, "fromVersion");
  const std::string kind = RequiredString(delta, "kind");
  const std::string url = RequiredString(delta, "url");
  const std::string sha256 = RequiredString(delta, "sha256");
  const std::int64_t length = delta.at("length").integer();
  if (Trim(from_version).empty() || kind != "bsdiff") {
    throw JsonError("Invalid delta artifact identity.");
  }
  if (!HasScheme(url)) {
    throw JsonError("Delta artifact URL is not absolute.");
  }
  if (!std::regex_match(sha256, kSha256)) {
    throw JsonError("Invalid delta artifact SHA-256.");
  }
  if (length < 0) {
    throw JsonError("Invalid delta artifact length.");
  }
  JsonValue::Object normalized;
  normalized.emplace("fromVersion", JsonValue(from_version));
  normalized.emplace("kind", JsonValue(kind));
  normalized.emplace("url", JsonValue(url));
  normalized.emplace("sha256", JsonValue(sha256));
  normalized.emplace("length", JsonValue(length));
  return JsonValue(std::move(normalized));
}

ReleaseArtifact ParseArtifact(const JsonValue& json) {
  ReleaseArtifact result;
  result.kind = RequiredString(json, "kind");
  result.url = RequiredString(json, "url");
  result.sha256 = RequiredString(json, "sha256");
  result.length = json.at("length").integer();
  JsonValue::Object normalized;
  normalized.emplace("kind", JsonValue(result.kind));
  normalized.emplace("url", JsonValue(result.url));
  normalized.emplace("sha256", JsonValue(result.sha256));
  normalized.emplace("length", JsonValue(result.length));
  result.raw = JsonValue(std::move(normalized));
  ValidateArtifact(result);
  return result;
}

std::string OptionalString(const JsonValue& value, const std::string& key) {
  const JsonValue* found = value.find(key);
  return found == nullptr ? std::string() : found->string();
}

}  // namespace

DesktopVersion ParseDesktopVersion(const std::string& value,
                                   bool has_build_number,
                                   std::int64_t build_number) {
  const std::string normalized = Trim(value);
  if (normalized.empty()) throw JsonError("Version must not be empty.");
  DesktopVersion result;
  result.raw = normalized;
  const std::vector<std::string> build_split = Split(normalized, '+');
  if (build_split.size() > 2) throw JsonError("Invalid version build metadata.");
  std::vector<std::string> prerelease_split;
  const std::size_t prerelease_separator = build_split[0].find('-');
  prerelease_split.push_back(build_split[0].substr(0, prerelease_separator));
  if (prerelease_separator != std::string::npos) {
    prerelease_split.push_back(build_split[0].substr(prerelease_separator + 1));
  }
  const std::vector<std::string> components = Split(prerelease_split[0], '.');
  if (components.size() != 3) throw JsonError("Version needs three components.");
  result.major = ParseComponent(components[0]);
  result.minor = ParseComponent(components[1]);
  result.patch = ParseComponent(components[2]);
  if (prerelease_split.size() == 2) {
    result.prerelease = Split(prerelease_split[1], '.');
    if (std::any_of(result.prerelease.begin(), result.prerelease.end(),
                    [](const std::string& item) { return item.empty(); })) {
      throw JsonError("Empty prerelease identifier.");
    }
  }
  result.has_build_number = has_build_number;
  result.build_number = build_number;
  if (!has_build_number && build_split.size() == 2) {
    const std::string first_metadata = Split(build_split[1], '.').front();
    if (!first_metadata.empty() &&
        std::all_of(first_metadata.begin(), first_metadata.end(), [](char byte) {
          return std::isdigit(static_cast<unsigned char>(byte));
        })) {
      result.build_number = ParseComponent(first_metadata);
      result.has_build_number = true;
    }
  }
  if (result.has_build_number && result.build_number < 0) {
    throw JsonError("Negative build number.");
  }
  return result;
}

int CompareDesktopVersions(const DesktopVersion& left,
                           const DesktopVersion& right) {
  if (left.has_build_number && right.has_build_number) {
    if (left.build_number == right.build_number) return 0;
    return left.build_number < right.build_number ? -1 : 1;
  }
  if (left.major != right.major) return left.major < right.major ? -1 : 1;
  if (left.minor != right.minor) return left.minor < right.minor ? -1 : 1;
  if (left.patch != right.patch) return left.patch < right.patch ? -1 : 1;
  return ComparePrerelease(left.prerelease, right.prerelease);
}

ReleaseIndexItem ParseReleaseIndexItem(const JsonValue& json) {
  ReleaseIndexItem result;
  result.version = RequiredTrimmedString(json, "version");
  ParseDesktopVersion(result.version);
  const JsonValue* build = json.find("buildNumber");
  if (build == nullptr) build = json.find("shortVersion");
  if (build != nullptr) {
    result.has_build_number = true;
    result.build_number = build->integer();
    if (result.build_number < 0) throw JsonError("Negative index build number.");
  }
  result.platform = RequiredTrimmedString(json, "platform");
  const bool has_channel = json.find("channel") != nullptr;
  result.channel = Trim(OptionalString(json, "channel"));
  if (result.channel.empty()) {
    if (has_channel) throw JsonError("Empty JSON string: channel");
    result.channel = "stable";
  }
  const JsonValue* mandatory = json.find("mandatory");
  result.mandatory = mandatory != nullptr && mandatory->boolean();
  result.release = RequiredString(json, "release");
  if (!HasScheme(result.release)) throw JsonError("Index release URL not absolute.");
  if (const JsonValue* rollout = json.find("rollout")) {
    result.has_rollout = true;
    result.rollout.percentage = rollout->at("percentage").integer();
    result.rollout.salt = RequiredString(*rollout, "salt");
    if (Trim(result.rollout.salt).empty()) {
      throw JsonError("Empty JSON string: salt");
    }
    if (result.rollout.percentage < 0 || result.rollout.percentage > 100) {
      throw JsonError("Invalid rollout percentage.");
    }
  }
  if (const JsonValue* fresh = json.find("freshInstall")) {
    result.has_fresh_install = true;
    result.fresh_install.download_url = RequiredString(*fresh, "downloadUrl");
    if (!HasScheme(result.fresh_install.download_url)) {
      throw JsonError("Fresh install URL not absolute.");
    }
    result.fresh_install.has_message = fresh->find("message") != nullptr;
    result.fresh_install.message = OptionalString(*fresh, "message");
  }
  result.raw = json;
  return result;
}

ReleaseIndex ParseReleaseIndex(const std::string& json) {
  const JsonValue root = ParseJson(json);
  ReleaseIndex result;
  result.schema_version = root.at("schemaVersion").integer();
  if (result.schema_version != 3) throw JsonError("Index schema must be 3.");
  result.app_name = RequiredString(root, "appName");
  for (const JsonValue& item : root.at("items").array()) {
    result.items.push_back(ParseReleaseIndexItem(item));
  }
  if (const JsonValue* policy = root.find("supportPolicy")) {
    result.has_support_policy = true;
    result.support_policy.minimum_supported_version = ParseDesktopVersion(
        RequiredString(*policy, "minimumSupportedVersion"));
    result.support_policy.enforced_after =
        RequiredString(*policy, "enforcedAfter");
    ParseInstant(result.support_policy.enforced_after);
  }
  if (const JsonValue* signature = root.find("signature")) {
    result.has_signature = true;
    result.signature.algorithm = signature->at("algorithm").string();
    result.signature.public_key_id = signature->at("publicKeyId").string();
    result.signature.value = OptionalString(*signature, "value");
  }
  result.raw = root;
  return result;
}

ReleaseDescriptor ParseReleaseDescriptor(const std::string& json) {
  JsonValue root = ParseJson(json);
  ReleaseDescriptor result;
  result.schema_version = root.at("schemaVersion").integer();
  if (result.schema_version != 3) throw JsonError("Descriptor schema must be 3.");
  result.package_id = RequiredTrimmedString(root, "packageId");
  result.app_name = RequiredString(root, "appName");
  if (Trim(result.app_name).empty()) {
    throw JsonError("Empty JSON string: appName");
  }
  result.version = RequiredTrimmedString(root, "version");
  ParseDesktopVersion(result.version);
  if (const JsonValue* build = root.find("buildNumber")) {
    result.has_build_number = true;
    result.build_number = build->integer();
    if (result.build_number < 0) throw JsonError("Negative descriptor build.");
  }
  result.platform = RequiredTrimmedString(root, "platform");
  const bool has_channel = root.find("channel") != nullptr;
  result.channel = Trim(OptionalString(root, "channel"));
  if (result.channel.empty()) {
    if (has_channel) throw JsonError("Empty JSON string: channel");
    result.channel = "stable";
  }
  result.artifact = ParseArtifact(root.at("artifact"));
  result.wire_install = NormalizeInstall(root.at("install"), false);
  result.install = NormalizeInstall(root.at("install"));
  if (const JsonValue* signature = root.find("signature")) {
    result.has_signature = true;
    result.signature.algorithm = RequiredString(*signature, "algorithm");
    result.signature.public_key_id = RequiredString(*signature, "publicKeyId");
    result.signature.value = signature->at("value").string();
  }
  result.minimum_updater_version = RequiredString(root, "minimumUpdaterVersion");
  ParseDesktopVersion(result.minimum_updater_version);
  if (const JsonValue* minimum_os = root.find("minimumOS")) {
    for (const auto& entry : minimum_os->object()) {
      const std::string platform = Trim(entry.first);
      const std::string version = Trim(entry.second.string());
      if (platform.empty() || version.empty()) {
        throw JsonError("Invalid minimum OS entry.");
      }
      result.minimum_os[platform] = version;
    }
  }
  if (const JsonValue* deltas = root.find("deltaArtifacts")) {
    for (const JsonValue& delta : deltas->array()) {
      result.delta_artifacts.push_back(NormalizeDelta(delta));
    }
  }
  result.generated_at =
      FormatInstant(ParseInstant(RequiredString(root, "generatedAt")));
  ValidateInstall(result);
  JsonValue::Object normalized;
  normalized.emplace("schemaVersion", JsonValue(result.schema_version));
  normalized.emplace("packageId", JsonValue(result.package_id));
  normalized.emplace("appName", JsonValue(result.app_name));
  normalized.emplace("version", JsonValue(result.version));
  if (result.has_build_number) {
    normalized.emplace("buildNumber", JsonValue(result.build_number));
  }
  normalized.emplace("platform", JsonValue(result.platform));
  normalized.emplace("channel", JsonValue(result.channel));
  normalized.emplace("artifact", result.artifact.raw);
  normalized.emplace("install", result.wire_install);
  if (result.has_signature) {
    JsonValue::Object signature;
    signature.emplace("algorithm", JsonValue(result.signature.algorithm));
    signature.emplace("publicKeyId",
                      JsonValue(result.signature.public_key_id));
    signature.emplace("value", JsonValue(result.signature.value));
    normalized.emplace("signature", JsonValue(std::move(signature)));
  }
  normalized.emplace("minimumUpdaterVersion",
                     JsonValue(result.minimum_updater_version));
  if (!result.minimum_os.empty()) {
    JsonValue::Object minimum_os;
    for (const auto& entry : result.minimum_os) {
      minimum_os.emplace(entry.first, JsonValue(entry.second));
    }
    normalized.emplace("minimumOS", JsonValue(std::move(minimum_os)));
  }
  if (!result.delta_artifacts.empty()) {
    JsonValue::Array deltas;
    for (const JsonValue& delta : result.delta_artifacts) {
      deltas.push_back(delta);
    }
    normalized.emplace("deltaArtifacts", JsonValue(std::move(deltas)));
  }
  normalized.emplace("generatedAt", JsonValue(result.generated_at));
  result.raw = JsonValue(std::move(normalized));
  return result;
}

const ReleaseIndexItem* SelectReleaseIndexItem(
    const ReleaseIndex& index,
    const std::string& platform,
    const std::string& channel,
    const DesktopVersion& current_version,
    const std::string& installation_identity,
    const Sha256Function& sha256) {
  const ReleaseIndexItem* selected = nullptr;
  for (const ReleaseIndexItem& item : index.items) {
    if (item.platform != platform || item.channel != channel ||
        !RolloutIncludes(item, installation_identity, sha256)) {
      continue;
    }
    const DesktopVersion candidate = ParseDesktopVersion(
        item.version, item.has_build_number && item.build_number > 0,
        item.build_number);
    if (CompareDesktopVersions(candidate, current_version) <= 0) continue;
    if (selected == nullptr ||
        CompareDesktopVersions(
            candidate,
            ParseDesktopVersion(selected->version,
                                selected->has_build_number &&
                                    selected->build_number > 0,
                                selected->build_number)) > 0) {
      selected = &item;
    }
  }
  return selected;
}

std::string CanonicalSignatureBytes(const ReleaseDescriptor& descriptor) {
  JsonValue::Object artifact;
  artifact.emplace("kind", JsonValue(descriptor.artifact.kind));
  artifact.emplace("url", JsonValue(descriptor.artifact.url));
  artifact.emplace("sha256", JsonValue(descriptor.artifact.sha256));
  artifact.emplace("length", JsonValue(descriptor.artifact.length));

  JsonValue::Object canonical;
  canonical.emplace("schemaVersion", JsonValue(descriptor.schema_version));
  canonical.emplace("packageId", JsonValue(descriptor.package_id));
  canonical.emplace("appName", JsonValue(descriptor.app_name));
  canonical.emplace("version", JsonValue(descriptor.version));
  if (descriptor.has_build_number) {
    canonical.emplace("buildNumber", JsonValue(descriptor.build_number));
  }
  canonical.emplace("platform", JsonValue(descriptor.platform));
  canonical.emplace("channel", JsonValue(descriptor.channel));
  canonical.emplace("artifact", JsonValue(std::move(artifact)));
  canonical.emplace("install", descriptor.wire_install);
  if (descriptor.has_signature) {
    JsonValue::Object signature;
    signature.emplace("algorithm", JsonValue(descriptor.signature.algorithm));
    signature.emplace("publicKeyId",
                      JsonValue(descriptor.signature.public_key_id));
    signature.emplace("value", JsonValue(std::string()));
    canonical.emplace("signature", JsonValue(std::move(signature)));
  }
  canonical.emplace("minimumUpdaterVersion",
                    JsonValue(descriptor.minimum_updater_version));
  if (!descriptor.minimum_os.empty()) {
    JsonValue::Object minimum_os;
    for (const auto& entry : descriptor.minimum_os) {
      minimum_os.emplace(entry.first, JsonValue(entry.second));
    }
    canonical.emplace("minimumOS", JsonValue(std::move(minimum_os)));
  }
  if (!descriptor.delta_artifacts.empty()) {
    JsonValue::Array deltas;
    for (const JsonValue& delta : descriptor.delta_artifacts) {
      deltas.push_back(delta);
    }
    canonical.emplace("deltaArtifacts", JsonValue(std::move(deltas)));
  }
  canonical.emplace("generatedAt", JsonValue(descriptor.generated_at));
  return EncodeCanonicalJson(JsonValue(std::move(canonical)));
}

std::string CanonicalIndexSignatureBytes(const ReleaseIndex& index) {
  JsonValue::Object canonical;
  canonical.emplace("schemaVersion", JsonValue(index.schema_version));
  canonical.emplace("appName", JsonValue(index.app_name));
  if (index.has_support_policy) {
    JsonValue::Object support;
    support.emplace(
        "minimumSupportedVersion",
        JsonValue(index.support_policy.minimum_supported_version.raw));
    support.emplace(
        "enforcedAfter",
        JsonValue(FormatInstant(ParseInstant(
            index.support_policy.enforced_after))));
    canonical.emplace("supportPolicy", JsonValue(std::move(support)));
  }
  JsonValue::Array items;
  for (const ReleaseIndexItem& item : index.items) {
    JsonValue::Object normalized;
    normalized.emplace("version", JsonValue(item.version));
    if (item.has_build_number) {
      normalized.emplace("buildNumber", JsonValue(item.build_number));
    }
    normalized.emplace("platform", JsonValue(item.platform));
    normalized.emplace("channel", JsonValue(item.channel));
    normalized.emplace("mandatory", JsonValue(item.mandatory));
    if (item.has_fresh_install) {
      JsonValue::Object fresh;
      fresh.emplace("downloadUrl",
                    JsonValue(item.fresh_install.download_url));
      if (item.fresh_install.has_message) {
        fresh.emplace("message", JsonValue(item.fresh_install.message));
      }
      normalized.emplace("freshInstall", JsonValue(std::move(fresh)));
    }
    normalized.emplace("release", JsonValue(item.release));
    if (item.has_rollout) {
      JsonValue::Object rollout;
      rollout.emplace("percentage", JsonValue(item.rollout.percentage));
      rollout.emplace("salt", JsonValue(item.rollout.salt));
      normalized.emplace("rollout", JsonValue(std::move(rollout)));
    }
    items.emplace_back(JsonValue(std::move(normalized)));
  }
  canonical.emplace("items", JsonValue(std::move(items)));
  if (index.has_signature) {
    JsonValue::Object signature;
    signature.emplace("algorithm", JsonValue(index.signature.algorithm));
    signature.emplace("publicKeyId",
                      JsonValue(index.signature.public_key_id));
    signature.emplace("value", JsonValue(std::string()));
    canonical.emplace("signature", JsonValue(std::move(signature)));
  }
  return EncodeCanonicalJson(JsonValue(std::move(canonical)));
}

bool VerifyIndexSignature(
    const ReleaseIndex& index,
    const std::map<std::string, std::vector<std::uint8_t>>& pinned_keys) {
  if (!index.has_signature || index.signature.algorithm != "ed25519" ||
      Trim(index.signature.public_key_id).empty()) {
    return false;
  }
  const auto key = pinned_keys.find(index.signature.public_key_id);
  if (key == pinned_keys.end() || key->second.size() != 32) return false;
  std::vector<std::uint8_t> signature;
  try {
    signature = DecodeBase64(index.signature.value);
  } catch (const JsonError&) {
    return false;
  }
  if (signature.size() != 64) return false;
  const std::string message = CanonicalIndexSignatureBytes(index);
  return crypto_ed25519_check(
             signature.data(), key->second.data(),
             reinterpret_cast<const std::uint8_t*>(message.data()),
             message.size()) == 0;
}

bool VerifyDescriptorSignature(
    const ReleaseDescriptor& descriptor,
    const std::map<std::string, std::vector<std::uint8_t>>& pinned_keys) {
  if (!descriptor.has_signature || descriptor.signature.algorithm != "ed25519") {
    return false;
  }
  const auto key = pinned_keys.find(descriptor.signature.public_key_id);
  if (key == pinned_keys.end() || key->second.size() != 32) return false;
  std::vector<std::uint8_t> signature;
  try {
    signature = DecodeBase64(descriptor.signature.value);
  } catch (const JsonError&) {
    return false;
  }
  if (signature.size() != 64) return false;
  const std::string message = CanonicalSignatureBytes(descriptor);
  return crypto_ed25519_check(signature.data(), key->second.data(),
                              reinterpret_cast<const std::uint8_t*>(
                                  message.data()),
                              message.size()) == 0;
}

std::string DescriptorBindingOutcome(const ReleaseDescriptor& descriptor,
                                     const ReleaseIndexItem& item,
                                     const std::string& expected_package_id) {
  if (descriptor.package_id != expected_package_id) {
    return "packageIdentityMismatch";
  }
  if (descriptor.version != item.version ||
      descriptor.has_build_number != item.has_build_number ||
      (descriptor.has_build_number &&
       descriptor.build_number != item.build_number) ||
      descriptor.platform != item.platform || descriptor.channel != item.channel) {
    return "invalidDescriptor";
  }
  return "match";
}

std::string DescriptorPolicyOutcome(
    const ReleaseDescriptor& descriptor,
    const DesktopVersion& current_updater_version,
    const std::string& platform,
    const std::function<bool(const std::string&, const std::string&)>&
        minimum_os_resolver) {
  if (CompareDesktopVersions(
          current_updater_version,
          ParseDesktopVersion(descriptor.minimum_updater_version)) < 0) {
    return "unsupportedMinimumUpdater";
  }
  const auto minimum_os = descriptor.minimum_os.find(platform);
  if (minimum_os != descriptor.minimum_os.end() &&
      !minimum_os_resolver(platform, minimum_os->second)) {
    return "unsupportedMinimumOS";
  }
  return "updateAvailable";
}

std::string SupportPolicyOutcome(const ReleaseSupportPolicy& policy,
                                 const DesktopVersion& current_version,
                                 const std::string& now) {
  if (CompareDesktopVersions(current_version,
                             policy.minimum_supported_version) >= 0) {
    return "updateAvailable";
  }
  const ParsedInstant current = ParseInstant(now);
  const ParsedInstant deadline = ParseInstant(policy.enforced_after);
  const bool enforced = current.seconds > deadline.seconds ||
                        (current.seconds == deadline.seconds &&
                         current.microseconds >= deadline.microseconds);
  return enforced ? "supportPolicyBlocked" : "supportPolicyWarning";
}

std::vector<std::uint8_t> DecodeBase64(const std::string& value) {
  static const std::string alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if (value.empty() || value.size() % 4 != 0) {
    throw JsonError("Invalid base64 length.");
  }
  std::vector<std::uint8_t> output;
  for (std::size_t offset = 0; offset < value.size(); offset += 4) {
    const bool final_group = offset + 4 == value.size();
    const bool pad_two = value[offset + 2] == '=';
    const bool pad_three = value[offset + 3] == '=';
    if ((pad_two && !pad_three) || (!final_group && (pad_two || pad_three)) ||
        value[offset] == '=' || value[offset + 1] == '=') {
      throw JsonError("Invalid base64 padding.");
    }
    const std::size_t first = alphabet.find(value[offset]);
    const std::size_t second = alphabet.find(value[offset + 1]);
    const std::size_t third = pad_two ? 0 : alphabet.find(value[offset + 2]);
    const std::size_t fourth = pad_three ? 0 : alphabet.find(value[offset + 3]);
    if (first == std::string::npos || second == std::string::npos ||
        third == std::string::npos || fourth == std::string::npos) {
      throw JsonError("Invalid base64 byte.");
    }
    if ((pad_two && (second & 0x0F) != 0) ||
        (pad_three && !pad_two && (third & 0x03) != 0)) {
      throw JsonError("Non-canonical base64 padding bits.");
    }
    const std::uint32_t combined =
        (static_cast<std::uint32_t>(first) << 18) |
        (static_cast<std::uint32_t>(second) << 12) |
        (static_cast<std::uint32_t>(third) << 6) |
        static_cast<std::uint32_t>(fourth);
    output.push_back(static_cast<std::uint8_t>((combined >> 16) & 0xFF));
    if (!pad_two) {
      output.push_back(static_cast<std::uint8_t>((combined >> 8) & 0xFF));
    }
    if (!pad_three) {
      output.push_back(static_cast<std::uint8_t>(combined & 0xFF));
    }
  }
  return output;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
