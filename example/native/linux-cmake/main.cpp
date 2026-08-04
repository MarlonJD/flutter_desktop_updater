#include <openssl/evp.h>
#include <unistd.h>

#include <array>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>

#include "desktop_updater_native.h"
#include "desktop_updater_version.h"

#ifndef DESKTOP_UPDATER_INSTALLED_HELPER_PATH
#error "The installed package must expose its helper path to this consumer."
#endif

namespace {

namespace fs = std::filesystem;

constexpr char kPackageId[] =
    "com.example.desktop-updater.installed-consumer";

std::string Sha256File(const fs::path& path) {
  using Context = std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)>;
  Context context(EVP_MD_CTX_new(), EVP_MD_CTX_free);
  if (!context || EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) !=
                      1) {
    throw std::runtime_error("Unable to initialize the SHA-256 fixture.");
  }
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("Unable to read " + path.string());
  }
  std::array<char, 64 * 1024> buffer{};
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize count = input.gcount();
    if (count > 0 && EVP_DigestUpdate(context.get(), buffer.data(),
                                      static_cast<std::size_t>(count)) != 1) {
      throw std::runtime_error("Unable to hash " + path.string());
    }
  }
  if (!input.eof()) {
    throw std::runtime_error("Unable to finish reading " + path.string());
  }
  std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
  unsigned int digest_length = 0;
  if (EVP_DigestFinal_ex(context.get(), digest.data(), &digest_length) != 1 ||
      digest_length != 32) {
    throw std::runtime_error("Unable to finish the SHA-256 fixture.");
  }
  std::ostringstream encoded;
  encoded << std::hex << std::setfill('0');
  for (std::size_t index = 0; index < digest_length; ++index) {
    encoded << std::setw(2) << static_cast<unsigned int>(digest[index]);
  }
  return encoded.str();
}

fs::path CurrentExecutable() {
  std::array<char, 4096> buffer{};
  const ssize_t length =
      readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
  if (length <= 0 || static_cast<std::size_t>(length) >= buffer.size()) {
    throw std::runtime_error("Installed consumer executable is unavailable.");
  }
  return fs::canonical(std::string(buffer.data(),
                                   static_cast<std::size_t>(length)));
}

int Exchange(const fs::path& stage) {
  const fs::path executable = CurrentExecutable();
  const fs::path install_root = executable.parent_path();
  const fs::path expected_helper =
      install_root.parent_path() / "libexec" / "desktop-updater-helper";
  const fs::path exported_helper(DESKTOP_UPDATER_INSTALLED_HELPER_PATH);
  if (fs::canonical(exported_helper) != fs::canonical(expected_helper)) {
    std::cerr << "Installed helper metadata is not relocatable." << std::endl;
    return 2;
  }

  desktop_updater::native::InstallRequest request;
  request.staging_path = fs::canonical(stage).string();
  request.install_root = install_root.string();
  request.executable_relative_path = executable.filename().string();
  request.package_id = kPackageId;
  request.expected_provenance_sha256 = Sha256File(
      stage / ".desktop_updater_stage_provenance.json");
  request.expected_artifact_sha256 = Sha256File(
      stage / ".desktop_updater_artifact.zip");

  desktop_updater::native::InstallReservation reservation;
  const std::string transaction_id =
      "123e4567-e89b-42d3-a456-426614174000";
  const auto prepared =
      desktop_updater::native::PrepareInstall(request, transaction_id,
                                              &reservation);
  if (!prepared.ok || reservation.transaction_id.empty()) {
    std::cerr << "PrepareInstall failed: " << prepared.error << std::endl;
    return 3;
  }
  const auto committed =
      desktop_updater::native::CommitAfterExit(reservation);
  if (committed.state !=
          desktop_updater::native::InstallTransactionState::kCommitAccepted ||
      committed.result_code != desktop_updater::native::
                                   InstallTransactionResultCode::kAccepted) {
    std::cerr << "CommitAfterExit failed: " << committed.detail << std::endl;
    return 4;
  }
  const auto queried = desktop_updater::native::QueryTransaction(
      reservation.transaction_id);
  if (queried.transaction_id != reservation.transaction_id ||
      queried.state !=
          desktop_updater::native::InstallTransactionState::kPrepared ||
      queried.result_code != desktop_updater::native::
                                 InstallTransactionResultCode::
                                     kRecoveryRequired ||
      queried.helper_endpoint_identity_sha256 !=
          reservation.helper_endpoint_identity_sha256) {
    std::cerr << "QueryTransaction failed: " << queried.detail << std::endl;
    return 5;
  }
  std::cout << "transaction=" << reservation.transaction_id << '\n'
            << "commitCode="
            << static_cast<unsigned int>(committed.result_code) << '\n'
            << "queryCode="
            << static_cast<unsigned int>(queried.result_code) << std::endl;
  return 0;
}

int Recover(const std::string& transaction_id) {
  const auto recovered =
      desktop_updater::native::RecoverPendingInstall(transaction_id);
  if (recovered.result_code == desktop_updater::native::
                                   InstallTransactionResultCode::
                                       kEndpointUnavailable) {
    std::cerr << "RecoverPendingInstall failed: " << recovered.detail
              << std::endl;
    return 6;
  }
  std::cout << "recoveryCode="
            << static_cast<unsigned int>(recovered.result_code) << std::endl;
  return 0;
}

}  // namespace

int main(int argc, char** argv) try {
  if (DESKTOP_UPDATER_NATIVE_VERSION_STRING[0] == '\0') return 1;
  if (argc == 1) {
    std::cout << "desktop_updater_native "
              << DESKTOP_UPDATER_NATIVE_VERSION_STRING
              << " installed consumer compiled" << std::endl;
    return 0;
  }
  if (argc == 3 && std::string(argv[1]) == "--exchange") {
    return Exchange(fs::path(argv[2]));
  }
  if (argc == 3 && std::string(argv[1]) == "--recover") {
    return Recover(argv[2]);
  }
  std::cerr << "usage: linux_installed_consumer "
               "[--exchange STAGE | --recover TRANSACTION]"
            << std::endl;
  return 64;
} catch (const std::exception& error) {
  std::cerr << error.what() << std::endl;
  return 70;
}
