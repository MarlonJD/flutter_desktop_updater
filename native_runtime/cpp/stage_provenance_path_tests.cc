#include "stage_provenance.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

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
  using desktop_updater::runtime::internal::FilesystemOwnedStage;
  using desktop_updater::runtime::internal::RemoveOwnedStage;
  using desktop_updater::runtime::internal::VerifyStageProvenance;
  using desktop_updater::runtime::internal::WriteStageProvenance;
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      "desktop_updater_native_path_test";
  const std::filesystem::path parent =
      root / std::filesystem::u8path(u8"güncelleme-日本");
  constexpr const char* nonce = "00000000-0000-4000-8000-000000000007";
  try {
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(parent);
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
    std::filesystem::remove_all(root);
    return 0;
  } catch (const std::exception& error) {
    std::filesystem::remove_all(root);
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
