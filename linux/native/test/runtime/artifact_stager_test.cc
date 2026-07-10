#include "artifact_stager_linux.h"

#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

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
  const char* root = std::getenv("TMPDIR");
  char canonical_root[PATH_MAX];
  const char* candidate = root == nullptr ? "/tmp" : root;
  const char* resolved = realpath(candidate, canonical_root);
  return std::string(resolved == nullptr ? candidate : resolved) +
         "/desktop_updater_linux_stager_" + std::to_string(getpid()) + suffix;
}

void WriteExecutableZip(const std::string& archive_path,
                        const std::string& source_path) {
  std::ofstream source(source_path, std::ios::binary);
  source << "#!/bin/sh\nexit 0\n";
  source.close();
  chmod(source_path.c_str(), 0755);

  mz_zip_archive archive{};
  if (!mz_zip_writer_init_file(&archive, archive_path.c_str(), 0) ||
      !mz_zip_writer_add_file(&archive, "Example", source_path.c_str(),
                              nullptr, 0, MZ_DEFAULT_COMPRESSION)) {
    mz_zip_writer_end(&archive);
    throw std::runtime_error("Unable to create Linux ZIP fixture.");
  }
  const bool finalized = mz_zip_writer_finalize_archive(&archive) != 0;
  const bool ended = mz_zip_writer_end(&archive) != 0;
  if (!finalized || !ended) {
    throw std::runtime_error("Unable to finalize Linux ZIP fixture.");
  }

  std::fstream file(archive_path, std::ios::in | std::ios::out |
                                      std::ios::binary);
  const std::istreambuf_iterator<char> begin(file);
  const std::istreambuf_iterator<char> end;
  std::vector<unsigned char> bytes(begin, end);
  bool patched = false;
  for (std::size_t index = 0; index + 42 <= bytes.size(); ++index) {
    if (bytes[index] == 0x50 && bytes[index + 1] == 0x4b &&
        bytes[index + 2] == 0x01 && bytes[index + 3] == 0x02) {
      bytes[index + 5] = 3;
      const std::uint32_t attributes = 0100755U << 16;
      for (int byte = 0; byte < 4; ++byte) {
        bytes[index + 38 + byte] = static_cast<unsigned char>(
            (attributes >> (byte * 8)) & 0xffU);
      }
      patched = true;
    }
  }
  if (!patched) {
    throw std::runtime_error("Linux ZIP central directory is missing.");
  }
  file.clear();
  file.seekp(0);
  file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  if (!file) {
    throw std::runtime_error("Unable to patch Linux ZIP permissions.");
  }
}

}  // namespace

int main(int argument_count, char** arguments) {
  if (argument_count != 2) return 2;
  using desktop_updater::runtime::internal::ArchiveLimits;
  using desktop_updater::runtime::internal::ParseReleaseDescriptor;
  using desktop_updater::runtime::internal::RemoveStagingDirectory;
  using desktop_updater::runtime::internal::StageLinuxZip;

  const std::string archive = TemporaryPath(".zip");
  const std::string source = TemporaryPath("_source");
  const std::string destination = TemporaryPath("_staging");
  const std::string install_root = TemporaryPath("_install");
  try {
    RemoveStagingDirectory(archive);
    RemoveStagingDirectory(source);
    RemoveStagingDirectory(destination);
    RemoveStagingDirectory(install_root);
    mkdir(install_root.c_str(), 0755);
    WriteExecutableZip(archive, source);
    const auto descriptor = ParseReleaseDescriptor(ReadFile(
        std::string(arguments[1]) +
        "/release-contract/release-linux-zip.json"));
    StageLinuxZip(archive, destination, "Example", descriptor,
                  "com.example.native-contract", ArchiveLimits{});

    struct stat executable {};
    if (stat((destination + "/Example").c_str(), &executable) != 0 ||
        (executable.st_mode & S_IXUSR) == 0) {
      throw std::runtime_error("Linux executable permission was not preserved.");
    }
    const std::string manifest = ReadFile(
        destination + "/.desktop_updater_release_manifest.json");
    if (manifest.find("com.example.native-contract") == std::string::npos) {
      throw std::runtime_error("Linux release manifest is not identity-bound.");
    }
    const auto valid_handoff =
        desktop_updater::runtime::internal::ValidateLinuxInstallHandoff(
            destination, install_root, "Example",
            "com.example.native-contract", {}, "");
    if (!valid_handoff.ok) {
      throw std::runtime_error("Validated Linux install handoff was rejected.");
    }
    const auto protected_handoff =
        desktop_updater::runtime::internal::ValidateLinuxInstallHandoff(
            destination, "/usr/bin", "Example",
            "com.example.native-contract", {}, "");
    if (protected_handoff.ok) {
      throw std::runtime_error("Protected Linux install root was accepted.");
    }

    RemoveStagingDirectory(destination);
    bool rejected = false;
    try {
      StageLinuxZip(archive, destination, "Example", descriptor,
                    "com.example.wrong", ArchiveLimits{});
    } catch (const std::exception&) {
      rejected = true;
    }
    struct stat status {};
    if (!rejected || lstat(destination.c_str(), &status) == 0) {
      throw std::runtime_error("Linux package mismatch did not fail closed.");
    }
  } catch (const std::exception& error) {
    try {
      RemoveStagingDirectory(destination);
      RemoveStagingDirectory(install_root);
      RemoveStagingDirectory(source);
      RemoveStagingDirectory(archive);
    } catch (...) {
    }
    std::cerr << error.what() << std::endl;
    return 1;
  }
  RemoveStagingDirectory(destination);
  RemoveStagingDirectory(install_root);
  RemoveStagingDirectory(source);
  RemoveStagingDirectory(archive);
  return 0;
}
