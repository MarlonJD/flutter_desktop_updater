#include "artifact_stager_windows.h"

#include <windows.h>

#include <cstdlib>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#define MINIZ_NO_ZLIB_APIS
#include "miniz.h"

namespace {

std::string ReadFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Fixture file is missing.");
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::filesystem::path TemporaryPath(const std::string& suffix) {
  return std::filesystem::temp_directory_path() /
         ("desktop_updater_windows_stager_" +
          std::to_string(GetCurrentProcessId()) + suffix);
}

void WriteZip(const std::filesystem::path& path) {
  mz_zip_archive archive{};
  const std::string payload = "fixture";
  std::unique_ptr<FILE, decltype(&std::fclose)> archive_file(
      _wfopen(path.c_str(), L"w+b"), &std::fclose);
  if (!archive_file ||
      !mz_zip_writer_init_cfile(&archive, archive_file.get(), 0) ||
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

  const std::filesystem::path archive = TemporaryPath(".zip");
  const std::filesystem::path installer = TemporaryPath(".exe");
  const std::filesystem::path test_root = TemporaryPath("_unicode");
  const std::filesystem::path unicode_root =
      test_root /
      std::filesystem::u8path(u8"güncelleme-日本");
  const std::string staging_parent = unicode_root.u8string();
  std::filesystem::path destination;
  try {
    RemoveStagingDirectory(archive);
    RemoveStagingDirectory(installer);
    RemoveStagingDirectory(test_root);
    std::filesystem::create_directories(unicode_root);
    std::ofstream(unicode_root / L"sentinel.txt") << "caller-owned";
    WriteZip(archive);
    const auto zip_descriptor = ParseReleaseDescriptor(ReadFile(
        std::filesystem::u8path(arguments[1]) /
        "release-contract/release-windows-zip.json"));
    const auto staged = StageWindowsZip(
        archive.u8string(), staging_parent, zip_descriptor,
        "com.example.native-contract", ArchiveLimits{});
    destination = staged.stage_path;
    const std::filesystem::path staged_path = destination;
    const std::string manifest = ReadFile(
        staged_path / L".desktop_updater_release_manifest.json");
    if (manifest.find("com.example.native-contract") == std::string::npos ||
        ReadFile(staged_path / L"Example.exe") != "fixture" ||
        !std::filesystem::exists(
            staged_path / L".desktop_updater_stage_provenance.json") ||
        staged.provenance.marker.entries.empty()) {
      throw std::runtime_error(
          "Windows Unicode stage extraction or provenance differs.");
    }

    RemoveStagingDirectory(destination);
    std::ofstream dummy(installer, std::ios::binary);
    dummy << "unsigned fixture";
    dummy.close();
    const auto inno_descriptor = ParseReleaseDescriptor(ReadFile(
        std::filesystem::u8path(arguments[1]) /
        "release-contract/release-windows-inno.json"));
    bool rejected = false;
    try {
      StageWindowsInnoInstaller(
          installer.wstring(), staging_parent,
          inno_descriptor, "com.example.native-contract");
    } catch (const std::exception&) {
      rejected = true;
    }
    std::vector<std::filesystem::path> remaining;
    for (const auto& entry : std::filesystem::directory_iterator(unicode_root)) {
      remaining.push_back(entry.path().filename());
    }
    if (!rejected || remaining.size() != 1 ||
        remaining.front() != L"sentinel.txt" ||
        ReadFile(unicode_root / L"sentinel.txt") != "caller-owned") {
      throw std::runtime_error("Unsigned Inno fixture did not fail closed.");
    }
  } catch (const std::exception& error) {
    try {
      RemoveStagingDirectory(test_root);
      RemoveStagingDirectory(installer);
      RemoveStagingDirectory(archive);
    } catch (...) {
    }
    std::cerr << error.what() << std::endl;
    return 1;
  }
  RemoveStagingDirectory(test_root);
  RemoveStagingDirectory(installer);
  RemoveStagingDirectory(archive);
  return 0;
}
