#ifndef DESKTOP_UPDATER_RUNTIME_UPDATE_CLIENT_CORE_FIXTURE_TESTS_H_
#define DESKTOP_UPDATER_RUNTIME_UPDATE_CLIENT_CORE_FIXTURE_TESTS_H_

#include <string>

#include "release_contract.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

void RunUpdateClientCoreFixtureTests(const std::string& fixture_root,
                                     const Sha256Function& sha256);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_UPDATE_CLIENT_CORE_FIXTURE_TESTS_H_
