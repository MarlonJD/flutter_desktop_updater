#include <gtest/gtest.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "linux_transaction_registry.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

namespace fs = std::filesystem;

class RegistryFixture {
 public:
  RegistryFixture() {
    std::string pattern =
        "/tmp/desktop-updater-registry-test-" + std::to_string(getpid()) +
        "-XXXXXX";
    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    char* created = mkdtemp(writable.data());
    if (created == nullptr) throw std::runtime_error("mkdtemp failed");
    root = created;
    if (chmod(root.c_str(), 0700) != 0) {
      throw std::runtime_error("chmod failed");
    }
    const char* old = std::getenv("XDG_STATE_HOME");
    had_old_state = old != nullptr;
    old_state = old == nullptr ? "" : old;
    if (setenv("XDG_STATE_HOME", root.c_str(), 1) != 0) {
      throw std::runtime_error("setenv failed");
    }
  }

  ~RegistryFixture() {
    if (had_old_state) {
      (void)setenv("XDG_STATE_HOME", old_state.c_str(), 1);
    } else {
      (void)unsetenv("XDG_STATE_HOME");
    }
    std::error_code ignored;
    fs::remove_all(root, ignored);
  }

  LinuxTransactionRegistryRecord Record() const {
    LinuxTransactionRegistryRecord record;
    record.transaction_id = "00000000-0000-4000-8000-000000000071";
    record.package_id = "com.example.app";
    record.policy_id = "com.example.policy";
    record.helper_endpoint_identity_sha256 = std::string(64, '1');
    record.recovery_authority_kind = "retainedPortable";
    record.recovery_policy_identity_sha256 = std::string(64, '7');
    record.recovery_authority_generation_sha256 =
        LinuxRecoveryAuthorityGenerationSha256(
            record.transaction_id, record.recovery_authority_kind,
            record.helper_endpoint_identity_sha256,
            record.recovery_policy_identity_sha256);
    record.target_path = (root / "Example.AppDir").string();
    record.canonical_request = "{}";
    record.state = "prepared";
    record.result_code = "recoveryRequired";
    record.journal_sha256 = std::string(64, '0');
    record.expected_payload_identity = {
        "com.example.app", "stable-2026", std::string(64, '2'),
        std::string(64, '3'), std::string(64, '4'), "bin/example",
        std::string(64, '5'), 0100755,
        static_cast<std::uint32_t>(geteuid()),
        static_cast<std::uint32_t>(getegid())};
    return record;
  }

  fs::path Transactions() const {
    return root / "desktop-updater" / "transactions";
  }

  fs::path root;
  bool had_old_state = false;
  std::string old_state;
};

class ExitAtRegistryFault final
    : public LinuxTransactionRegistryFaultInjector {
 public:
  explicit ExitAtRegistryFault(LinuxTransactionRegistryFaultPoint selected)
      : selected_(selected) {}

  void OnLinuxTransactionRegistryFault(
      LinuxTransactionRegistryFaultPoint point) override {
    if (point == selected_) _exit(81);
  }

 private:
  LinuxTransactionRegistryFaultPoint selected_;
};

TEST(LinuxTransactionRegistry, PersistsAndLoadsExactPrivateRecord) {
  RegistryFixture fixture;
  LinuxTransactionRegistry registry(false);
  const auto record = fixture.Record();

  registry.Persist(record);
  const auto loaded = registry.Load(record.transaction_id);

  ASSERT_TRUE(loaded.has_value());
  EXPECT_EQ(record.EncodeCanonical(), loaded->EncodeCanonical());
  struct stat directory {};
  struct stat file {};
  ASSERT_EQ(0, lstat(fixture.Transactions().c_str(), &directory));
  ASSERT_EQ(0, lstat((fixture.Transactions() /
                      (record.transaction_id + ".json")).c_str(),
                     &file));
  EXPECT_EQ(0700, directory.st_mode & 07777);
  EXPECT_EQ(geteuid(), directory.st_uid);
  EXPECT_EQ(getegid(), directory.st_gid);
  EXPECT_EQ(0600, file.st_mode & 07777);
  EXPECT_EQ(1, file.st_nlink);
  EXPECT_EQ(geteuid(), file.st_uid);
  EXPECT_EQ(getegid(), file.st_gid);
}

TEST(LinuxTransactionRegistry,
     RetainsOnlyTheTransactionScopedHelperAndPolicyGeneration) {
  RegistryFixture fixture;
  LinuxTransactionRegistry registry(false);
  const fs::path helper_v1 = fixture.root / "helper-v1";
  const fs::path policy_v1 = fixture.root / "policy-v1.json";
  const fs::path arbitrary_v2 = fixture.root / "helper-v2";
  {
    std::ofstream helper(helper_v1, std::ios::binary | std::ios::trunc);
    helper << "helper-generation-one";
    std::ofstream policy(policy_v1, std::ios::binary | std::ios::trunc);
    policy << "{\"policy\":\"generation-one\"}";
    std::ofstream arbitrary(arbitrary_v2,
                            std::ios::binary | std::ios::trunc);
    arbitrary << "helper-generation-two";
  }
  ASSERT_EQ(0, chmod(helper_v1.c_str(), 0755));
  ASSERT_EQ(0, chmod(policy_v1.c_str(), 0600));
  ASSERT_EQ(0, chmod(arbitrary_v2.c_str(), 0755));

  auto record = fixture.Record();
  record.helper_endpoint_identity_sha256 = Sha256LinuxFile(helper_v1);
  record.recovery_policy_identity_sha256 = std::string(64, '8');
  EXPECT_THROW(
      registry.PreservePortableRecoveryAuthority(helper_v1, policy_v1,
                                                  &record),
      LinuxTransactionRegistryError);
  record.recovery_policy_identity_sha256.clear();
  record.recovery_authority_generation_sha256.clear();
  registry.PreservePortableRecoveryAuthority(helper_v1, policy_v1, &record);
  registry.Persist(record);

  const fs::path retained =
      registry.PortableRecoveryAuthorityHelperPath(record.transaction_id);
  EXPECT_NO_THROW(registry.VerifyRecoveryAuthority(record, retained));
  EXPECT_THROW(registry.VerifyRecoveryAuthority(record, arbitrary_v2),
               LinuxTransactionRegistryError);

  const fs::path retained_policy =
      retained.parent_path() / "desktop-updater-helper.policy.json";
  ASSERT_EQ(0, chmod(retained_policy.c_str(), 0600));
  {
    std::ofstream tampered(retained_policy,
                           std::ios::binary | std::ios::trunc);
    tampered << "{\"policy\":\"tampered\"}";
  }
  EXPECT_THROW(registry.VerifyRecoveryAuthority(record, retained),
               LinuxTransactionRegistryError);
}

TEST(LinuxTransactionRegistry, RejectsNonExactModeAndHardlinkedNext) {
  RegistryFixture fixture;
  LinuxTransactionRegistry registry(false);
  const auto record = fixture.Record();
  registry.Persist(record);
  const fs::path leaf =
      fixture.Transactions() / (record.transaction_id + ".json");

  ASSERT_EQ(0, chmod(leaf.c_str(), 0640));
  EXPECT_THROW(registry.Load(record.transaction_id),
               LinuxTransactionRegistryError);
  ASSERT_EQ(0, chmod(leaf.c_str(), 0600));

  const fs::path next = leaf.string() + ".next";
  ASSERT_EQ(0, link(leaf.c_str(), next.c_str()));
  EXPECT_THROW(registry.Persist(record), LinuxTransactionRegistryError);
  EXPECT_TRUE(fs::exists(leaf));
  EXPECT_TRUE(fs::exists(next));
}

TEST(LinuxTransactionRegistry, RejectsDirectoryModeAndReplacement) {
  RegistryFixture fixture;
  {
    LinuxTransactionRegistry registry(false);
    ASSERT_EQ(0, chmod(fixture.Transactions().c_str(), 0710));
    EXPECT_THROW(LinuxTransactionRegistry(false),
                 LinuxTransactionRegistryError);
    ASSERT_EQ(0, chmod(fixture.Transactions().c_str(), 0700));

    const fs::path moved = fixture.Transactions().string() + ".moved";
    ASSERT_EQ(0, rename(fixture.Transactions().c_str(), moved.c_str()));
    ASSERT_EQ(0, mkdir(fixture.Transactions().c_str(), 0700));
    EXPECT_THROW(registry.Load(fixture.Record().transaction_id),
                 LinuxTransactionRegistryError);
  }
}

TEST(LinuxTransactionRegistry,
     SecureDirectoryTreeRejectsSymlinkWritableAndNonPrivateComponents) {
  RegistryFixture fixture;
  const fs::path trusted = fixture.root / "trusted";
  ASSERT_EQ(0, mkdir(trusted.c_str(), 0700));
  auto root = OpenLinuxDirectory(fixture.root.string());

  auto opened = OpenSecureLinuxRegistryDirectoryTree(
      root.get(), {"trusted", "desktop-updater", "transactions"}, 1,
      geteuid(), getegid());
  EXPECT_TRUE(opened.valid());
  struct stat final_status {};
  ASSERT_EQ(0, fstat(opened.get(), &final_status));
  EXPECT_EQ(0700, final_status.st_mode & 07777);

  ASSERT_EQ(0, chmod(trusted.c_str(), 0720));
  EXPECT_THROW(OpenSecureLinuxRegistryDirectoryTree(
                   root.get(), {"trusted", "another"}, 1, geteuid(),
                   getegid()),
               LinuxTransactionRegistryError);
  ASSERT_EQ(0, chmod(trusted.c_str(), 0700));

  ASSERT_EQ(0, symlink(trusted.c_str(), (fixture.root / "linked").c_str()));
  EXPECT_THROW(OpenSecureLinuxRegistryDirectoryTree(
                   root.get(), {"linked", "private"}, 1, geteuid(),
                   getegid()),
               LinuxTransactionRegistryError);

  const fs::path non_private = trusted / "non-private";
  ASSERT_EQ(0, mkdir(non_private.c_str(), 0750));
  EXPECT_THROW(OpenSecureLinuxRegistryDirectoryTree(
                   root.get(), {"trusted", "non-private"}, 1, geteuid(),
                   getegid()),
               LinuxTransactionRegistryError);
}

TEST(LinuxTransactionRegistry, ReplacesOnlyStrictSingleLinkTornNext) {
  RegistryFixture fixture;
  LinuxTransactionRegistry registry(false);
  const auto record = fixture.Record();
  const fs::path next = fixture.Transactions() /
      (record.transaction_id + ".json.next");
  {
    std::ofstream output(next, std::ios::binary | std::ios::trunc);
    output << "partial";
  }
  ASSERT_EQ(0, chmod(next.c_str(), 0600));

  EXPECT_NO_THROW(registry.Persist(record));
  EXPECT_FALSE(fs::exists(next));
  ASSERT_TRUE(registry.Load(record.transaction_id).has_value());
}

TEST(LinuxTransactionRegistry,
     RejectsCanonicalButDivergentStateResultPairWithoutPromotion) {
  RegistryFixture fixture;
  LinuxTransactionRegistry registry(false);
  const auto current = fixture.Record();
  registry.Persist(current);

  auto completed = current;
  completed.state = "completed";
  completed.result_code = "completed";
  std::string divergent = completed.EncodeCanonical();
  const std::string expected = "\"resultCode\":\"completed\"";
  const std::size_t offset = divergent.find(expected);
  ASSERT_NE(std::string::npos, offset);
  divergent.replace(offset, expected.size(),
                    "\"resultCode\":\"rolledBack\"");
  const fs::path next = fixture.Transactions() /
      (current.transaction_id + ".json.next");
  {
    std::ofstream output(next, std::ios::binary | std::ios::trunc);
    output << divergent;
  }
  ASSERT_EQ(0, chmod(next.c_str(), 0600));

  const auto loaded = registry.Load(current.transaction_id);
  ASSERT_TRUE(loaded.has_value());
  EXPECT_EQ("prepared", loaded->state);
  EXPECT_EQ("recoveryRequired", loaded->result_code);
  EXPECT_FALSE(fs::exists(next));

  auto invalid = current;
  invalid.state = "completed";
  invalid.result_code = "rolledBack";
  EXPECT_THROW(invalid.EncodeCanonical(), LinuxTransactionRegistryError);
}

TEST(LinuxTransactionRegistry,
     ProcessDeathReconcilesPreparingCommitAndTerminalTransitions) {
  struct Transition {
    const char* from;
    const char* to;
    const char* from_result;
    const char* to_result;
    bool advances_journal;
  };
  for (const Transition transition : {
           Transition{"preparing", "prepared", "recoveryRequired",
                      "recoveryRequired", true},
           Transition{"prepared", "commitAccepted", "recoveryRequired",
                      "recoveryRequired", false},
           Transition{"commitAccepted", "launchPending", "recoveryRequired",
                      "recoveryRequired", false},
           Transition{"launchPending", "launchAttempting", "recoveryRequired",
                      "relaunchFailure", false},
           Transition{"launchAttempting", "launched", "relaunchFailure",
                      "completed", false},
           Transition{"launchAttempting", "launchFailed", "relaunchFailure",
                      "relaunchFailure", false}}) {
    for (const LinuxTransactionRegistryFaultPoint point : {
             LinuxTransactionRegistryFaultPoint::kAfterNextCreate,
             LinuxTransactionRegistryFaultPoint::kAfterNextFileSync,
             LinuxTransactionRegistryFaultPoint::kAfterNextRename}) {
      RegistryFixture fixture;
      auto before = fixture.Record();
      before.state = transition.from;
      before.result_code = transition.from_result;
      if (std::string(transition.from) != "preparing") {
        before.journal_sha256 = std::string(64, '6');
      }
      LinuxTransactionRegistry initial(false);
      initial.Persist(before);

      auto after = before;
      after.state = transition.to;
      after.result_code = transition.to_result;
      if (transition.advances_journal) {
        after.journal_sha256 = std::string(64, '6');
      }
      const pid_t child = fork();
      ASSERT_GE(child, 0);
      if (child == 0) {
        ExitAtRegistryFault fault(point);
        try {
          LinuxTransactionRegistry crashing(false, &fault);
          crashing.Persist(after);
        } catch (...) {
          _exit(82);
        }
        _exit(83);
      }
      int status = 0;
      ASSERT_EQ(child, waitpid(child, &status, 0));
      ASSERT_TRUE(WIFEXITED(status));
      ASSERT_EQ(81, WEXITSTATUS(status));

      LinuxTransactionRegistry recovered(false);
      const auto loaded = recovered.Load(before.transaction_id);
      ASSERT_TRUE(loaded.has_value());
      const bool write_was_durable =
          point != LinuxTransactionRegistryFaultPoint::kAfterNextCreate;
      EXPECT_EQ(write_was_durable ? after.state : before.state, loaded->state);
      EXPECT_EQ(write_was_durable ? after.result_code : before.result_code,
                loaded->result_code);
      EXPECT_EQ(write_was_durable ? after.journal_sha256
                                  : before.journal_sha256,
                loaded->journal_sha256);
      EXPECT_FALSE(fs::exists(
          fixture.Transactions() /
          (before.transaction_id + ".json.next")));
    }
  }
}

}  // namespace
}  // namespace desktop_updater::helper
