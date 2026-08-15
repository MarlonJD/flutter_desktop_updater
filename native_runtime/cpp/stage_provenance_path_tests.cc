#include "stage_provenance.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace {

std::vector<std::uint8_t> FixtureSha256(const std::string& value) {
  std::vector<std::uint8_t> result(32, 0);
  for (std::size_t index = 0; index < value.size(); ++index) {
    result[index % result.size()] ^= static_cast<std::uint8_t>(value[index]);
  }
  return result;
}

}  // namespace

int main() {
  using desktop_updater::runtime::internal::CreateOwnedStage;
  using desktop_updater::runtime::internal::CanonicalStageDirectory;
  using desktop_updater::runtime::internal::FilesystemOwnedStage;
  using desktop_updater::runtime::internal::RemoveOwnedStage;
  using desktop_updater::runtime::internal::VerifyStageProvenance;
  using desktop_updater::runtime::internal::WriteStageProvenance;
  using desktop_updater::runtime::internal::kOwnedStagePrefix;
  using desktop_updater::runtime::internal::kStageProvenanceFileName;
  const std::filesystem::path test_directory =
      std::filesystem::current_path();
  const std::filesystem::path root =
      test_directory / "desktop_updater_native_path_test";
#if defined(_WIN32)
  const std::string long_root_prefix = "desktop_updater_native_long_path_";
  const std::string long_parent_name = "long-parent";
  const std::string long_root_suffix =
      "-" + std::to_string(GetCurrentProcessId());
  const std::size_t fixed_long_stage_length =
      test_directory.wstring().size() + 1 + long_root_prefix.size() +
      long_root_suffix.size() + 1 + long_parent_name.size() + 1 +
      std::string(kOwnedStagePrefix).size() + 36;
  const std::size_t long_root_padding =
      fixed_long_stage_length < 245 ? 245 - fixed_long_stage_length : 1;
  const std::filesystem::path long_root =
      test_directory /
      (long_root_prefix + std::string(long_root_padding, 'x') +
       long_root_suffix);
#endif
  const std::filesystem::path parent =
      root / std::filesystem::u8path(u8"güncelleme-日本");
  constexpr const char* nonce = "00000000-0000-4000-8000-000000000007";
  try {
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(parent);
    const std::filesystem::path canonical_parent =
        CanonicalStageDirectory(parent, "Canonical parent");
    const std::filesystem::path trailing_parent = parent / "";
    if (CanonicalStageDirectory(trailing_parent, "Trailing parent") !=
        canonical_parent) {
      throw std::runtime_error(
          "Canonical directory retained a trailing non-root separator.");
    }
    const std::filesystem::path filesystem_root = parent.root_path();
    if (CanonicalStageDirectory(filesystem_root, "Filesystem root") !=
        filesystem_root) {
      throw std::runtime_error("Canonical directory changed root semantics.");
    }
    std::ofstream(parent / "sentinel.txt") << "caller-owned";
    const FilesystemOwnedStage stage = CreateOwnedStage(parent, nonce);
    std::ofstream(stage.path / std::filesystem::u8path(u8"uygulama-日本.bin"))
        << "fixture";
    const auto provenance = WriteStageProvenance(
        stage, "com.example.native-path", std::string(64, '1'),
        std::string(64, '2'), FixtureSha256);
    VerifyStageProvenance(stage.path, provenance.marker_sha256, FixtureSha256);
    RemoveOwnedStage(parent, stage.path, stage.nonce, FixtureSha256);
    if (std::filesystem::exists(stage.path) ||
        !std::filesystem::exists(parent / "sentinel.txt")) {
      throw std::runtime_error("Native owned-stage cleanup escaped its child.");
    }
#if defined(_WIN32)
    const std::filesystem::path long_parent = long_root / long_parent_name;
    std::filesystem::remove_all(long_root);
    std::filesystem::create_directories(long_parent);
    constexpr const char* long_nonce =
        "00000000-0000-4000-8000-000000000008";
    const FilesystemOwnedStage long_stage =
        CreateOwnedStage(long_parent, long_nonce);
    const std::filesystem::path long_marker =
        long_stage.path / std::filesystem::u8path(kStageProvenanceFileName);
    if (long_marker.wstring().size() <= 260) {
      throw std::runtime_error(
          "Long-path provenance test did not exceed MAX_PATH.");
    }
    const auto long_provenance = WriteStageProvenance(
        long_stage, "com.example.native-long-path", std::string(64, '3'),
        std::string(64, '4'), FixtureSha256);
    VerifyStageProvenance(long_stage.path, long_provenance.marker_sha256,
                          FixtureSha256);
    RemoveOwnedStage(long_parent, long_stage.path, long_stage.nonce,
                     FixtureSha256);
    if (std::filesystem::exists(long_stage.path)) {
      throw std::runtime_error("Long-path owned-stage cleanup failed.");
    }
    std::filesystem::remove_all(long_root);
#endif
    std::filesystem::remove_all(root);
    return 0;
  } catch (const std::exception& error) {
    std::error_code cleanup_error;
    std::filesystem::remove_all(root, cleanup_error);
#if defined(_WIN32)
    std::filesystem::remove_all(long_root, cleanup_error);
#endif
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
