#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <unistd.h>

#include "desktop_updater_native.h"

int main(int argc, char** argv) {
  if (argc == 1) {
    const char* proof = std::getenv("DESKTOP_UPDATER_TEST_RELAUNCH_PROOF");
    if (proof == nullptr) return 64;
    const int group_count = getgroups(0, nullptr);
    std::vector<gid_t> groups(group_count < 0 ? 0 : group_count);
    if (group_count < 0 ||
        (group_count > 0 &&
         getgroups(group_count, groups.data()) != group_count)) {
      return 65;
    }
    std::ofstream result(proof, std::ios::binary | std::ios::trunc);
    result << "uid=" << getuid() << '\n' << "euid=" << geteuid() << '\n'
           << "gid=" << getgid() << '\n' << "egid=" << getegid() << '\n'
           << "groups=";
    for (std::size_t index = 0; index < groups.size(); ++index) {
      if (index != 0) result << ',';
      result << groups[index];
    }
    result << '\n' << "secret="
           << (std::getenv("DESKTOP_UPDATER_ROOT_SECRET") == nullptr
                   ? "absent"
                   : "present")
           << '\n';
    return result.good() ? 0 : 66;
  }
  if (argc == 4 &&
      (std::string(argv[1]) == "--query" ||
       std::string(argv[1]) == "--recover")) {
    std::ofstream result(argv[3], std::ios::binary | std::ios::trunc);
    const auto status = std::string(argv[1]) == "--query"
                            ? desktop_updater::native::QueryTransaction(argv[2])
                            : desktop_updater::native::RecoverPendingInstall(
                                  argv[2]);
    result << "state\n" << static_cast<unsigned int>(status.state) << '\n'
           << "code\n" << static_cast<unsigned int>(status.result_code)
           << '\n' << "detail\n" << status.detail << '\n';
    return status.state ==
                   desktop_updater::native::InstallTransactionState::kCompleted
               ? 0
               : 5;
  }
  if (argc != 5) return 64;
  const std::string target = argv[1];
  const std::string stage = argv[2];
    const std::string result_path = argv[4];
  std::ofstream result(result_path, std::ios::binary | std::ios::trunc);
  try {
    desktop_updater::native::InstallRequest request;
    request.operation = desktop_updater::native::LinuxInstallOperation::kInstall;
    request.staging_path = stage;
    request.install_root = target;
    request.executable_relative_path = "linux_commit_caller_fixture";
    request.package_id = "com.example.app";
    // The public API validates the expected marker digest before handoff. The
    // fixture receives it through the environment so its process image remains
    // byte-for-byte identical to the policy-bound executable.
    const char* expected = std::getenv("DESKTOP_UPDATER_TEST_PROVENANCE_SHA256");
    if (expected == nullptr) throw std::runtime_error("missing provenance digest");
    request.expected_provenance_sha256 = expected;
    request.expected_artifact_sha256 =
        desktop_updater::helper::Sha256LinuxFile(
            std::filesystem::path(stage) / ".desktop_updater_artifact.zip");

    desktop_updater::native::InstallReservation reservation;
    const auto prepared =
        desktop_updater::native::PrepareInstall(request, &reservation);
    if (!prepared.ok) {
      result << "prepare-error\n" << prepared.error << '\n';
      return 2;
    }
    const auto committed =
        desktop_updater::native::CommitAfterExit(reservation);
    result << "state\n" << static_cast<unsigned int>(committed.state) << '\n'
           << "code\n" << static_cast<unsigned int>(committed.result_code)
           << '\n' << "transaction\n" << reservation.transaction_id << '\n'
           << "detail\n" << committed.detail << '\n';
    return committed.state ==
                   desktop_updater::native::InstallTransactionState::kCommitAccepted
               ? 0
               : 3;
  } catch (const std::exception& error) {
    result << "exception\n" << error.what() << '\n';
    return 4;
  }
}
