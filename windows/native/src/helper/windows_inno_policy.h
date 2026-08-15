#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_POLICY_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_POLICY_H_

#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

#include "release_contract.h"

namespace desktop_updater::helper {

class WindowsInnoPolicyError : public std::runtime_error {
 public:
  explicit WindowsInnoPolicyError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct ProtectedWindowsInnoExecutionPolicy {
  std::vector<std::wstring> silent_arguments;
  bool inherit_install_directory = false;
  bool relaunch_after_install = false;
  std::filesystem::path installed_executable_relative_path;
  std::string installed_executable_sha256;
  std::wstring log_file_name;
  std::vector<std::string> signer_certificate_sha256;
};

struct ProtectedWindowsInnoExpectation {
  std::filesystem::path installer_path;
  std::string installer_sha256;
  std::string package_id;
  std::string expected_version;
  std::int64_t expected_build_number = 0;
  std::filesystem::path install_root;
  std::filesystem::path log_root;
  ProtectedWindowsInnoExecutionPolicy execution;
};

class ProtectedWindowsInnoVerifier {
 public:
  virtual ~ProtectedWindowsInnoVerifier() = default;
  virtual void VerifyInstaller(
      const ProtectedWindowsInnoExpectation& expectation) = 0;
  virtual void VerifyInstalledPackage(
      const ProtectedWindowsInnoExpectation& expectation) = 0;
};

class AuthenticodeProtectedWindowsInnoVerifier final
    : public ProtectedWindowsInnoVerifier {
 public:
  void VerifyInstaller(
      const ProtectedWindowsInnoExpectation& expectation) override;
  void VerifyInstalledPackage(
      const ProtectedWindowsInnoExpectation& expectation) override;
};

class ProtectedWindowsInnoRunner {
 public:
  virtual ~ProtectedWindowsInnoRunner() = default;
  virtual std::string Launch(
      const ProtectedWindowsInnoExpectation& expectation) = 0;
};

class CreateProcessProtectedWindowsInnoRunner final
    : public ProtectedWindowsInnoRunner {
 public:
  std::string Launch(
      const ProtectedWindowsInnoExpectation& expectation) override;
};

struct ProtectedWindowsInnoTransactionResult {
  std::string provider_transaction_identity;
  bool completed = false;
};

// Converts only the security-relevant, signed descriptor fields into the
// elevated helper contract. This protected path never accepts a portable or
// no-elevation descriptor, an unsigned installer, or arbitrary switches.
ProtectedWindowsInnoExecutionPolicy ParseProtectedWindowsInnoExecutionPolicy(
    const desktop_updater::runtime::internal::ReleaseDescriptor& descriptor);

std::vector<std::wstring> BuildProtectedWindowsInnoArguments(
    const ProtectedWindowsInnoExecutionPolicy& policy,
    const std::filesystem::path& install_root,
    const std::filesystem::path& log_root);

ProtectedWindowsInnoTransactionResult ExecuteProtectedWindowsInnoHandoff(
    const ProtectedWindowsInnoExpectation& expectation,
    ProtectedWindowsInnoVerifier& verifier,
    ProtectedWindowsInnoRunner& runner);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_POLICY_H_
