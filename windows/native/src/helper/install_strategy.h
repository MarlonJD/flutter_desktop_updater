#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_STRATEGY_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_STRATEGY_H_

#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

#include "windows_file_transaction.h"

namespace desktop_updater::helper {

struct WindowsStrategyCapability {
  std::string strategy;
  std::string provider;

  bool operator==(const WindowsStrategyCapability& other) const {
    return strategy == other.strategy && provider == other.provider;
  }
};

struct WindowsStrategyRequest {
  std::string strategy;
  std::string provider;
  std::vector<std::wstring> caller_arguments;
  bool direct_revision_mutation = false;
  bool dangerous_sideload = false;
};

class WindowsInstallStrategyError : public std::runtime_error {
 public:
  explicit WindowsInstallStrategyError(const std::string& detail)
      : std::runtime_error(detail) {}
};

WindowsStrategyCapability SelectWindowsInstallStrategy(
    const std::vector<WindowsStrategyCapability>& policy_capabilities,
    const std::vector<WindowsStrategyCapability>& protocol_capabilities,
    const WindowsStrategyRequest& request);

WindowsFileTransactionResult ExecuteWindowsDirectoryReplace(
    WindowsFileTransaction& transaction);

struct WindowsInstallerExpectation {
  std::filesystem::path installer_path;
  std::wstring authenticode_publisher;
  std::string installer_sha256;
  std::string package_id;
  std::string expected_version;
  std::filesystem::path installed_executable_path;
  std::string installed_executable_sha256;
};

class WindowsInstallerVerifier {
 public:
  virtual ~WindowsInstallerVerifier() = default;
  virtual void VerifyInstaller(
      const WindowsInstallerExpectation& expectation) = 0;
  virtual void VerifyInstalledPackage(
      const WindowsInstallerExpectation& expectation) = 0;
};

class AuthenticodeWindowsInstallerVerifier final
    : public WindowsInstallerVerifier {
 public:
  void VerifyInstaller(
      const WindowsInstallerExpectation& expectation) override;
  void VerifyInstalledPackage(
      const WindowsInstallerExpectation& expectation) override;
};

class WindowsFixedInstallerRunner {
 public:
  virtual ~WindowsFixedInstallerRunner() = default;
  virtual std::string Launch(
      const std::filesystem::path& verified_installer,
      const std::vector<std::wstring>& fixed_arguments) = 0;
};

class CreateProcessWindowsInstallerRunner final
    : public WindowsFixedInstallerRunner {
 public:
  std::string Launch(
      const std::filesystem::path& verified_installer,
      const std::vector<std::wstring>& fixed_arguments) override;
};

struct WindowsInstallerTransaction {
  std::string transaction_identity;
  bool completed = false;
};

std::vector<std::wstring> FixedWindowsInnoArguments();
WindowsInstallerTransaction ExecuteVerifiedWindowsInstallerHandoff(
    const WindowsInstallerExpectation& expectation,
    WindowsInstallerVerifier& verifier,
    WindowsFixedInstallerRunner& runner);
WindowsInstallerTransaction RecoverVerifiedWindowsInstallerHandoff(
    const WindowsInstallerExpectation& expectation,
    const std::string& transaction_identity,
    WindowsInstallerVerifier& verifier);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_STRATEGY_H_
