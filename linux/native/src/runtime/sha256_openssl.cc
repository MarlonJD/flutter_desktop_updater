#include "sha256_openssl.h"

#include <openssl/evp.h>

#include <memory>
#include <stdexcept>

namespace desktop_updater {
namespace runtime {
namespace internal {

std::vector<std::uint8_t> OpenSSLSha256(const std::string& value) {
  std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context(
      EVP_MD_CTX_new(), EVP_MD_CTX_free);
  if (!context ||
      EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) != 1 ||
      EVP_DigestUpdate(context.get(), value.data(), value.size()) != 1) {
    throw std::runtime_error("OpenSSL SHA-256 initialization failed.");
  }
  std::vector<std::uint8_t> output(EVP_MAX_MD_SIZE);
  unsigned int output_size = 0;
  if (EVP_DigestFinal_ex(context.get(), output.data(), &output_size) != 1 ||
      output_size != 32) {
    throw std::runtime_error("OpenSSL SHA-256 finalization failed.");
  }
  output.resize(output_size);
  return output;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
