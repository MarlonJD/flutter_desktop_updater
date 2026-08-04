#ifndef DESKTOP_UPDATER_RUNTIME_SHA256_OPENSSL_H_
#define DESKTOP_UPDATER_RUNTIME_SHA256_OPENSSL_H_

#include <cstdint>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {

std::vector<std::uint8_t> OpenSSLSha256(const std::string& value);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_SHA256_OPENSSL_H_
