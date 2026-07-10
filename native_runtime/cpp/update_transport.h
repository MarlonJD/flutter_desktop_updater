#ifndef DESKTOP_UPDATER_RUNTIME_UPDATE_TRANSPORT_H_
#define DESKTOP_UPDATER_RUNTIME_UPDATE_TRANSPORT_H_

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {

using HeadersProvider = std::function<std::map<std::string, std::string>(
    const std::string& url)>;
using DownloadProgress =
    std::function<void(std::int64_t received, std::int64_t total)>;

struct TransportOptions {
  std::int64_t timeout_milliseconds = 30000;
  std::int64_t maximum_metadata_bytes = 4LL * 1024LL * 1024LL;
  int maximum_redirects = 5;
  int maximum_retries = 3;
  HeadersProvider request_headers_provider;
};

struct ArtifactDownloadRequest {
  std::string url;
  std::string destination_path;
  std::int64_t expected_length = 0;
  std::string expected_sha256;
  DownloadProgress progress;
};

class UpdateTransport {
 public:
  virtual ~UpdateTransport() = default;
  virtual std::vector<std::uint8_t> DownloadMetadata(
      const std::string& url) = 0;
  virtual void DownloadArtifact(const ArtifactDownloadRequest& request) = 0;
};

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_UPDATE_TRANSPORT_H_
