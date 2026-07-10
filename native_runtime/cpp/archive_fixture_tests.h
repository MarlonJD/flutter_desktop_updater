#ifndef DESKTOP_UPDATER_RUNTIME_ARCHIVE_FIXTURE_TESTS_H_
#define DESKTOP_UPDATER_RUNTIME_ARCHIVE_FIXTURE_TESTS_H_

#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {

void RunArchivePathFixtureTests(const std::string& fixture_root);
void RunArchiveStagerTests();

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_ARCHIVE_FIXTURE_TESTS_H_
