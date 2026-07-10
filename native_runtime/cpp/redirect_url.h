#ifndef DESKTOP_UPDATER_RUNTIME_REDIRECT_URL_H_
#define DESKTOP_UPDATER_RUNTIME_REDIRECT_URL_H_

#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {

std::string ResolveRedirectURL(const std::string& source,
                               const std::string& location);

std::string HTTPRequestTarget(const std::string& url);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_REDIRECT_URL_H_
