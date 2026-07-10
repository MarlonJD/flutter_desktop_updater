#include "archive_fixture_tests.h"
#include "contract_fixture_tests.h"
#include "diagnostics_fixture_tests.h"
#include "sha256_bcrypt.h"

#include <exception>
#include <iostream>
#include <string>

int main(int argument_count, char** arguments) {
  if (argument_count != 2) return 2;
  try {
    desktop_updater::runtime::internal::RunContractFixtureTests(
        arguments[1],
        desktop_updater::runtime::internal::BCryptSha256);
    desktop_updater::runtime::internal::RunArchivePathFixtureTests(arguments[1]);
    desktop_updater::runtime::internal::RunArchiveStagerTests();
    desktop_updater::runtime::internal::RunDiagnosticsFixtureTests(arguments[1]);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
