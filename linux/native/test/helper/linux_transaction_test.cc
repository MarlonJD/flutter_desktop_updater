#include <gtest/gtest.h>

#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <sys/inotify.h>
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

  void FinalizeActivatedPayloadRoot(
      int parent,
      const std::string& leaf,
      const LinuxFileIdentity& staged_identity) override {
    if (!finalize_root_mode) return;
    auto directory = OpenLinuxRelativeNoFollow(
        parent, leaf, O_RDONLY | O_DIRECTORY);
    const LinuxFileIdentity current = ReadLinuxFileIdentity(directory.get());
    if (current.device != staged_identity.device ||
        current.inode != staged_identity.inode ||
        current.mount_id != staged_identity.mount_id) {
      throw LinuxFileTransactionError("activation root identity changed");
    }
    if (fchmod(directory.get(), 0755) != 0) {
      throw LinuxFileTransactionError("activation root chmod failed");
    }
    finalized_root_mode = true;
  }

  bool MatchesActivatedPayloadRoot(
      int parent,
      const std::string& leaf,
      const LinuxFileIdentity& staged_identity) override {
    const LinuxFileIdentity current =
        ReadLinuxRelativeIdentity(parent, leaf);
    if (!finalize_root_mode) return current == staged_identity;
    return current.device == staged_identity.device &&
           current.inode == staged_identity.inode &&
           current.mount_id == staged_identity.mount_id &&
           current.uid == staged_identity.uid &&
           current.gid == staged_identity.gid &&
           current.link_count == staged_identity.link_count &&
           current.directory == staged_identity.directory &&
           (current.mode & 0777) == 0755;
  }

  bool finalize_root_mode = false;
  bool finalized_root_mode = false;
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

TEST(LinuxFileTransaction, PrepareIsDurableWithoutMutationAndCanBeCancelled) {
  Fixture fixture;
  auto transaction = fixture.Transaction();

  const std::string journal = transaction->PrepareDurableJournal();

  EXPECT_FALSE(journal.empty());
  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_EQ("new", fixture.Read(fixture.stage));
  EXPECT_TRUE(std::filesystem::exists(
      fixture.root / transaction->paths().journal_name));
  EXPECT_TRUE(std::filesystem::exists(
      fixture.root / transaction->paths().lock_name));

  transaction->CancelPrepared();

  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_EQ("new", fixture.Read(fixture.stage));
  EXPECT_FALSE(std::filesystem::exists(
      fixture.root / transaction->paths().journal_name));
  EXPECT_FALSE(std::filesystem::exists(
      fixture.root / transaction->paths().lock_name));
}

TEST(LinuxFileTransaction, ExecuteReusesPreparedJournal) {
  Fixture fixture;
  auto transaction = fixture.Transaction();
  const std::string journal = transaction->PrepareDurableJournal();

  EXPECT_EQ(LinuxFileTransactionResult::kCompleted, transaction->Execute());

  EXPECT_EQ("new", fixture.Read(fixture.target));
  EXPECT_FALSE(journal.empty());
  EXPECT_FALSE(std::filesystem::exists(
      fixture.root / transaction->paths().journal_name));
  EXPECT_FALSE(std::filesystem::exists(
      fixture.root / transaction->paths().lock_name));
}

TEST(LinuxFileTransaction, FinalizesPrivateStageRootOnlyAfterActivation) {
  Fixture fixture;
  ASSERT_EQ(0, chmod(fixture.stage.c_str(), 0700));
  fixture.verifier.finalize_root_mode = true;
  auto transaction = fixture.Transaction();
  struct stat before {};
  ASSERT_EQ(0, stat(fixture.stage.c_str(), &before));
  EXPECT_EQ(0700, before.st_mode & 0777);

  EXPECT_EQ(LinuxFileTransactionResult::kCompleted, transaction->Execute());

  struct stat after {};
  ASSERT_EQ(0, stat(fixture.target.c_str(), &after));
  EXPECT_EQ(0755, after.st_mode & 0777);
  EXPECT_TRUE(fixture.verifier.finalized_root_mode);
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

TEST(LinuxFileTransaction,
     CleanupRejectsNestedBindMountBeforeDeletingBackingData) {
  Fixture fixture;
  const auto cleanup = fixture.root / "cleanup";
  const auto nested = cleanup / "nested";
  const auto backing = fixture.root / "mount-backing";
  const auto sentinel = backing / "must-survive.txt";
  ASSERT_TRUE(std::filesystem::create_directories(nested));
  ASSERT_TRUE(std::filesystem::create_directories(backing));
  std::ofstream(sentinel, std::ios::binary) << "external";

  const pid_t child = fork();
  ASSERT_GE(child, 0);
  if (child == 0) {
    if (unshare(CLONE_NEWNS) != 0 ||
        mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr) != 0) {
      _exit(77);
    }
    auto parent = OpenLinuxDirectory(fixture.root.string());
    const LinuxFileIdentity expected =
        ReadLinuxRelativeIdentity(parent.get(), cleanup.filename().string());
    if (mount(backing.c_str(), nested.c_str(), nullptr, MS_BIND, nullptr) != 0) {
      _exit(77);
    }
    bool rejected = false;
    try {
      RemoveLinuxTreeExact(parent.get(), cleanup.filename().string(), expected);
    } catch (const std::exception&) {
      rejected = true;
    }
    if (!rejected) _exit(1);
    if (!std::filesystem::exists(sentinel)) _exit(2);
    if (!std::filesystem::exists(cleanup)) _exit(3);
    _exit(0);
  }

  int status = 0;
  ASSERT_EQ(child, waitpid(child, &status, 0));
  ASSERT_TRUE(WIFEXITED(status));
  if (WEXITSTATUS(status) == 77) {
    GTEST_SKIP() << "mount namespaces unavailable";
  }
  EXPECT_EQ(0, WEXITSTATUS(status));
  EXPECT_TRUE(std::filesystem::exists(sentinel));
}

TEST(LinuxFileTransaction, CleanupRejectsTreeBeyondMaximumDepthBeforeMutation) {
  Fixture fixture;
  const auto cleanup = fixture.root / "cleanup";
  std::filesystem::path current = cleanup;
  ASSERT_TRUE(std::filesystem::create_directory(cleanup));
  for (int depth = 0; depth != 129; ++depth) {
    current /= "d" + std::to_string(depth);
    ASSERT_TRUE(std::filesystem::create_directory(current));
  }
  const auto sentinel = current / "must-survive.txt";
  std::ofstream(sentinel, std::ios::binary) << "bounded";

  auto parent = OpenLinuxDirectory(fixture.root.string());
  const LinuxFileIdentity expected =
      ReadLinuxRelativeIdentity(parent.get(), cleanup.filename().string());

  EXPECT_THROW(RemoveLinuxTreeExact(parent.get(), cleanup.filename().string(),
                                   expected),
               LinuxTransactionJournalError);
  EXPECT_TRUE(std::filesystem::exists(cleanup));
  EXPECT_TRUE(std::filesystem::exists(sentinel));
}

TEST(LinuxFileTransaction, CleanupAcceptsMaximumVerifiedInventoryDepth) {
  Fixture fixture;
  const auto cleanup = fixture.root / "cleanup";
  std::filesystem::path current = cleanup;
  ASSERT_TRUE(std::filesystem::create_directory(cleanup));
  for (int depth = 0; depth != 127; ++depth) {
    current /= "d" + std::to_string(depth);
    ASSERT_TRUE(std::filesystem::create_directory(current));
  }
  std::ofstream(current / "depth-128.txt", std::ios::binary) << "accepted";

  auto parent = OpenLinuxDirectory(fixture.root.string());
  const LinuxFileIdentity expected =
      ReadLinuxRelativeIdentity(parent.get(), cleanup.filename().string());

  EXPECT_NO_THROW(RemoveLinuxTreeExact(
      parent.get(), cleanup.filename().string(), expected));
  EXPECT_FALSE(std::filesystem::exists(cleanup));
}

TEST(LinuxFileTransaction, CleanupRejectsSpecialNodeBeforeMutation) {
  Fixture fixture;
  const auto cleanup = fixture.root / "cleanup";
  const auto regular = cleanup / "must-survive.txt";
  const auto fifo = cleanup / "untrusted.fifo";
  ASSERT_TRUE(std::filesystem::create_directory(cleanup));
  std::ofstream(regular, std::ios::binary) << "regular";
  ASSERT_EQ(0, mkfifo(fifo.c_str(), 0600));

  auto parent = OpenLinuxDirectory(fixture.root.string());
  const LinuxFileIdentity expected =
      ReadLinuxRelativeIdentity(parent.get(), cleanup.filename().string());

  EXPECT_THROW(RemoveLinuxTreeExact(parent.get(), cleanup.filename().string(),
                                   expected),
               LinuxTransactionJournalError);
  EXPECT_TRUE(std::filesystem::exists(regular));
  struct stat status {};
  ASSERT_EQ(0, lstat(fifo.c_str(), &status));
  EXPECT_TRUE(S_ISFIFO(status.st_mode));
}

TEST(LinuxFileTransaction, CleanupRejectsDescendantReplacementBeforeUnlink) {
  Fixture fixture;
  const auto cleanup = fixture.root / "cleanup";
  const auto victim = cleanup / "victim";
  const auto displaced = fixture.root / "displaced-victim";
  const auto replacement = fixture.root / "replacement-victim";
  const auto original_sentinel = victim / "original-must-survive.txt";
  const auto replacement_sentinel =
      replacement / "replacement-must-survive.txt";
  ASSERT_TRUE(std::filesystem::create_directories(victim));
  ASSERT_TRUE(std::filesystem::create_directory(replacement));
  std::ofstream(original_sentinel, std::ios::binary) << "original";
  std::ofstream(replacement_sentinel, std::ios::binary) << "replacement";
  for (int index = 0; index != 2048; ++index) {
    std::ofstream(victim / ("padding-" + std::to_string(index)),
                  std::ios::binary)
        << index;
  }

  auto parent = OpenLinuxDirectory(fixture.root.string());
  const LinuxFileIdentity expected =
      ReadLinuxRelativeIdentity(parent.get(), cleanup.filename().string());
  UniqueLinuxFd notifications(inotify_init1(IN_CLOEXEC));
  ASSERT_TRUE(notifications.valid());
  ASSERT_GE(inotify_add_watch(notifications.get(), victim.c_str(), IN_OPEN), 0);

  const pid_t child = fork();
  ASSERT_GE(child, 0);
  if (child == 0) {
    try {
      RemoveLinuxTreeExact(parent.get(), cleanup.filename().string(), expected);
      _exit(1);
    } catch (const std::exception&) {
      _exit(0);
    }
  }

  pollfd ready{notifications.get(), POLLIN, 0};
  if (poll(&ready, 1, 5000) != 1) {
    kill(child, SIGKILL);
    waitpid(child, nullptr, 0);
    FAIL() << "cleanup did not open the watched descendant";
  }
  char event_buffer[4096];
  if (read(notifications.get(), event_buffer, sizeof(event_buffer)) <= 0 ||
      kill(child, SIGSTOP) != 0) {
    kill(child, SIGKILL);
    waitpid(child, nullptr, 0);
    FAIL() << "failed to stop cleanup at the descendant open";
  }

  int status = 0;
  if (waitpid(child, &status, WUNTRACED) != child || !WIFSTOPPED(status)) {
    kill(child, SIGKILL);
    waitpid(child, nullptr, 0);
    FAIL() << "cleanup child did not stop for replacement";
  }
  if (rename(victim.c_str(), displaced.c_str()) != 0 ||
      rename(replacement.c_str(), victim.c_str()) != 0) {
    kill(child, SIGKILL);
    waitpid(child, nullptr, 0);
    FAIL() << "failed to install descendant replacement";
  }
  if (kill(child, SIGCONT) != 0 || waitpid(child, &status, 0) != child) {
    kill(child, SIGKILL);
    waitpid(child, nullptr, 0);
    FAIL() << "failed to resume cleanup after replacement";
  }

  ASSERT_TRUE(WIFEXITED(status));
  EXPECT_EQ(0, WEXITSTATUS(status));
  EXPECT_TRUE(
      std::filesystem::exists(victim / replacement_sentinel.filename()));
  EXPECT_TRUE(
      std::filesystem::exists(displaced / original_sentinel.filename()));
}

}  // namespace
}  // namespace desktop_updater::helper
