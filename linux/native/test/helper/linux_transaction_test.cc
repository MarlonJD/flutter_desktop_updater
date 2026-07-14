#include <gtest/gtest.h>

#include <fcntl.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>

#include "linux_file_transaction.h"

namespace desktop_updater::helper {
namespace {

LinuxVerifiedPayloadIdentity Payload(const std::string& version) {
  const char digit = version == "new" ? 'b' : version == "old" ? 'a' : 'f';
  return {"com.example.app",
          "release-key-1",
          std::string(64, digit),
          std::string(64, 'c'),
          std::string(64, 'd'),
          "bin/example",
          std::string(64, 'e'),
          static_cast<std::uint32_t>(S_IFREG | 0755),
          static_cast<std::uint32_t>(geteuid()),
          static_cast<std::uint32_t>(getegid())};
}

class FixtureVerifier final : public LinuxInstallPayloadVerifier {
 public:
  LinuxVerifiedPayloadIdentity Verify(int parent,
                                      const std::string& leaf) override {
    auto directory = OpenLinuxRelativeNoFollow(parent, leaf, O_PATH | O_DIRECTORY);
    return Payload(ReadLinuxRelativeUtf8(directory.get(), "version.txt", 32));
  }
};

class ThrowingFault final : public LinuxTransactionFaultInjector {
 public:
  explicit ThrowingFault(LinuxTransactionFaultPoint point) : point_(point) {}
  void Hit(LinuxTransactionFaultPoint point) override {
    if (!thrown_ && point == point_) {
      thrown_ = true;
      throw LinuxFileTransactionError("injected persistence failure");
    }
  }

 private:
  LinuxTransactionFaultPoint point_;
  bool thrown_ = false;
};

class Fixture {
 public:
  Fixture() {
    root = std::filesystem::temp_directory_path() /
           ("desktop-updater-transaction-\xE6\xA1\x8C\xE9\x9D\xA2-" +
            std::to_string(getpid()) + "-" +
            std::to_string(counter_++));
    target = root / "Example.AppDir";
    stage = root / "Stage.AppDir";
    std::filesystem::create_directories(target);
    std::filesystem::create_directories(stage);
    Write(target, "old");
    Write(stage, "new");
  }

  ~Fixture() {
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
    std::filesystem::remove_all(root.string() + ".displaced", ignored);
  }

  void Write(const std::filesystem::path& directory,
             const std::string& value) {
    std::ofstream(directory / "version.txt", std::ios::binary) << value;
  }

  std::string Read(const std::filesystem::path& directory) {
    std::ifstream input(directory / "version.txt", std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
  }

  std::unique_ptr<LinuxFileTransaction> Transaction(
      LinuxTransactionFaultInjector* fault = nullptr,
      const std::string& transaction_id =
          "00000000-0000-4000-8000-000000000010") {
    return std::make_unique<LinuxFileTransaction>(
        target, stage, transaction_id, getpid(), Payload("new"), verifier,
        fault);
  }

  inline static unsigned int counter_ = 0;
  std::filesystem::path root;
  std::filesystem::path target;
  std::filesystem::path stage;
  FixtureVerifier verifier;
};

TEST(LinuxFileTransaction, SwapsUnicodeTreeAndRemovesDerivedState) {
  Fixture fixture;
  auto transaction = fixture.Transaction();

  EXPECT_EQ(LinuxFileTransactionResult::kCompleted, transaction->Execute());
  EXPECT_EQ("new", fixture.Read(fixture.target));
  EXPECT_FALSE(std::filesystem::exists(fixture.stage));
  EXPECT_FALSE(std::filesystem::exists(fixture.root /
                                       transaction->paths().journal_name));
  EXPECT_FALSE(std::filesystem::exists(fixture.root /
                                       transaction->paths().lock_name));
}

TEST(LinuxFileTransaction, RejectsSymlinkAndStageReplacement) {
  Fixture fixture;
  auto transaction = fixture.Transaction();
  std::filesystem::remove_all(fixture.stage);
  std::filesystem::create_directory_symlink(fixture.target, fixture.stage);

  EXPECT_THROW(transaction->Execute(), std::exception);
  EXPECT_EQ("old", fixture.Read(fixture.target));
}

TEST(LinuxFileTransaction, RejectsPermissionChangeAfterReservation) {
  Fixture fixture;
  auto transaction = fixture.Transaction();
  ASSERT_EQ(0, chmod(fixture.stage.c_str(), 0700));

  EXPECT_THROW(transaction->Execute(), std::exception);
  EXPECT_EQ("old", fixture.Read(fixture.target));
}

TEST(LinuxFileTransaction, RejectsTargetParentReplacement) {
  Fixture fixture;
  auto transaction = fixture.Transaction();
  const auto displaced = fixture.root.string() + ".displaced";
  ASSERT_EQ(0, rename(fixture.root.c_str(), displaced.c_str()));
  ASSERT_TRUE(std::filesystem::create_directories(fixture.root));

  EXPECT_THROW(transaction->Execute(), std::exception);
  EXPECT_FALSE(std::filesystem::exists(fixture.target));
  EXPECT_EQ("old", fixture.Read(std::filesystem::path(displaced) /
                                "Example.AppDir"));
}

TEST(LinuxFileTransaction, TwoHelpersRaceOnExclusiveTargetLock) {
  Fixture fixture;
  auto first = fixture.Transaction();
  EXPECT_THROW(fixture.Transaction(
                   nullptr, "00000000-0000-4000-8000-000000000011"),
               std::exception);
  EXPECT_EQ("old", fixture.Read(fixture.target));
}

TEST(LinuxFileTransaction, PersistenceFailuresNeverStartMutation) {
  for (const auto point : {LinuxTransactionFaultPoint::kDiskFull,
                           LinuxTransactionFaultPoint::kShortJournalWrite,
                           LinuxTransactionFaultPoint::kFileFsyncFailure,
                           LinuxTransactionFaultPoint::kDirectoryFsyncFailure}) {
    Fixture fixture;
    ThrowingFault fault(point);
    auto transaction = fixture.Transaction(&fault);
    EXPECT_THROW(transaction->Execute(), std::exception);
    EXPECT_EQ("old", fixture.Read(fixture.target));
  }
}

TEST(LinuxFileTransaction, RejectsHardLinkedSingleFileStage) {
  Fixture fixture;
  std::filesystem::remove_all(fixture.target);
  std::filesystem::remove_all(fixture.stage);
  std::ofstream(fixture.target, std::ios::binary) << "old";
  std::ofstream(fixture.stage, std::ios::binary) << "new";
  const auto alias = fixture.root / "stage-alias";
  ASSERT_EQ(0, link(fixture.stage.c_str(), alias.c_str()));

  EXPECT_THROW(LinuxFileTransaction(fixture.target, fixture.stage,
                                    "00000000-0000-4000-8000-000000000012",
                                    getpid(), Payload("new"), fixture.verifier),
               std::exception);
}

TEST(LinuxFileTransaction, RejectsBindMountAndMountIdChange) {
  const char bindMount[] = "bindMount";
  (void)bindMount;
  Fixture fixture;
  const pid_t child = fork();
  ASSERT_GE(child, 0);
  if (child == 0) {
    if (unshare(CLONE_NEWNS) != 0 ||
        mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr) != 0 ||
        mount(fixture.stage.c_str(), fixture.stage.c_str(), nullptr, MS_BIND,
              nullptr) != 0) {
      _exit(77);
    }
    try {
      auto transaction = fixture.Transaction();
      (void)transaction;
      _exit(1);
    } catch (const std::exception&) {
      _exit(0);
    }
  }
  int status = 0;
  ASSERT_EQ(child, waitpid(child, &status, 0));
  ASSERT_TRUE(WIFEXITED(status));
  if (WEXITSTATUS(status) == 77) {
    GTEST_SKIP() << "unprivileged mount namespaces unavailable";
  }
  EXPECT_EQ(0, WEXITSTATUS(status));
}

}  // namespace
}  // namespace desktop_updater::helper
