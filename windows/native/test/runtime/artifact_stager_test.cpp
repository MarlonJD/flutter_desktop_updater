#include "artifact_stager_windows.h"

#include <windows.h>

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

#define MINIZ_NO_ZLIB_APIS
#include "miniz.h"

namespace {

std::string ReadFile(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Fixture file is missing.");
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::string TemporaryPath(const std::string& suffix) {
  const char* root = std::getenv("TEMP");
  return std::string(root == nullptr ? "." : root) +
         "/desktop_updater_windows_stager_" +
         std::to_string(GetCurrentProcessId()) + suffix;
}

void WriteZip(const std::string& path) {
  mz_zip_archive archive{};
  const std::string payload = "fixture";
  if (!mz_zip_writer_init_file(&archive, path.c_str(), 0) ||
      !mz_zip_writer_add_mem(&archive, "Example.exe", payload.data(),
                             payload.size(), MZ_DEFAULT_COMPRESSION)) {
    mz_zip_writer_end(&archive);
    throw std::runtime_error("Unable to create Windows ZIP fixture.");
  }
  const bool finalized = mz_zip_writer_finalize_archive(&archive) != 0;
  const bool ended = mz_zip_writer_end(&archive) != 0;
  if (!finalized || !ended) {
    throw std::runtime_error("Unable to finalize Windows ZIP fixture.");
  }
}

}  // namespace

int main(int argument_count, char** arguments) {
  if (argument_count != 2) return 2;
  using desktop_updater::runtime::internal::ArchiveLimits;
  using desktop_updater::runtime::internal::ParseReleaseDescriptor;
  using desktop_updater::runtime::internal::RemoveStagingDirectory;
  using desktop_updater::runtime::internal::StageWindowsInnoInstaller;
  using desktop_updater::runtime::internal::StageWindowsZip;

  const std::string archive = TemporaryPath(".zip");
  const std::string installer = TemporaryPath(".exe");
  const std::string staging_parent = TemporaryPath("_staging_parent");
  std::string destination;
  try {
    RemoveStagingDirectory(archive);
    RemoveStagingDirectory(installer);
    RemoveStagingDirectory(staging_parent);
    CreateDirectoryA(staging_parent.c_str(), nullptr);
    std::ofstream(staging_parent + "/sentinel.txt") << "caller-owned";
    WriteZip(archive);
    const auto zip_descriptor = ParseReleaseDescriptor(ReadFile(
        std::string(arguments[1]) +
        "/release-contract/release-windows-zip.json"));
    const auto staged = StageWindowsZip(
        archive, staging_parent, zip_descriptor,
        "com.example.native-contract", ArchiveLimits{});
    destination = staged.stage_path;
    const std::string manifest = ReadFile(
        destination + "/.desktop_updater_release_manifest.json");
    if (manifest.find("com.example.native-contract") == std::string::npos) {
      throw std::runtime_error("Windows release manifest is not identity-bound.");
    }

    RemoveStagingDirectory(destination);
    std::ofstream dummy(installer, std::ios::binary);
    dummy << "unsigned fixture";
    dummy.close();
    const auto inno_descriptor = ParseReleaseDescriptor(ReadFile(
        std::string(arguments[1]) +
        "/release-contract/release-windows-inno.json"));
    bool rejected = false;
    try {
      StageWindowsInnoInstaller(
          std::wstring(installer.begin(), installer.end()), staging_parent,
          inno_descriptor, "com.example.native-contract");
    } catch (const std::exception&) {
      rejected = true;
    }
    if (!rejected ||
        GetFileAttributesA(destination.c_str()) != INVALID_FILE_ATTRIBUTES ||
        ReadFile(staging_parent + "/sentinel.txt") != "caller-owned") {
      throw std::runtime_error("Unsigned Inno fixture did not fail closed.");
    }
  } catch (const std::exception& error) {
    try {
      RemoveStagingDirectory(staging_parent);
      RemoveStagingDirectory(installer);
      RemoveStagingDirectory(archive);
    } catch (...) {
    }
    std::cerr << error.what() << std::endl;
    return 1;
  }
  RemoveStagingDirectory(staging_parent);
  RemoveStagingDirectory(installer);
  RemoveStagingDirectory(archive);
  return 0;
}
