#include "stage_provenance.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

#if defined(_WIN32)
std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    throw std::runtime_error("Invalid UTF-16 staged path.");
  }
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), length,
                          nullptr, nullptr) != length) {
    throw std::runtime_error("Unable to encode staged path.");
  }
  return result;
}

std::wstring Win32Path(const std::filesystem::path& path) {
  const std::wstring value = path.wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) return value;
  if (value.rfind(L"\\\\", 0) == 0) {
    return std::wstring(L"\\\\?\\UNC\\") + value.substr(2);
  }
  if (value.size() >= 2 && value[1] == L':') {
    return std::wstring(L"\\\\?\\") + value;
  }
  return value;
}
#endif

bool ValidSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return std::isdigit(byte) || (byte >= 'a' && byte <= 'f');
         });
}

bool ValidNonce(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const char byte = value[index];
    if (!std::isdigit(static_cast<unsigned char>(byte)) &&
        (byte < 'a' || byte > 'f')) {
      return false;
    }
  }
  return true;
}

void ValidateRelative(const std::string& value, const char* field) {
  if (value.empty() || value.front() == '/' || value.back() == '/' ||
      value.find('\\') != std::string::npos ||
      (value.size() >= 2 &&
       std::isalpha(static_cast<unsigned char>(value[0])) &&
       value[1] == ':')) {
    throw std::runtime_error(std::string("Invalid ") + field + ".");
  }
  std::size_t start = 0;
  while (start <= value.size()) {
    const std::size_t slash = value.find('/', start);
    const std::string segment = value.substr(start, slash - start);
    if (segment.empty() || segment == "." || segment == "..") {
      throw std::runtime_error(std::string("Invalid ") + field + ".");
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
}

std::string PathToUTF8(const std::filesystem::path& path) {
  return path.generic_u8string();
}

std::filesystem::path CanonicalDirectoryImpl(
    const std::filesystem::path& path,
    const char* field) {
#if defined(_WIN32)
  const std::wstring native_path = Win32Path(path);
  const DWORD attributes = GetFileAttributesW(native_path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw std::runtime_error(std::string(field) +
                             " must be a real non-reparse directory.");
  }
  std::error_code error;
  std::filesystem::path absolute =
      std::filesystem::absolute(path, error).lexically_normal();
  if (error || absolute.empty()) {
    throw std::runtime_error(std::string("Unable to canonicalize ") + field + ".");
  }
  while (absolute != absolute.root_path() && absolute.filename().empty()) {
    const std::filesystem::path parent = absolute.parent_path();
    if (parent == absolute) break;
    absolute = parent;
  }
  return absolute;
#else
  const std::string native = path.string();
  struct stat status {};
  if (lstat(native.c_str(), &status) != 0 || !S_ISDIR(status.st_mode) ||
      S_ISLNK(status.st_mode)) {
    throw std::runtime_error(std::string(field) +
                             " must be a real directory.");
  }
  char buffer[PATH_MAX];
  if (realpath(native.c_str(), buffer) == nullptr) {
    throw std::runtime_error(std::string("Unable to canonicalize ") + field + ".");
  }
  return std::filesystem::path(buffer);
#endif
}

std::string RandomNonce() {
  unsigned char bytes[16]{};
#if defined(_WIN32)
  if (BCryptGenRandom(nullptr, bytes, sizeof(bytes),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    throw std::runtime_error("Unable to generate stage nonce.");
  }
#else
  const int random = open("/dev/urandom", O_RDONLY
#if defined(O_CLOEXEC)
                          | O_CLOEXEC
#endif
  );
  if (random < 0) throw std::runtime_error("Unable to generate stage nonce.");
  std::size_t offset = 0;
  while (offset < sizeof(bytes)) {
    const ssize_t count = read(random, bytes + offset, sizeof(bytes) - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      close(random);
      throw std::runtime_error("Unable to generate stage nonce.");
    }
    offset += static_cast<std::size_t>(count);
  }
  close(random);
#endif
  bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0f) | 0x40);
  bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3f) | 0x80);
  std::ostringstream output;
  output << std::hex;
  for (std::size_t index = 0; index < sizeof(bytes); ++index) {
    if (index == 4 || index == 6 || index == 8 || index == 10) output << '-';
    output.width(2);
    output.fill('0');
    output << static_cast<unsigned int>(bytes[index]);
  }
  return output.str();
}

bool Utf8Less(const std::string& left, const std::string& right) {
  return std::lexicographical_compare(
      left.begin(), left.end(), right.begin(), right.end(),
      [](char first, char second) {
        return static_cast<unsigned char>(first) <
               static_cast<unsigned char>(second);
      });
}

std::string ReadFile(const std::filesystem::path& path) {
#if defined(_WIN32)
  const std::wstring native_path = Win32Path(path);
  HANDLE raw_file = CreateFileW(
      native_path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (raw_file == INVALID_HANDLE_VALUE) {
    throw std::runtime_error("Unable to read staged file.");
  }
  struct FileCloser {
    void operator()(void* handle) const {
      if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
        CloseHandle(static_cast<HANDLE>(handle));
      }
    }
  };
  std::unique_ptr<void, FileCloser> file(raw_file);
  BY_HANDLE_FILE_INFORMATION information{};
  LARGE_INTEGER size{};
  if (!GetFileInformationByHandle(raw_file, &information) ||
      (information.dwFileAttributes &
      (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
      !GetFileSizeEx(raw_file, &size) || size.QuadPart < 0 ||
      static_cast<unsigned long long>(size.QuadPart) >
          static_cast<unsigned long long>(
              (std::numeric_limits<std::size_t>::max)())) {
    throw std::runtime_error("Unable to read staged file.");
  }
  std::string bytes(static_cast<std::size_t>(size.QuadPart), '\0');
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    DWORD bytes_read = 0;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        bytes.size() - offset, 64 * 1024));
    if (::ReadFile(raw_file, bytes.data() + offset, requested, &bytes_read,
                   nullptr) == FALSE ||
        bytes_read == 0 || bytes_read > requested) {
      throw std::runtime_error("Unable to read staged file.");
    }
    offset += bytes_read;
  }
  return bytes;
#else
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Unable to read staged file.");
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
#endif
}

#if defined(_WIN32)
void RemoveTree(const std::filesystem::path& path) {
  const std::wstring native_path = Win32Path(path);
  const DWORD attributes = GetFileAttributesW(native_path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) return;
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    const bool removed = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
                             ? RemoveDirectoryW(native_path.c_str()) != 0
                             : DeleteFileW(native_path.c_str()) != 0;
    if (!removed) throw std::runtime_error("Cleanup failed.");
    return;
  }
  WIN32_FIND_DATAW entry{};
  const std::wstring pattern = Win32Path(path / L"*");
  HANDLE search = FindFirstFileW(pattern.c_str(), &entry);
  if (search != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = entry.cFileName;
      if (name != L"." && name != L"..") RemoveTree(path / name);
    } while (FindNextFileW(search, &entry));
    FindClose(search);
  }
  if (!RemoveDirectoryW(native_path.c_str())) {
    throw std::runtime_error("Cleanup failed.");
  }
}

#else
void RemoveTree(const std::filesystem::path& path) {
  const std::string native = path.string();
  struct stat status {};
  if (lstat(native.c_str(), &status) != 0) return;
  if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
    if (unlink(native.c_str()) != 0) throw std::runtime_error("Cleanup failed.");
    return;
  }
  DIR* directory = opendir(native.c_str());
  if (directory == nullptr) throw std::runtime_error("Cleanup failed.");
  while (dirent* entry = readdir(directory)) {
    const std::string name = entry->d_name;
    if (name != "." && name != "..") RemoveTree(path / name);
  }
  closedir(directory);
  if (rmdir(native.c_str()) != 0) throw std::runtime_error("Cleanup failed.");
}
#endif

void AddInventory(const std::filesystem::path& root,
                  const std::filesystem::path& native_relative,
                  const std::string& json_relative,
                  const StageSha256Function& sha256,
                  std::vector<StageProvenanceEntry>* entries) {
  const std::filesystem::path absolute =
      native_relative.empty() ? root : root / native_relative;
#if defined(_WIN32)
  WIN32_FIND_DATAW found{};
  const std::wstring pattern = Win32Path(absolute / L"*");
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND) return;
    throw std::runtime_error("Unable to enumerate staged directory.");
  }
  do {
    const std::string name = WideToUtf8(found.cFileName);
    if (name == "." || name == "..") continue;
    const std::string json_child = json_relative.empty()
                                       ? name
                                       : json_relative + "/" + name;
    if (json_child == kStageProvenanceFileName) continue;
    const std::filesystem::path native_child =
        native_relative / found.cFileName;
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      FindClose(search);
      throw std::runtime_error("Staged reparse points are unsafe.");
    }
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      entries->push_back({json_child, "directory", 0, "", ""});
      AddInventory(root, native_child, json_child, sha256, entries);
    } else {
      const std::string bytes = ReadFile(root / native_child);
      entries->push_back(
          {json_child, "file", static_cast<std::int64_t>(bytes.size()),
           StageBytesToHex(sha256(bytes)), ""});
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
#else
  const std::string native_absolute = absolute.string();
  DIR* directory = opendir(native_absolute.c_str());
  if (directory == nullptr) throw std::runtime_error("Unable to enumerate staged directory.");
  while (dirent* found = readdir(directory)) {
    const std::string name = found->d_name;
    if (name == "." || name == "..") continue;
    const std::string json_child = json_relative.empty()
                                       ? name
                                       : json_relative + "/" + name;
    if (json_child == kStageProvenanceFileName) continue;
    const std::filesystem::path native_child = native_relative / name;
    const std::filesystem::path child_path = root / native_child;
    const std::string native_child_string = child_path.string();
    struct stat status {};
    if (lstat(native_child_string.c_str(), &status) != 0) {
      closedir(directory);
      throw std::runtime_error("Unable to inspect staged entry.");
    }
    if (S_ISDIR(status.st_mode)) {
      entries->push_back({json_child, "directory", 0, "", ""});
      AddInventory(root, native_child, json_child, sha256, entries);
    } else if (S_ISREG(status.st_mode)) {
      const std::string bytes = ReadFile(child_path);
      entries->push_back(
          {json_child, "file", static_cast<std::int64_t>(bytes.size()),
           StageBytesToHex(sha256(bytes)), ""});
    } else if (S_ISLNK(status.st_mode)) {
      std::vector<char> target(static_cast<std::size_t>(status.st_size) + 2);
      const ssize_t length = readlink(native_child_string.c_str(), target.data(),
                                      target.size() - 1);
      if (length < 0) {
        closedir(directory);
        throw std::runtime_error("Unable to read staged symlink.");
      }
      const std::string value(target.data(), static_cast<std::size_t>(length));
      ValidateRelative(value, "symlink target");
      entries->push_back({json_child, "symlink", 0, "", value});
    } else {
      closedir(directory);
      throw std::runtime_error("Unsupported staged filesystem entry.");
    }
  }
  closedir(directory);
#endif
}

std::vector<StageProvenanceEntry> Inventory(
    const std::filesystem::path& stage_root,
    const StageSha256Function& sha256) {
  if (!sha256) throw std::invalid_argument("Stage SHA-256 is required.");
  std::vector<StageProvenanceEntry> entries;
  AddInventory(stage_root, std::filesystem::path(), "", sha256, &entries);
  std::sort(entries.begin(), entries.end(),
            [](const StageProvenanceEntry& first,
               const StageProvenanceEntry& second) {
              return Utf8Less(first.path, second.path);
            });
  return entries;
}

JsonValue EncodeMarker(const StageProvenanceMarker& marker) {
  JsonValue::Array entries;
  for (const StageProvenanceEntry& entry : marker.entries) {
    JsonValue::Object value;
    value.emplace("path", JsonValue(entry.path));
    value.emplace("kind", JsonValue(entry.kind));
    value.emplace("length", JsonValue(entry.length));
    if (entry.kind == "file") value.emplace("sha256", JsonValue(entry.sha256));
    if (entry.kind == "symlink") value.emplace("target", JsonValue(entry.target));
    entries.emplace_back(JsonValue(std::move(value)));
  }
  JsonValue::Object root;
  root.emplace("schemaVersion", JsonValue(static_cast<std::int64_t>(1)));
  root.emplace("nonce", JsonValue(marker.nonce));
  root.emplace("packageId", JsonValue(marker.package_id));
  root.emplace("descriptorSha256", JsonValue(marker.descriptor_sha256));
  root.emplace("artifactSha256", JsonValue(marker.artifact_sha256));
  root.emplace("entries", JsonValue(std::move(entries)));
  return JsonValue(std::move(root));
}

StageProvenanceMarker DecodeMarker(const JsonValue& root) {
  if (root.at("schemaVersion").integer() != 1) {
    throw std::runtime_error("Unsupported stage provenance schema.");
  }
  StageProvenanceMarker marker;
  marker.nonce = root.at("nonce").string();
  marker.package_id = root.at("packageId").string();
  marker.descriptor_sha256 = root.at("descriptorSha256").string();
  marker.artifact_sha256 = root.at("artifactSha256").string();
  if (!ValidNonce(marker.nonce) || marker.package_id.empty() ||
      !ValidSha256(marker.descriptor_sha256) ||
      !ValidSha256(marker.artifact_sha256)) {
    throw std::runtime_error("Stage provenance identity is invalid.");
  }
  std::set<std::string> paths;
  std::string previous;
  for (const JsonValue& value : root.at("entries").array()) {
    StageProvenanceEntry entry;
    entry.path = value.at("path").string();
    entry.kind = value.at("kind").string();
    entry.length = value.at("length").integer();
    ValidateRelative(entry.path, "provenance path");
    if (!paths.insert(entry.path).second ||
        (!previous.empty() && !Utf8Less(previous, entry.path))) {
      throw std::runtime_error("Stage provenance entries are not unique and sorted.");
    }
    previous = entry.path;
    if (entry.kind == "file") {
      entry.sha256 = value.at("sha256").string();
      if (entry.length < 0 || !ValidSha256(entry.sha256) ||
          value.find("target") != nullptr) {
        throw std::runtime_error("Stage provenance file entry is invalid.");
      }
    } else if (entry.kind == "directory") {
      if (entry.length != 0 || value.find("sha256") != nullptr ||
          value.find("target") != nullptr) {
        throw std::runtime_error("Stage provenance directory entry is invalid.");
      }
    } else if (entry.kind == "symlink") {
      entry.target = value.at("target").string();
      ValidateRelative(entry.target, "symlink target");
      if (entry.length != 0 || value.find("sha256") != nullptr) {
        throw std::runtime_error("Stage provenance symlink entry is invalid.");
      }
    } else {
      throw std::runtime_error("Unsupported stage provenance entry.");
    }
    marker.entries.push_back(std::move(entry));
  }
  return marker;
}

bool EqualEntries(const std::vector<StageProvenanceEntry>& first,
                  const std::vector<StageProvenanceEntry>& second) {
  if (first.size() != second.size()) return false;
  for (std::size_t index = 0; index < first.size(); ++index) {
    const auto& left = first[index];
    const auto& right = second[index];
    if (left.path != right.path || left.kind != right.kind ||
        left.length != right.length || left.sha256 != right.sha256 ||
        left.target != right.target) {
      return false;
    }
  }
  return true;
}

void WriteExclusive(const std::filesystem::path& path,
                    const std::string& bytes) {
#if defined(_WIN32)
  const std::wstring native_path = Win32Path(path);
  HANDLE file = CreateFileW(native_path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    throw std::runtime_error("Stage provenance marker already exists.");
  }
  DWORD written = 0;
  const bool ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                            &written, nullptr) != 0 &&
                  written == bytes.size();
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(native_path.c_str());
    throw std::runtime_error("Unable to write stage provenance marker.");
  }
#else
  const std::string native = path.string();
  const int file = open(native.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (file < 0) throw std::runtime_error("Stage provenance marker already exists.");
  std::size_t offset = 0;
  bool ok = true;
  while (offset < bytes.size()) {
    const ssize_t count = write(file, bytes.data() + offset, bytes.size() - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { ok = false; break; }
    offset += static_cast<std::size_t>(count);
  }
  if (close(file) != 0) ok = false;
  if (!ok) {
    unlink(native.c_str());
    throw std::runtime_error("Unable to write stage provenance marker.");
  }
#endif
}

struct CanonicalMarker {
  StageProvenanceMarker marker;
  std::string bytes;
};

CanonicalMarker ReadCanonicalMarker(const std::filesystem::path& stage_root,
                                    bool require_owned_stage_name = true) {
  const std::filesystem::path root =
      CanonicalStageDirectory(stage_root, "Stage root");
  const std::string bytes = ReadFile(root / kStageProvenanceFileName);
  const JsonValue parsed = ParseJson(bytes);
  StageProvenanceMarker marker = DecodeMarker(parsed);
  if (EncodeCanonicalJson(EncodeMarker(marker)) != bytes ||
      (require_owned_stage_name &&
       PathToUTF8(root.filename()) !=
           std::string(kOwnedStagePrefix) + marker.nonce)) {
    throw std::runtime_error(
        "Stage provenance marker is not canonical or nonce-bound.");
  }
  return {std::move(marker), bytes};
}

}  // namespace

std::filesystem::path CanonicalStageDirectory(
    const std::filesystem::path& path,
    const char* field) {
  return CanonicalDirectoryImpl(path, field);
}

std::string StageBytesToHex(const std::vector<std::uint8_t>& bytes) {
  static const char* digits = "0123456789abcdef";
  std::string output;
  output.reserve(bytes.size() * 2);
  for (std::uint8_t byte : bytes) {
    output.push_back(digits[byte >> 4]);
    output.push_back(digits[byte & 0x0f]);
  }
  return output;
}

FilesystemOwnedStage CreateOwnedStage(
    const std::filesystem::path& parent_path,
    const std::string& requested_nonce) {
  const std::filesystem::path parent =
      CanonicalStageDirectory(parent_path, "Staging parent");
  if (parent == parent.root_path()) {
    throw std::runtime_error("Filesystem roots cannot be staging parents.");
  }
  const std::string nonce = requested_nonce.empty() ? RandomNonce()
                                                     : requested_nonce;
  if (!ValidNonce(nonce)) throw std::runtime_error("Stage nonce is invalid.");
  const std::filesystem::path child =
      parent / std::filesystem::u8path(std::string(kOwnedStagePrefix) + nonce);
  if (child.parent_path() != parent) {
    throw std::runtime_error("Owned staging child escapes canonical parent.");
  }
#if defined(_WIN32)
  const std::wstring native_child = Win32Path(child);
  if (!CreateDirectoryW(native_child.c_str(), nullptr)) {
#else
  if (mkdir(child.string().c_str(), 0700) != 0) {
#endif
    throw std::runtime_error("Unable to exclusively create owned stage.");
  }
  try {
    if (CanonicalStageDirectory(child, "Owned stage") != child) {
      throw std::runtime_error("Owned stage escapes canonical parent.");
    }
  } catch (...) {
    try { RemoveTree(child); } catch (...) {}
    throw;
  }
  return {child, parent, nonce};
}

StageProvenanceState WriteStageProvenance(
    const FilesystemOwnedStage& stage,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    const StageSha256Function& sha256) {
  if (!ValidNonce(stage.nonce) ||
      PathToUTF8(stage.path.filename()) !=
          std::string(kOwnedStagePrefix) + stage.nonce ||
      package_id.empty() ||
      !ValidSha256(descriptor_sha256) || !ValidSha256(artifact_sha256)) {
    throw std::runtime_error("Stage provenance metadata is invalid.");
  }
  StageProvenanceState state;
  state.marker = {stage.nonce, package_id, descriptor_sha256, artifact_sha256,
                  Inventory(stage.path, sha256)};
  const std::string bytes = EncodeCanonicalJson(EncodeMarker(state.marker));
  WriteExclusive(stage.path / kStageProvenanceFileName, bytes);
  state.marker_sha256 = StageBytesToHex(sha256(bytes));
  return state;
}

StageProvenanceState ReadStageProvenance(
    const std::filesystem::path& stage_root,
    const StageSha256Function& sha256) {
  const CanonicalMarker canonical = ReadCanonicalMarker(stage_root);
  StageProvenanceState state;
  state.marker = canonical.marker;
  state.marker_sha256 = StageBytesToHex(sha256(canonical.bytes));
  return state;
}

StageProvenanceBinding ReadStageProvenanceBinding(
    const std::filesystem::path& stage_root) {
  const CanonicalMarker canonical = ReadCanonicalMarker(stage_root);
  return {canonical.marker, canonical.bytes};
}

StageProvenanceMarker VerifyStageProvenance(
    const std::filesystem::path& stage_root,
    const std::string& expected_marker_sha256,
    const StageSha256Function& sha256) {
  if (!ValidSha256(expected_marker_sha256)) {
    throw std::runtime_error("Expected stage provenance SHA-256 is invalid.");
  }
  const StageProvenanceState state = ReadStageProvenance(stage_root, sha256);
  if (state.marker_sha256 != expected_marker_sha256) {
    throw std::runtime_error("Stage provenance marker digest changed.");
  }
  if (!EqualEntries(state.marker.entries, Inventory(stage_root, sha256))) {
    throw std::runtime_error("Staged update inventory changed.");
  }
  return state.marker;
}

StageProvenanceMarker VerifyRelocatedStageProvenance(
    const std::filesystem::path& stage_root,
    const std::string& expected_marker_sha256,
    const StageSha256Function& sha256) {
  if (!ValidSha256(expected_marker_sha256)) {
    throw std::runtime_error("Expected stage provenance SHA-256 is invalid.");
  }
  const CanonicalMarker canonical =
      ReadCanonicalMarker(stage_root, false);
  const std::string marker_sha256 =
      StageBytesToHex(sha256(canonical.bytes));
  if (marker_sha256 != expected_marker_sha256 ||
      !EqualEntries(canonical.marker.entries, Inventory(stage_root, sha256))) {
    throw std::runtime_error("Relocated stage provenance changed.");
  }
  return canonical.marker;
}

void RemoveOwnedStage(const std::filesystem::path& parent_path,
                      const std::filesystem::path& stage_root,
                      const std::string& nonce,
                      const StageSha256Function& sha256) {
  const std::filesystem::path parent =
      CanonicalStageDirectory(parent_path, "Staging parent");
  const std::filesystem::path root =
      CanonicalStageDirectory(stage_root, "Stage root");
  if (root.parent_path() != parent || !ValidNonce(nonce) ||
      PathToUTF8(root.filename()) !=
          std::string(kOwnedStagePrefix) + nonce) {
    throw std::runtime_error("Owned stage cleanup path is invalid.");
  }
  const StageProvenanceMarker marker = VerifyStageProvenance(
      root, ReadStageProvenance(root, sha256).marker_sha256, sha256);
  if (marker.nonce != nonce) {
    throw std::runtime_error("Owned stage cleanup nonce changed.");
  }
  RemoveTree(root);
}

OwnedStage CreateOwnedStage(const std::string& parent_path,
                            const std::string& requested_nonce) {
  const FilesystemOwnedStage stage = CreateOwnedStage(
      std::filesystem::u8path(parent_path), requested_nonce);
  return {PathToUTF8(stage.path), PathToUTF8(stage.parent_path), stage.nonce};
}

StageProvenanceState WriteStageProvenance(
    const OwnedStage& stage,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    const StageSha256Function& sha256) {
  return WriteStageProvenance(
      FilesystemOwnedStage{std::filesystem::u8path(stage.path),
                           std::filesystem::u8path(stage.parent_path),
                           stage.nonce},
      package_id, descriptor_sha256, artifact_sha256, sha256);
}

StageProvenanceState ReadStageProvenance(
    const std::string& stage_root,
    const StageSha256Function& sha256) {
  return ReadStageProvenance(std::filesystem::u8path(stage_root), sha256);
}

StageProvenanceBinding ReadStageProvenanceBinding(
    const std::string& stage_root) {
  return ReadStageProvenanceBinding(std::filesystem::u8path(stage_root));
}

StageProvenanceMarker VerifyStageProvenance(
    const std::string& stage_root,
    const std::string& expected_marker_sha256,
    const StageSha256Function& sha256) {
  return VerifyStageProvenance(std::filesystem::u8path(stage_root),
                               expected_marker_sha256, sha256);
}

void RemoveOwnedStage(const std::string& parent_path,
                      const std::string& stage_root,
                      const std::string& nonce,
                      const StageSha256Function& sha256) {
  RemoveOwnedStage(std::filesystem::u8path(parent_path),
                   std::filesystem::u8path(stage_root), nonce, sha256);
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
