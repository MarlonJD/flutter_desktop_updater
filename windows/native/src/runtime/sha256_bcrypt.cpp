#include "sha256_bcrypt.h"

#include <windows.h>

#include <bcrypt.h>

#include <stdexcept>

namespace desktop_updater {
namespace runtime {
namespace internal {

std::vector<std::uint8_t> BCryptSha256(const std::string& value) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(
          &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) {
    throw std::runtime_error("BCrypt SHA-256 provider failed.");
  }
  std::vector<std::uint8_t> output(32);
  const NTSTATUS create_status = BCryptCreateHash(
      algorithm, &hash, nullptr, 0, nullptr, 0, 0);
  const NTSTATUS hash_status = create_status < 0
                                   ? create_status
                                   : BCryptHashData(
                                         hash,
                                         reinterpret_cast<PUCHAR>(
                                             const_cast<char*>(value.data())),
                                         static_cast<ULONG>(value.size()), 0);
  const NTSTATUS finish_status =
      hash_status < 0
          ? hash_status
          : BCryptFinishHash(hash, output.data(),
                             static_cast<ULONG>(output.size()), 0);
  if (hash != nullptr) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (finish_status < 0) {
    throw std::runtime_error("BCrypt SHA-256 operation failed.");
  }
  return output;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
