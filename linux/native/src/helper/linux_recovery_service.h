#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_RECOVERY_SERVICE_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_RECOVERY_SERVICE_H_

#include <filesystem>
#include <string>

#include "linux_file_transaction.h"

namespace desktop_updater::helper {

enum class LinuxRecoveryOutcome {
  kNothingToRecover,
  kLiveOwner,
  kRecovered,
  kManualActionRequired,
};

class LinuxProcessLivenessChecker {
 public:
  virtual ~LinuxProcessLivenessChecker() = default;
  virtual bool IsSameProcessAlive(
      pid_t process_id,
      std::uint64_t process_start_identity) = 0;
};

class PidfdLinuxProcessLivenessChecker final
    : public LinuxProcessLivenessChecker {
 public:
  bool IsSameProcessAlive(pid_t process_id,
                          std::uint64_t process_start_identity) override;
};

class LinuxRecoveryService {
 public:
  LinuxRecoveryService(
      const std::filesystem::path& target_path,
      std::string transaction_id,
      LinuxVerifiedPayloadIdentity expected_payload_identity,
      LinuxInstallPayloadVerifier& verifier,
      LinuxProcessLivenessChecker& liveness_checker);

  LinuxRecoveryOutcome Recover();

 private:
  std::filesystem::path parent_locator_;
  LinuxTransactionPaths paths_;
  LinuxVerifiedPayloadIdentity expected_payload_identity_;
  LinuxInstallPayloadVerifier& verifier_;
  LinuxProcessLivenessChecker& liveness_checker_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_RECOVERY_SERVICE_H_
