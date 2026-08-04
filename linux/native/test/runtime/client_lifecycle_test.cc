#include <exception>
#include <iostream>

#include "client_lifecycle_tests.h"

int main() {
  try {
    desktop_updater::runtime::internal::RunClientLifecycleTests();
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
