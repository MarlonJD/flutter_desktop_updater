#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "install_strategy.h"

namespace desktop_updater::helper {
namespace {

class RecordingVerifier final : public WindowsInstallerVerifier {
 public:
  void VerifyInstaller(const WindowsInstallerExpectation& value) override {
    installer = value.installer_path;
  }
  void VerifyInstalledPackage(
      const WindowsInstallerExpectation& value) override {
    installed = value.installed_executable_path;
  }

  std::filesystem::path installer;
  std::filesystem::path installed;
};

class RecordingRunner final : public WindowsFixedInstallerRunner {
 public:
  std::string Launch(
      const std::filesystem::path& installer,
      const std::vector<std::wstring>& arguments) override {
    path = installer;
    args = arguments;
    return "inno-process:42";
  }

  std::filesystem::path path;
  std::vector<std::wstring> args;
};

TEST(WindowsInstallStrategy, RequiresExactPolicyAndProtocolPair) {
  const std::vector<WindowsStrategyCapability> policy = {
      {"directoryReplace", "platformDirectory"},
      {"verifiedInstallerHandoff", "windowsInno"},
  };
  const std::vector<WindowsStrategyCapability> protocol = {
      {"directoryReplace", "platformDirectory"},
      {"verifiedInstallerHandoff", "windowsInno"},
  };

  EXPECT_EQ((WindowsStrategyCapability{"verifiedInstallerHandoff",
                                       "windowsInno"}),
            SelectWindowsInstallStrategy(
                policy, protocol,
                {"verifiedInstallerHandoff", "windowsInno", {}, false,
                 false}));
  EXPECT_THROW(SelectWindowsInstallStrategy(
                   policy, protocol,
                   {"verifiedInstallerHandoff", "macosInstaller", {}, false,
                    false}),
               WindowsInstallStrategyError);
  EXPECT_THROW(SelectWindowsInstallStrategy(
                   policy, protocol,
                   {"directoryReplace", "platformDirectory", {L"attacker"},
                    false, false}),
               WindowsInstallStrategyError);
}

TEST(WindowsInstallStrategy, HandoffUsesFixedArgumentsAndPostVerification) {
  const WindowsInstallerExpectation expectation{
      L"C:\\sealed\\setup.exe",
      L"Example Software LLC",
      std::string(64, 'a'),
      "com.example.app",
      "2.0.0",
      L"C:\\Program Files\\Example\\example.exe",
      std::string(64, 'b'),
  };
  RecordingVerifier verifier;
  RecordingRunner runner;

  const auto result = ExecuteVerifiedWindowsInstallerHandoff(
      expectation, verifier, runner);

  EXPECT_TRUE(result.completed);
  EXPECT_EQ("inno-process:42", result.transaction_identity);
  EXPECT_EQ(expectation.installer_path, verifier.installer);
  EXPECT_EQ(expectation.installed_executable_path, verifier.installed);
  EXPECT_EQ(FixedWindowsInnoArguments(), runner.args);
  EXPECT_TRUE(RecoverVerifiedWindowsInstallerHandoff(
                  expectation, result.transaction_identity, verifier)
                  .completed);
}

}  // namespace
}  // namespace desktop_updater::helper
