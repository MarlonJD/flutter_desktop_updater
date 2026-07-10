#include "artifact_stager.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <direct.h>
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#define MINIZ_NO_ZLIB_APIS
#include "miniz.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

void MakeDirectory(const std::string& path) {
  if (path.empty()) return;
#if defined(_WIN32)
  const int result = _mkdir(path.c_str());
#else
  const int result = mkdir(path.c_str(), 0755);
#endif
  if (result != 0 && errno != EEXIST) {
    throw std::runtime_error("Unable to create staging directory.");
  }
}

void MakeParents(const std::string& path, bool include_last) {
  std::size_t start = 0;
  while (true) {
    const std::size_t separator = path.find('/', start);
    if (separator == std::string::npos) break;
    if (separator > 0) MakeDirectory(path.substr(0, separator));
    start = separator + 1;
  }
  if (include_last) MakeDirectory(path);
}

void RemoveTree(const std::string& path) {
#if defined(_WIN32)
  const DWORD attributes = GetFileAttributesA(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) return;
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    if (!DeleteFileA(path.c_str())) {
      throw std::runtime_error("Unable to clean partial staging entry.");
    }
    return;
  }
  WIN32_FIND_DATAA entry{};
  const std::string pattern = path + "/*";
  HANDLE search = FindFirstFileA(pattern.c_str(), &entry);
  if (search != INVALID_HANDLE_VALUE) {
    do {
      const std::string name = entry.cFileName;
      if (name != "." && name != "..") RemoveTree(path + "/" + name);
    } while (FindNextFileA(search, &entry));
    FindClose(search);
  }
  if (!RemoveDirectoryA(path.c_str())) {
    throw std::runtime_error("Unable to clean partial staging directory.");
  }
#else
  struct stat status {};
  if (lstat(path.c_str(), &status) != 0) return;
  if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
    if (unlink(path.c_str()) != 0) {
      throw std::runtime_error("Unable to clean partial staging entry.");
    }
    return;
  }
  DIR* directory = opendir(path.c_str());
  if (directory == nullptr) {
    throw std::runtime_error("Unable to inspect partial staging directory.");
  }
  while (dirent* entry = readdir(directory)) {
    const std::string name = entry->d_name;
    if (name != "." && name != "..") RemoveTree(path + "/" + name);
  }
  closedir(directory);
  if (rmdir(path.c_str()) != 0) {
    throw std::runtime_error("Unable to clean partial staging directory.");
  }
#endif
}

bool IsDrivePrefixed(const std::string& path) {
  return path.size() >= 2 && std::isalpha(
      static_cast<unsigned char>(path[0])) && path[1] == ':';
}

std::string ArchiveComparisonKey(const std::string& path) {
#if defined(_WIN32)
  std::string result = path;
  std::transform(result.begin(), result.end(), result.begin(),
                 [](unsigned char value) {
                   return static_cast<char>(std::tolower(value));
                 });
  return result;
#else
  return path;
#endif
}

void CheckDuplicateConflict(const std::string& path,
                            bool directory,
                            std::map<std::string, bool>* entries) {
  const std::string key = ArchiveComparisonKey(path);
  const auto existing = entries->find(key);
  if (existing != entries->end()) {
    if (existing->second != directory) {
      throw std::runtime_error("Unsafe duplicate file/directory conflict.");
    }
    throw std::runtime_error("Unsafe duplicate archive entry.");
  }
  std::size_t separator = key.find('/');
  while (separator != std::string::npos) {
    const auto parent = entries->find(key.substr(0, separator));
    if (parent != entries->end() && !parent->second) {
      throw std::runtime_error("Unsafe duplicate file/directory conflict.");
    }
    separator = key.find('/', separator + 1);
  }
  if (!directory) {
    const std::string prefix = key + "/";
    const auto child = entries->lower_bound(prefix);
    if (child != entries->end() && child->first.rfind(prefix, 0) == 0) {
      throw std::runtime_error("Unsafe duplicate file/directory conflict.");
    }
  }
  entries->emplace(key, directory);
}

}  // namespace

std::string NormalizeSafeArchivePath(const std::string& input) {
  if (input.find('\0') != std::string::npos) {
    throw std::runtime_error("Unsafe archive path.");
  }
  std::string normalized = input;
  std::replace(normalized.begin(), normalized.end(), '\\', '/');
  if (normalized.empty() || normalized.front() == '/' ||
      IsDrivePrefixed(normalized)) {
    throw std::runtime_error("Unsafe archive path.");
  }
  std::vector<std::string> segments;
  std::size_t start = 0;
  while (start <= normalized.size()) {
    const std::size_t separator = normalized.find('/', start);
    const std::string segment = normalized.substr(start, separator - start);
    if (segment == "..") {
      throw std::runtime_error("Unsafe archive path traversal.");
    }
    if (!segment.empty() && segment != ".") segments.push_back(segment);
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
  if (segments.empty()) throw std::runtime_error("Unsafe archive path.");
  std::string result;
  for (const std::string& segment : segments) {
    if (segment.find(':') != std::string::npos) {
      throw std::runtime_error("Unsafe archive path.");
    }
    if (!result.empty()) result += '/';
    result += segment;
  }
  if (IsDrivePrefixed(result)) {
    throw std::runtime_error("Unsafe archive path.");
  }
  return result;
}

void RemoveStagingDirectory(const std::string& path) {
  RemoveTree(path);
}

void StageZipArchive(const std::string& archive_path,
                     const std::string& destination_path,
                     const ArchiveLimits& limits) {
  if (limits.maximum_archive_entries <= 0 ||
      limits.maximum_uncompressed_bytes <= 0 ||
      limits.maximum_single_entry_bytes <= 0) {
    throw std::invalid_argument("Archive limits must be positive.");
  }
  mz_zip_archive archive{};
  if (!mz_zip_reader_init_file(&archive, archive_path.c_str(), 0)) {
    throw std::runtime_error("Unable to open ZIP archive.");
  }
  try {
    const mz_uint count = mz_zip_reader_get_num_files(&archive);
    if (count == 0 ||
        count > static_cast<mz_uint64>(limits.maximum_archive_entries)) {
      throw std::runtime_error("Archive exceeds maximum_archive_entries.");
    }
    std::uint64_t total = 0;
    std::map<std::string, bool> entries;
    struct Entry {
      mz_uint index;
      std::string path;
      bool directory;
      std::uint32_t mode;
    };
    std::vector<Entry> staged;
    for (mz_uint index = 0; index < count; ++index) {
      mz_zip_archive_file_stat stat{};
      if (!mz_zip_reader_file_stat(&archive, index, &stat) ||
          stat.m_is_encrypted || !stat.m_is_supported) {
        throw std::runtime_error("Unsupported ZIP archive entry.");
      }
      const std::string path = NormalizeSafeArchivePath(stat.m_filename);
      const bool directory = stat.m_is_directory != 0;
      const std::uint32_t mode = stat.m_external_attr >> 16;
      const std::uint32_t type = mode & 0170000;
      if (type == 0120000 ||
          (type != 0 && type != 0100000 && type != 0040000)) {
        throw std::runtime_error(
            "Unsafe symbolic link or hard link archive entry.");
      }
      if (stat.m_uncomp_size >
          static_cast<mz_uint64>(limits.maximum_single_entry_bytes)) {
        throw std::runtime_error("Archive exceeds maximum_single_entry_bytes.");
      }
      const std::uint64_t maximum_total = static_cast<std::uint64_t>(
          limits.maximum_uncompressed_bytes);
      if (stat.m_uncomp_size > maximum_total ||
          total > maximum_total - stat.m_uncomp_size) {
        throw std::runtime_error("Archive exceeds maximum_uncompressed_bytes.");
      }
      total += stat.m_uncomp_size;
      CheckDuplicateConflict(path, directory, &entries);
      staged.push_back(Entry{index, path, directory, mode});
    }

    RemoveTree(destination_path);
    MakeParents(destination_path, true);
    for (const Entry& entry : staged) {
      const std::string output = destination_path + "/" + entry.path;
      MakeParents(output, entry.directory);
      if (!entry.directory &&
          !mz_zip_reader_extract_to_file(
              &archive, entry.index, output.c_str(), 0)) {
        throw std::runtime_error("ZIP extraction failed.");
      }
#if !defined(_WIN32)
      if (!entry.directory && (entry.mode & 0777) != 0) {
        chmod(output.c_str(), entry.mode & 0777);
      }
#endif
    }
    mz_zip_reader_end(&archive);
  } catch (...) {
    mz_zip_reader_end(&archive);
    try {
      RemoveTree(destination_path);
    } catch (...) {
      // Preserve the staging failure that triggered cleanup.
    }
    throw;
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
