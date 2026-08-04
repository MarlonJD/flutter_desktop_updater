#include "archive_fixture_tests.h"

#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#if defined(_WIN32)
#include <process.h>
#include <windows.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

#include "artifact_stager.h"
#include "json_value.h"
#define MINIZ_NO_ZLIB_APIS
#include "miniz.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string TemporaryPath(const std::string& suffix) {
#if defined(_WIN32)
  const char* root = std::getenv("TEMP");
  const int process = _getpid();
#else
  const char* root = std::getenv("TMPDIR");
  const int process = getpid();
#endif
  const std::string base = root == nullptr ? "." : root;
  return base + "/desktop_updater_archive_" + std::to_string(process) +
         suffix;
}

void WriteZip(
    const std::string& path,
    const std::vector<std::pair<std::string, std::string>>& entries) {
  RemoveStagingDirectory(path);
  mz_zip_archive archive{};
  if (!mz_zip_writer_init_file(&archive, path.c_str(), 0)) {
    throw std::runtime_error("Unable to create archive fixture.");
  }
  for (const auto& entry : entries) {
    if (!mz_zip_writer_add_mem(&archive, entry.first.c_str(),
                               entry.second.data(), entry.second.size(),
                               MZ_DEFAULT_COMPRESSION)) {
      mz_zip_writer_end(&archive);
      throw std::runtime_error("Unable to add archive fixture entry.");
    }
  }
  const bool finalized = mz_zip_writer_finalize_archive(&archive) != 0;
  const bool ended = mz_zip_writer_end(&archive) != 0;
  if (!finalized || !ended) {
    throw std::runtime_error("Unable to finalize archive fixture.");
  }
}

bool PathExists(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (input) return true;
#if defined(_WIN32)
  return GetFileAttributesA(path.c_str()) != INVALID_FILE_ATTRIBUTES;
#else
  struct stat status {};
  return lstat(path.c_str(), &status) == 0;
#endif
}

}  // namespace

void RunArchivePathFixtureTests(const std::string& fixture_root) {
  std::ifstream input(fixture_root + "/safe-path-cases.json");
  if (!input) throw std::runtime_error("Safe-path fixture is missing.");
  const JsonValue fixture = ParseJson(std::string(
      std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()));
  for (const JsonValue& entry : fixture.at("archivePathCases").array()) {
    bool valid = true;
    std::string normalized;
    try {
      normalized = NormalizeSafeArchivePath(entry.at("input").string());
    } catch (const std::exception&) {
      valid = false;
    }
    if (valid != entry.at("expectedValid").boolean()) {
      throw std::runtime_error("Archive path validity differs from Dart.");
    }
    const JsonValue& expected = entry.at("expectedNormalized");
    if (valid && expected.type() == JsonValue::Type::kString &&
        normalized != expected.string()) {
      throw std::runtime_error("Archive path normalization differs from Dart.");
    }
  }
}

void RunArchiveStagerTests() {
  const std::string archive = TemporaryPath(".zip");
  const std::string destination = TemporaryPath("_staging");
  try {
    WriteZip(archive, {{"Example/bin/app", "executable"},
                       {"Example/data.txt", "fixture"}});
    StageZipArchive(archive, destination, ArchiveLimits{});
    if (!PathExists(destination + "/Example/bin/app")) {
      throw std::runtime_error("Safe archive was not extracted.");
    }

    ArchiveLimits single_entry_limit;
    single_entry_limit.maximum_single_entry_bytes = 4;
    bool rejected = false;
    try {
      StageZipArchive(archive, destination, single_entry_limit);
    } catch (const std::exception&) {
      rejected = true;
    }
    if (!rejected || PathExists(destination)) {
      throw std::runtime_error(
          "Archive limit failure did not clean partial staging.");
    }

    ArchiveLimits total_limit;
    total_limit.maximum_uncompressed_bytes = 4;
    total_limit.maximum_single_entry_bytes = 64;
    rejected = false;
    try {
      StageZipArchive(archive, destination, total_limit);
    } catch (const std::exception&) {
      rejected = true;
    }
    if (!rejected || PathExists(destination)) {
      throw std::runtime_error(
          "Archive total limit failure did not clean partial staging.");
    }

    WriteZip(archive, {{"../escape.txt", "unsafe"}});
    rejected = false;
    try {
      StageZipArchive(archive, destination, ArchiveLimits{});
    } catch (const std::exception&) {
      rejected = true;
    }
    if (!rejected || PathExists(destination)) {
      throw std::runtime_error(
          "Unsafe archive path did not fail before extraction.");
    }

    WriteZip(archive, {{"conflict", "file"},
                       {"conflict/child.txt", "child"}});
    rejected = false;
    try {
      StageZipArchive(archive, destination, ArchiveLimits{});
    } catch (const std::exception&) {
      rejected = true;
    }
    if (!rejected || PathExists(destination)) {
      throw std::runtime_error(
          "Archive file/directory conflict was not rejected.");
    }
  } catch (...) {
    try {
      RemoveStagingDirectory(destination);
      RemoveStagingDirectory(archive);
    } catch (...) {
    }
    throw;
  }
  RemoveStagingDirectory(destination);
  RemoveStagingDirectory(archive);
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
