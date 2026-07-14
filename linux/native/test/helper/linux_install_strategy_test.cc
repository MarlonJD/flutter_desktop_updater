#include <gtest/gtest.h>

#include <sys/stat.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "install_strategy.h"

namespace desktop_updater::helper {
namespace {

LinuxVerifiedPayloadIdentity Payload(const std::string& version) {
  const char fill = version == "new" ? 'b' : 'a';
  return {"com.example.app",
          "release-key",
          std::string(64, fill),
          std::string(64, 'c'),
          std::string(64, 'd'),
          "Example.AppImage",
          std::string(64, 'e'),
          static_cast<std::uint32_t>(S_IFREG | 0755),
          static_cast<std::uint32_t>(geteuid()),
          static_cast<std::uint32_t>(getegid())};
}

class FileVerifier final : public LinuxInstallPayloadVerifier {
 public:
  LinuxVerifiedPayloadIdentity Verify(int parent,
                                      const std::string& leaf) override {
    return Payload(ReadLinuxRelativeUtf8(parent, leaf, 32));
  }
};

class RecordingRunner final : public LinuxProviderRunner {
 public:
  std::string StartFixed(const LinuxProviderCommand& value) override {
    command = value;
    return transaction_identity;
  }

  LinuxProviderTransactionState QueryInstalledState(
      const std::string& provider,
      const std::string& transaction,
      const std::string& package_id,
      const std::string& expected) override {
    query = {provider, {transaction, package_id, expected}};
    return query_state;
  }

  LinuxProviderCommand command;
  LinuxProviderCommand query;
  std::string transaction_identity = "provider-42";
  LinuxProviderTransactionState query_state =
      LinuxProviderTransactionState::kCompleted;
};

TEST(LinuxInstallStrategy, SelectsOnlyExactPolicyAndProtocolCapability) {
  const std::vector<LinuxStrategyCapability> policy = {
      {"singleFileReplace", "platformFile"},
      {"systemPackageTransaction", "apt"},
  };
  const std::vector<LinuxStrategyCapability> protocol = {
      {"singleFileReplace", "platformFile"},
      {"systemPackageTransaction", "apt"},
  };

  EXPECT_EQ((LinuxStrategyCapability{"systemPackageTransaction", "apt"}),
            SelectLinuxInstallStrategy(
                policy, protocol,
                {"systemPackageTransaction", "apt", true, false, {}, false,
                 false}));
  EXPECT_THROW(SelectLinuxInstallStrategy(
                   policy, protocol,
                   {"systemPackageTransaction", "dnf", true, false, {},
                    false, false}),
               LinuxInstallStrategyError);
  EXPECT_THROW(SelectLinuxInstallStrategy(
                   policy, protocol,
                   {"systemPackageTransaction", "platformFile", true, false,
                    {}, false, false}),
               LinuxInstallStrategyError);
}

TEST(LinuxInstallStrategy, RejectsRootAppImageWithoutBrokerAndCallerFlags) {
  const std::vector<LinuxStrategyCapability> policy = {
      {"singleFileReplace", "platformFile"}};
  const std::vector<LinuxStrategyCapability> protocol = {
      {"singleFileReplace", "platformFile"}};

  EXPECT_EQ((LinuxStrategyCapability{"singleFileReplace", "platformFile"}),
            SelectLinuxInstallStrategy(
                policy, protocol,
                {"singleFileReplace", "platformFile", false, false, {}, false,
                 false}));
  EXPECT_EQ((LinuxStrategyCapability{"singleFileReplace", "platformFile"}),
            SelectLinuxInstallStrategy(
                policy, protocol,
                {"singleFileReplace", "platformFile", true, true, {}, false,
                 false}));
  EXPECT_THROW(SelectLinuxInstallStrategy(
                   policy, protocol,
                   {"singleFileReplace", "platformFile", false, true, {},
                    false, false}),
               LinuxInstallStrategyError);
  EXPECT_THROW(SelectLinuxInstallStrategy(
                   policy, protocol,
                   {"singleFileReplace", "platformFile", true, true,
                    {"attacker"}, false, false}),
               LinuxInstallStrategyError);
}

TEST(LinuxInstallStrategy, SingleFileReplaceUsesLinuxFileTransaction) {
  const auto root = std::filesystem::temp_directory_path() /
                    ("desktop-updater-strategy-" + std::to_string(getpid()));
  const auto target = root / "Example.AppImage";
  const auto stage = root / "Stage.AppImage";
  std::filesystem::create_directories(root);
  std::ofstream(target, std::ios::binary) << "old";
  std::ofstream(stage, std::ios::binary) << "new";
  chmod(target.c_str(), 0755);
  chmod(stage.c_str(), 0755);
  FileVerifier verifier;

  EXPECT_EQ(LinuxFileTransactionResult::kCompleted,
            ExecuteLinuxSingleFileReplace(
                {target,
                 stage,
                 "00000000-0000-4000-8000-000000000011",
                 getpid(),
                 Payload("new"),
                 "x86_64",
                 "x86_64",
                 false,
                 false},
                verifier));
  EXPECT_EQ("new", ReadLinuxRelativeUtf8(
                       OpenLinuxDirectory(root.string()).get(),
                       "Example.AppImage", 32));
  std::filesystem::remove_all(root);
}

TEST(LinuxInstallStrategy, BuildsOnlyFixedAptAndDnfCommands) {
  RecordingRunner runner;
  LinuxSystemPackageRequest apt{"apt",
                                "example-app",
                                "2.0.0",
                                "amd64",
                                "https://packages.example.test stable",
                                std::string(64, 'a'),
                                {}};

  const auto transaction = StartLinuxSystemPackageTransaction(apt, runner);
  EXPECT_EQ("/usr/bin/apt-get", runner.command.executable);
  EXPECT_EQ((std::vector<std::string>{"install", "--yes", "--only-upgrade",
                                      "example-app=2.0.0"}),
            runner.command.arguments);
  EXPECT_EQ(LinuxProviderTransactionState::kManagerStarted,
            transaction.state);

  apt.caller_arguments = {"--allow-unauthenticated"};
  EXPECT_THROW(BuildLinuxSystemPackageCommand(apt),
               LinuxInstallStrategyError);

  const LinuxSystemPackageRequest dnf{
      "dnf", "example-app", "2.0.0", "x86_64", "signed-repository",
      std::string(64, 'b'), {}};
  EXPECT_EQ("/usr/bin/dnf", BuildLinuxSystemPackageCommand(dnf).executable);
}

TEST(LinuxInstallStrategy, ExternalRefreshRejectsDangerousAndDirectMutation) {
  RecordingRunner runner;
  LinuxExternalRefreshRequest flatpak{"flatpak",
                                      "com.example.App",
                                      "stable",
                                      "flathub",
                                      "commit-42",
                                      false,
                                      false,
                                      false,
                                      false,
                                      {}};
  auto transaction = StartLinuxExternalManagedRefresh(flatpak, runner);
  EXPECT_EQ("/usr/bin/flatpak", runner.command.executable);
  EXPECT_EQ("provider-42", transaction.transaction_identity);
  transaction = RecoverLinuxExternalManagedRefresh(
      transaction, "commit-42", runner);
  EXPECT_EQ(LinuxProviderTransactionState::kCompleted, transaction.state);

  LinuxExternalRefreshRequest snap{"snap",
                                   "example-app",
                                   "latest/stable",
                                   "brand-store",
                                   "revision-42",
                                   false,
                                   true,
                                   true,
                                   false,
                                   {}};
  EXPECT_THROW(BuildLinuxExternalRefreshCommand(snap),
               LinuxInstallStrategyError);
  snap.dangerous_sideload = false;
  snap.direct_revision_mutation = true;
  EXPECT_THROW(BuildLinuxExternalRefreshCommand(snap),
               LinuxInstallStrategyError);
  snap.direct_revision_mutation = false;
  EXPECT_EQ("/usr/bin/snap",
            BuildLinuxExternalRefreshCommand(snap).executable);
}

}  // namespace
}  // namespace desktop_updater::helper
