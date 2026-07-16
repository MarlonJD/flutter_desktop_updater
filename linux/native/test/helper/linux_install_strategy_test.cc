#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <sys/stat.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "install_strategy.h"
#include "unix_socket_transport.h"

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

  LinuxProviderStateObservation QueryInstalledState(
      const LinuxProviderTransaction& transaction,
      const std::string& expected) override {
    query_transaction = transaction;
    query_expected = expected;
    return {query_state,
            query_identity.empty() ? transaction.transaction_identity
                                   : query_identity};
  }

  LinuxProviderCommand command;
  LinuxProviderTransaction query_transaction;
  std::string query_expected;
  std::string transaction_identity = "provider-42";
  std::string query_identity;
  LinuxProviderTransactionState query_state =
      LinuxProviderTransactionState::kCompleted;
};

class ScriptedProviderExecutor final : public LinuxProviderProcessExecutor {
 public:
  LinuxProviderProcessResult Run(
      const std::string& executable,
      const std::vector<std::string>& arguments) override {
    commands.push_back({executable, arguments});
    if (results.empty()) {
      throw LinuxInstallStrategyError("unexpected provider process");
    }
    LinuxProviderProcessResult result = results.front();
    results.erase(results.begin());
    return result;
  }

  std::vector<LinuxProviderCommand> commands;
  std::vector<LinuxProviderProcessResult> results;
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
                                std::string(64, 'c'),
                                std::string(64, 'a'),
                                {}};
  apt.source_artifact_path =
      "/var/lib/desktop-updater/artifacts/example-app_2.0.0_amd64.deb";

  const auto transaction = StartLinuxSystemPackageTransaction(apt, runner);
  EXPECT_EQ("/usr/bin/apt-get", runner.command.executable);
  EXPECT_EQ((std::vector<std::string>{
                "-o",
                "Dir::Etc::sourcelist=/etc/desktop-updater/repositories/" +
                    std::string(64, 'c') + ".sources",
                "-o", "Dir::Etc::sourceparts=-", "install", "--yes",
                "--only-upgrade", "--",
                "/var/lib/desktop-updater/artifacts/"
                "example-app_2.0.0_amd64.deb"}),
            runner.command.arguments);
  EXPECT_EQ(apt.repository_identity,
            runner.command.repository_or_remote_identity);
  EXPECT_EQ(apt.source_artifact_sha256,
            runner.command.source_artifact_sha256);
  EXPECT_EQ(LinuxProviderTransactionState::kManagerStarted,
            transaction.state);

  apt.caller_arguments = {"--allow-unauthenticated"};
  EXPECT_THROW(BuildLinuxSystemPackageCommand(apt),
               LinuxInstallStrategyError);

  const LinuxSystemPackageRequest dnf{
      "dnf", "example-app", "2.0.0", "x86_64", std::string(64, 'd'),
      std::string(64, 'b'), {},
      "/var/lib/desktop-updater/artifacts/example-app-2.0.0.x86_64.rpm"};
  const auto dnf_command = BuildLinuxSystemPackageCommand(dnf);
  EXPECT_EQ("/usr/bin/dnf", dnf_command.executable);
  EXPECT_THAT(dnf_command.arguments,
              testing::Contains("--enablerepo=desktop-updater-" +
                                std::string(64, 'd')));
  EXPECT_THAT(dnf_command.arguments,
              testing::Contains(dnf.source_artifact_path));

  apt.repository_identity = "https://attacker.invalid stable";
  EXPECT_THROW(BuildLinuxSystemPackageCommand(apt),
               LinuxInstallStrategyError);
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
  EXPECT_THAT(runner.command.arguments,
              testing::Contains("flathub:com.example.App//stable"));
  EXPECT_EQ("flathub", runner.command.repository_or_remote_identity);
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

TEST(LinuxInstallStrategy,
     ProductionRunnerUsesNoShellAndQueriesProviderStateAfterInterruption) {
  const auto root = std::filesystem::temp_directory_path() /
                    ("desktop-updater-provider-runner-" +
                     std::to_string(getpid()));
  std::filesystem::create_directories(root);
  const auto artifact = root / "example-app_2.0.0_amd64.deb";
  std::ofstream(artifact, std::ios::binary) << "verified package bytes";
  const auto repositories = root / "repositories";
  const auto journal_root = root / "journal";
  std::filesystem::create_directories(repositories);
  std::filesystem::create_directories(journal_root);
  chmod(root.c_str(), 0700);
  chmod(repositories.c_str(), 0700);
  chmod(journal_root.c_str(), 0700);
  chmod(artifact.c_str(), 0600);
  const std::string repository_contents = "sealed apt source configuration";
  const std::string repository_identity =
      Sha256LinuxBytes(repository_contents);
  const auto repository = repositories / (repository_identity + ".sources");
  std::ofstream(repository, std::ios::binary) << repository_contents;
  chmod(repository.c_str(), 0600);
  ASSERT_EQ(setenv("DESKTOP_UPDATER_TEST_REPOSITORY_ROOT",
                   repositories.c_str(), 1),
            0);

  ScriptedProviderExecutor executor;
  executor.results = {
      {0, "example-app\n2.0.0\namd64\n", "metadata-check"},
      {0, "", "process-local-id-must-not-escape"},
      {0, "ii \n2.0.0\namd64\n", "installed-state-query"},
  };
  LinuxFixedProviderRunner runner(executor);
  LinuxSystemPackageRequest request{
      "apt", "example-app", "2.0.0", "amd64", repository_identity,
      Sha256LinuxFile(artifact), {}, artifact};
  LinuxProviderJournal journal(journal_root, geteuid(), getegid());
  const std::string transaction_id =
      "00000000-0000-4000-8000-000000000043";
  const auto transaction = StartDurableLinuxSystemPackageTransaction(
      transaction_id, request, runner, journal);

  EXPECT_THAT(transaction.transaction_identity,
              testing::StartsWith("apt-state-"));
  ASSERT_EQ(3u, executor.commands.size());
  EXPECT_EQ("/usr/bin/dpkg-deb", executor.commands[0].executable);
  EXPECT_EQ("/usr/bin/apt-get", executor.commands[1].executable);
  EXPECT_EQ("/usr/bin/dpkg-query", executor.commands[2].executable);
  for (const auto& command : executor.commands) {
    EXPECT_NE("/bin/sh", command.executable);
    EXPECT_NE("/bin/bash", command.executable);
  }
  ScriptedProviderExecutor recovery_executor;
  recovery_executor.results = {
      {0, "ii \n2.0.0\namd64\n", "recovery-state-query"}};
  LinuxFixedProviderRunner recovery_runner(recovery_executor);
  LinuxProviderJournal restarted_journal(journal_root, geteuid(), getegid());
  EXPECT_EQ(LinuxProviderTransactionState::kCompleted,
            RecoverDurableLinuxSystemPackageTransaction(
                transaction_id, recovery_runner, restarted_journal).state);
  ASSERT_EQ(1u, recovery_executor.commands.size());
  EXPECT_EQ("/usr/bin/dpkg-query",
            recovery_executor.commands.back().executable);
  const auto recovered_record = restarted_journal.Load(transaction_id);
  ASSERT_TRUE(recovered_record.has_value());
  EXPECT_EQ(LinuxProviderTransactionState::kCompleted,
            recovered_record->transaction.state);

  unsetenv("DESKTOP_UPDATER_TEST_REPOSITORY_ROOT");
  std::filesystem::remove_all(root);
}

TEST(LinuxInstallStrategy,
     DurableRecoveryFromPreparedStatePersistsNormativeIntermediateState) {
  const auto root = std::filesystem::temp_directory_path() /
                    ("desktop-updater-provider-prepared-recovery-" +
                     std::to_string(getpid()));
  std::filesystem::create_directories(root);
  chmod(root.c_str(), 0700);
  LinuxProviderJournal journal(root, geteuid(), getegid());
  LinuxProviderJournalRecord record;
  record.transaction_id = "00000000-0000-4000-8000-000000000048";
  record.transaction = {
      "apt", "example-app", "pending-" + std::string(64, 'a'),
      LinuxProviderTransactionState::kPrepared};
  record.expected_version_or_revision = "2.0.0";
  record.command_sha256 = std::string(64, 'a');
  journal.Persist(record);

  RecordingRunner runner;
  runner.query_state = LinuxProviderTransactionState::kCompleted;
  const auto recovered = RecoverDurableLinuxSystemPackageTransaction(
      record.transaction_id, runner, journal);

  EXPECT_EQ(LinuxProviderTransactionState::kCompleted, recovered.state);
  const auto reloaded = journal.Load(record.transaction_id);
  ASSERT_TRUE(reloaded.has_value());
  EXPECT_EQ(LinuxProviderTransactionState::kCompleted,
            reloaded->transaction.state);
  std::filesystem::remove_all(root);
}

TEST(LinuxInstallStrategy,
     ProductionRunnerBindsFlatpakRemoteAndSnapStoreState) {
  ScriptedProviderExecutor flatpak_executor;
  flatpak_executor.results = {
      {0, "commit-42\n", "remote-preflight"},
      {0, "", "process-local-id"},
      {0, "flathub\n", "origin-query"},
      {0, "commit-42\n", "commit-query"},
  };
  LinuxFixedProviderRunner flatpak_runner(flatpak_executor);
  const LinuxProviderCommand flatpak = BuildLinuxExternalRefreshCommand(
      {"flatpak", "com.example.App", "stable", "flathub", "commit-42",
       true, false, false, false, {}});
  const std::string flatpak_identity = flatpak_runner.StartFixed(flatpak);
  EXPECT_THAT(flatpak_identity, testing::StartsWith("flatpak-state-"));
  ASSERT_EQ(4u, flatpak_executor.commands.size());
  EXPECT_EQ((std::vector<std::string>{
                "info", "--show-origin", "com.example.App//stable"}),
            flatpak_executor.commands[2].arguments);
  EXPECT_EQ((std::vector<std::string>{
                "info", "--show-commit", "com.example.App//stable"}),
            flatpak_executor.commands[3].arguments);

  ScriptedProviderExecutor snap_executor;
  snap_executor.results = {
      {0, "channels:\n  latest/stable: 2.0 (42)\n", "store-preflight"},
      {0, "", "process-local-id"},
      {0, "type: model\nstore: brand-store\n", "model-assertion"},
      {0, "tracking: latest/stable\ninstalled: 2.0 (42) 10MB -\n",
       "installed-query"},
  };
  LinuxFixedProviderRunner snap_runner(snap_executor);
  const LinuxProviderCommand snap = BuildLinuxExternalRefreshCommand(
      {"snap", "example-app", "latest/stable", "brand-store", "42",
       false, true, false, false, {}});
  const std::string snap_identity = snap_runner.StartFixed(snap);
  EXPECT_THAT(snap_identity, testing::StartsWith("snap-state-"));
  ASSERT_EQ(4u, snap_executor.commands.size());
  EXPECT_EQ((std::vector<std::string>{"model", "--assertion"}),
            snap_executor.commands[2].arguments);
  EXPECT_EQ((std::vector<std::string>{"info", "example-app"}),
            snap_executor.commands[3].arguments);
}

TEST(LinuxInstallStrategy,
     DurableProviderJournalReloadsIdentityAndRejectsTamperAndSymlink) {
  const auto root = std::filesystem::temp_directory_path() /
                    ("desktop-updater-provider-journal-" +
                     std::to_string(getpid()));
  std::filesystem::create_directories(root);
  chmod(root.c_str(), 0700);
  LinuxProviderJournal journal(root, geteuid(), getegid());
  LinuxProviderJournalRecord record;
  record.transaction_id = "00000000-0000-4000-8000-000000000044";
  record.transaction = {"apt", "example-app", "apt-history-42",
                        LinuxProviderTransactionState::kManagerStarted};
  record.expected_version_or_revision = "2.0.0";
  record.command_sha256 = std::string(64, 'a');
  journal.Persist(record);

  const auto loaded = LinuxProviderJournal(root, geteuid(), getegid())
                          .Load(record.transaction_id);
  ASSERT_TRUE(loaded.has_value());
  EXPECT_EQ(record.transaction.transaction_identity,
            loaded->transaction.transaction_identity);
  EXPECT_EQ(record.expected_version_or_revision,
            loaded->expected_version_or_revision);

  const auto journal_path =
      root / (record.transaction_id + ".provider.json");
  std::ofstream(journal_path, std::ios::binary | std::ios::trunc)
      << "{\"schemaVersion\":1}";
  chmod(journal_path.c_str(), 0600);
  EXPECT_THROW(journal.Load(record.transaction_id),
               LinuxProviderJournalError);
  std::filesystem::remove(journal_path);
  ASSERT_EQ(symlink("missing", journal_path.c_str()), 0);
  EXPECT_THROW(journal.Load(record.transaction_id),
               LinuxProviderJournalError);
  std::filesystem::remove(journal_path);
  journal.Persist(record);
  chmod(journal_path.c_str(), 0644);
  EXPECT_THROW(journal.Load(record.transaction_id),
               LinuxProviderJournalError);

  std::filesystem::remove_all(root);
}

TEST(LinuxInstallStrategy, PosixExecutorPreservesMetacharactersAsLiteralArgv) {
  const auto root = std::filesystem::temp_directory_path() /
                    ("desktop-updater-provider-argv-" +
                     std::to_string(getpid()));
  std::filesystem::create_directories(root);
  const auto injected = root / "shell-expanded";
  const std::string literal = "literal;touch " + injected.string();
  PosixLinuxProviderProcessExecutor executor;

  const auto result = executor.Run("/usr/bin/printf", {"%s", literal});

  EXPECT_EQ(0, result.exit_code);
  EXPECT_EQ(literal, result.standard_output);
  EXPECT_FALSE(std::filesystem::exists(injected));
  EXPECT_TRUE(result.transaction_identity.empty());
  std::filesystem::remove_all(root);
}

TEST(LinuxInstallStrategy, FixedRunnerRejectsShellAndMutatedTemplates) {
  ScriptedProviderExecutor executor;
  LinuxFixedProviderRunner runner(executor);
  LinuxProviderCommand shell;
  shell.executable = "/bin/sh";
  shell.arguments = {"-c", "touch /tmp/provider-injection"};
  shell.provider = "apt";
  shell.package_id = "example-app";
  shell.expected_version_or_revision = "2.0.0";
  shell.expected_architecture = "amd64";
  shell.repository_or_remote_identity = std::string(64, 'a');
  shell.source_artifact_path = "/var/lib/desktop-updater/artifacts/app.deb";
  shell.source_artifact_sha256 = std::string(64, 'b');

  EXPECT_THROW(runner.StartFixed(shell), LinuxInstallStrategyError);
  EXPECT_TRUE(executor.commands.empty());
}

TEST(LinuxInstallStrategy, ExternalProviderIdentitySurvivesJournalReload) {
  const auto root = std::filesystem::temp_directory_path() /
                    ("desktop-updater-external-provider-" +
                     std::to_string(getpid()));
  std::filesystem::create_directories(root);
  chmod(root.c_str(), 0700);
  LinuxProviderJournal journal(root, geteuid(), getegid());
  RecordingRunner runner;
  LinuxExternalRefreshRequest request{
      "flatpak", "com.example.App", "stable", "flathub", "commit-42",
      false, false, false, false, {}};
  const std::string transaction_id =
      "00000000-0000-4000-8000-000000000045";

  const auto started = StartDurableLinuxExternalManagedRefresh(
      transaction_id, request, runner, journal);
  EXPECT_EQ("provider-42", started.transaction_identity);
  LinuxProviderJournal restarted(root, geteuid(), getegid());
  RecordingRunner recovery_runner;
  recovery_runner.query_state = LinuxProviderTransactionState::kCompleted;
  const auto recovered = RecoverDurableLinuxExternalManagedRefresh(
      transaction_id, recovery_runner, restarted);

  EXPECT_EQ(LinuxProviderTransactionState::kCompleted, recovered.state);
  EXPECT_EQ("flatpak", recovery_runner.query_transaction.provider);
  EXPECT_EQ("provider-42",
            recovery_runner.query_transaction.transaction_identity);
  EXPECT_EQ("com.example.App",
            recovery_runner.query_transaction.package_id);
  EXPECT_EQ("stable", recovery_runner.query_transaction.provider_scope);
  EXPECT_EQ("flathub",
            recovery_runner.query_transaction.provider_authority);
  EXPECT_EQ("commit-42", recovery_runner.query_expected);
  std::filesystem::remove_all(root);
}

}  // namespace
}  // namespace desktop_updater::helper
