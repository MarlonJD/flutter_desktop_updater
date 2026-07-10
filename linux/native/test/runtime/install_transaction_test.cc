#include <exception>
#include <iostream>

#include "install_transaction_tests.h"

int main() {
  try {
    desktop_updater::runtime::internal::RunInstallTransactionTests();
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
