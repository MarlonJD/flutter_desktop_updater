#ifndef DESKTOP_UPDATER_RUNTIME_UPDATE_TRANSPORT_WINHTTP_H_
#define DESKTOP_UPDATER_RUNTIME_UPDATE_TRANSPORT_WINHTTP_H_

#include "update_transport.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

std::string ResolveRedirectURL(const std::string& source,
                               const std::string& location);

class WinHttpUpdateTransport final : public UpdateTransport {
 public:
  explicit WinHttpUpdateTransport(TransportOptions options);
  std::vector<std::uint8_t> DownloadMetadata(
      const std::string& url) override;
  void DownloadArtifact(const ArtifactDownloadRequest& request) override;

 private:
  TransportOptions options_;
};

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_UPDATE_TRANSPORT_WINHTTP_H_
