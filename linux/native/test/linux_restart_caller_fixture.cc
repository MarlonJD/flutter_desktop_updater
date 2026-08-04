#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>

#include "desktop_updater_native.h"

int main(int argc, char** argv) {
  const char* proof_path =
      std::getenv("DESKTOP_UPDATER_TEST_RESTART_PROOF");
  const char* exit_proof_path =
      std::getenv("DESKTOP_UPDATER_TEST_RESTART_EXIT_PROOF");
  if (argc == 1 && proof_path != nullptr && proof_path[0] != '\0') {
    std::ofstream proof(proof_path, std::ios::binary | std::ios::trunc);
    std::ifstream exit_proof(exit_proof_path == nullptr ? "" : exit_proof_path,
                             std::ios::binary);
    proof << (exit_proof.good() ? "restarted-after-exit\n"
                                : "restarted-before-exit\n");
    proof.close();
    return proof.good() ? 0 : 3;
  }

  if (argc == 2 && std::string(argv[1]) == "--restart") {
    const auto result =
        desktop_updater::native::RestartCurrentApplication();
    if (!result.ok) {
      std::cerr << result.error << '\n';
      return 1;
    }
    usleep(300'000);
    std::ofstream exit_proof(exit_proof_path == nullptr ? "" : exit_proof_path,
                             std::ios::binary | std::ios::trunc);
    exit_proof << "old-process-exiting\n";
    exit_proof.close();
    if (!exit_proof.good()) return 4;
    return 0;
  }

  return 2;
}
