#ifndef DESKTOP_UPDATER_RUNTIME_TRANSPORT_FIXTURE_TESTS_H_
#define DESKTOP_UPDATER_RUNTIME_TRANSPORT_FIXTURE_TESTS_H_

#include <string>

#include "release_contract.h"
#include "update_transport.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

void RunTransportFixtureTests(UpdateTransport* transport,
                              const std::string& base_url,
                              const std::string& temporary_directory,
                              const Sha256Function& sha256);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_TRANSPORT_FIXTURE_TESTS_H_
